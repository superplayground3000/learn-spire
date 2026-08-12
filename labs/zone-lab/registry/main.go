// Command registry is the zone-lab SVID-authorized service registry.
//
// The registry is a plain-HTTP Go program. It holds no TLS code and no
// identity code. An Envoy sidecar in front of it terminates mTLS and passes the
// caller SPIFFE ID in an x-forwarded-client-cert (XFCC) header. The registry
// reads the caller from that header. The body states intent; it is never
// evidence.
//
// A caller may register only its own zone and its own service. The rule is
// exact, not prefix-based. A cross-zone registration is refused with the reason
// "cross-zone registration refused". A wrong-service registration is refused
// with "service mismatch".
//
// Each record holds a lease. A reaper goroutine removes a lease that is not
// renewed. So a stopped registrar, or a revoked identity, ages out on its own.
//
// The registry renders one CoreDNS zone file per zone to a shared views volume.
// It re-renders only when the record set changes, so the SOA serial does not
// bump on every reap tick.
package main

import (
	"encoding/json"
	"log"
	"net/http"
	"os"
	"path/filepath"
	"regexp"
	"sort"
	"strconv"
	"strings"
	"sync"
	"time"
)

// getenv reads an environment variable, or returns a default value.
func getenv(key, def string) string {
	if v := os.Getenv(key); v != "" {
		return v
	}
	return def
}

// getenvInt reads an integer environment variable, or returns a default value.
func getenvInt(key string, def int) int {
	if v := os.Getenv(key); v != "" {
		if n, err := strconv.Atoi(v); err == nil {
			return n
		}
	}
	return def
}

var (
	trustDomain  = getenv("TRUST_DOMAIN", "lab.local")
	listenAddr   = getenv("LISTEN_ADDR", "127.0.0.1:8081")
	viewsDir     = getenv("VIEWS_DIR", "/views")
	leaseTTL     = getenvInt("LEASE_TTL", 30)
	reapInterval = getenvInt("REAP_INTERVAL", 5)
	zones        = strings.Split(getenv("ZONES", "zone-a,zone-b,zone-c"), ",")
)

// idRe matches spiffe://<trust-domain>/<zone>/<service>. The match is exact.
var idRe = regexp.MustCompile(`^spiffe://` + regexp.QuoteMeta(trustDomain) + `/([^/]+)/([^/]+)$`)

// policy maps a zone to the peer zones it may reach. A human maintains this
// only. Everything else in a view is derived. The policy comes from POLICY_JSON
// at start; it is never an HTTP endpoint. An unauthenticated policy-rewrite
// endpoint would undermine the design.
var policy = loadPolicy()

func loadPolicy() map[string][]string {
	def := map[string][]string{"zone-a": {"zone-b"}, "zone-b": {"zone-c"}}
	raw := os.Getenv("POLICY_JSON")
	if raw == "" {
		return def
	}
	var p map[string][]string
	if err := json.Unmarshal([]byte(raw), &p); err != nil {
		log.Printf("[registry] POLICY_JSON is not valid; using the default policy: %v", err)
		return def
	}
	return p
}

// gwAddrIn gives the gateway address a viewer zone should dial for a target
// zone. A gateway is multi-homed, so its address depends on who is asking. The
// value is the target gateway's address on the viewer's network. These values
// match the phase-1 docker-compose addresses.
//
//	gwAddrIn[targetZone][viewerZone] = address the viewer should dial
var gwAddrIn = map[string]map[string]string{
	"zone-b": {"zone-a": "10.10.0.40"}, // zone-b-gateway, as seen from zone-a
	"zone-c": {"zone-b": "10.20.0.41"}, // zone-c-gateway, as seen from zone-b
}

// record is one registered service. The map key is "<service>.<zone>".
type record struct {
	Zone      string  `json:"zone"`
	Service   string  `json:"service"`
	IP        string  `json:"ip"`
	Port      int     `json:"port"`
	SpiffeID  string  `json:"spiffe_id"`
	ExpiresAt float64 `json:"expires_at"`
	LeaseTTL  int     `json:"lease_ttl"`
}

var (
	registry = map[string]record{}
	lock     sync.Mutex
	lastSig  string // re-render only when the record set changes
)

// peerSpiffeID reads the caller identity from the XFCC header. This is the ONLY
// input the authorization decision may use. Envoy sets URI=<san> from the
// validated mTLS peer. A request body is a claim, not evidence.
func peerSpiffeID(xfcc string) string {
	if xfcc == "" {
		return ""
	}
	// XFCC is a comma-separated list of elements. Each element is a set of
	// semicolon-separated key=value pairs. "uri: true" adds URI=<san>.
	for _, elem := range strings.Split(xfcc, ",") {
		for _, kv := range strings.Split(elem, ";") {
			kv = strings.TrimSpace(kv)
			if len(kv) >= 4 && strings.EqualFold(kv[:4], "URI=") {
				v := strings.Trim(kv[4:], "\"")
				if strings.HasPrefix(v, "spiffe://") {
					return v
				}
			}
		}
	}
	return ""
}

// authorize returns (ok, reason). The rule is exact, not prefix-based.
func authorize(spiffeID, wantZone, wantService string) (bool, string) {
	if spiffeID == "" {
		return false, "no SPIFFE ID presented (no client certificate)"
	}
	m := idRe.FindStringSubmatch(spiffeID)
	if m == nil {
		return false, "SPIFFE ID " + spiffeID + " is not of the form spiffe://" + trustDomain + "/<zone>/<service>"
	}
	gotZone, gotService := m[1], m[2]
	// P15: this check refuses a cross-zone registration. To prove the rule can
	// fail, delete this block: a zone-b identity would then register into
	// zone-c, and P15 would flip from refused to accepted.
	if gotZone != wantZone {
		return false, "cross-zone registration refused: identity is in '" + gotZone + "' but tried to register into '" + wantZone + "'"
	}
	// P16: this check refuses a wrong-service registration.
	if gotService != wantService {
		return false, "service mismatch: identity is '" + gotService + "' but tried to register '" + wantService + "'"
	}
	return true, "identity matches the requested name exactly"
}

// signature is the identity of the record SET, not the lease clock. Re-rendering
// on every reap would bump the SOA serial for nothing.
func signature() string {
	lock.Lock()
	defer lock.Unlock()
	keys := make([]string, 0, len(registry))
	for _, r := range registry {
		keys = append(keys, r.Zone+"|"+r.Service+"|"+r.IP)
	}
	sort.Strings(keys)
	return strings.Join(keys, ",")
}

// renderViews writes one CoreDNS zone file per zone. It derives each file from
// three inputs:
//   - registrations: a zone's own services resolve to their real addresses.
//   - policy: each authorized peer zone gets ONE wildcard line.
//   - gwAddrIn: that peer's gateway, as reachable from this zone.
//
// A zone gets its own services as real records, one wildcard per zone it may
// reach, and nothing for the zones it may not reach. The absence turns an
// unauthorized lookup into NXDOMAIN, not a reachable address.
func renderViews() []string {
	if err := os.MkdirAll(viewsDir, 0o755); err != nil {
		log.Printf("[registry] cannot make the views dir: %v", err)
		return nil
	}

	sig := signature()
	firstView := filepath.Join(viewsDir, zones[0]+".zone")
	if sig == lastSig {
		if _, err := os.Stat(firstView); err == nil {
			return zones // nothing changed; leave the serial alone
		}
	}
	lastSig = sig

	lock.Lock()
	recs := make([]record, 0, len(registry))
	for _, r := range registry {
		recs = append(recs, r)
	}
	lock.Unlock()

	// The file plugin reloads on an increased SOA serial, so it must change.
	serial := time.Now().Unix()
	written := []string{}
	for _, zone := range zones {
		var b strings.Builder
		b.WriteString("$ORIGIN internal.\n")
		b.WriteString("$TTL 30\n")
		b.WriteString("@   IN SOA ns.internal. hostmaster.internal. " + strconv.FormatInt(serial, 10) + " 7200 3600 1209600 30\n")
		b.WriteString("    IN NS  ns.internal.\n")
		b.WriteString("ns  IN A 127.0.0.1\n")
		b.WriteString("\n; --- " + zone + "'s own services (real addresses, no gateway) ---\n")

		own := []record{}
		for _, r := range recs {
			if r.Zone == zone {
				own = append(own, r)
			}
		}
		sort.Slice(own, func(i, j int) bool { return own[i].Service < own[j].Service })
		for _, r := range own {
			b.WriteString(r.Service + "." + zone + "    IN A " + r.IP + "    ; " + r.SpiffeID + "\n")
		}

		b.WriteString("\n; --- authorized peer zones: ONE wildcard each, pointing at their gateway ---\n")
		peers := append([]string{}, policy[zone]...)
		sort.Strings(peers)
		peerSet := map[string]bool{}
		for _, peer := range peers {
			peerSet[peer] = true
			if vip := gwAddrIn[peer][zone]; vip != "" {
				b.WriteString("*." + peer + "    IN A " + vip + "    ; " + peer + " gateway, as reachable from " + zone + "\n")
			}
		}
		denied := []string{}
		for _, z := range zones {
			if z != zone && !peerSet[z] {
				denied = append(denied, z)
			}
		}
		msg := "none"
		if len(denied) > 0 {
			msg = strings.Join(denied, ", ")
		}
		b.WriteString("; not authorized (absent on purpose -> NXDOMAIN): " + msg + "\n")

		path := filepath.Join(viewsDir, zone+".zone")
		if err := os.WriteFile(path, []byte(b.String()), 0o644); err != nil {
			log.Printf("[registry] cannot write %s: %v", path, err)
			continue
		}
		written = append(written, zone)
	}
	return written
}

// reap removes leases that were not renewed, then re-renders if anything
// changed.
func reap() {
	for {
		time.Sleep(time.Duration(reapInterval) * time.Second)
		now := float64(time.Now().UnixNano()) / 1e9
		expired := []record{}
		lock.Lock()
		for k, r := range registry {
			if r.ExpiresAt <= now {
				expired = append(expired, r)
				delete(registry, k)
			}
		}
		lock.Unlock()
		for _, r := range expired {
			log.Printf("[registry] EXPIRED %s.%s (lease not renewed; owner was %s)", r.Service, r.Zone, r.SpiffeID)
		}
		if len(expired) > 0 {
			renderViews()
		}
	}
}

func writeJSON(w http.ResponseWriter, code int, obj any) {
	body, _ := json.Marshal(obj)
	w.Header().Set("Content-Type", "application/json")
	w.WriteHeader(code)
	_, _ = w.Write(body)
}

// handleRegistry answers GET /registry with the current record set.
func handleRegistry(w http.ResponseWriter, r *http.Request) {
	now := float64(time.Now().UnixNano()) / 1e9
	lock.Lock()
	out := []map[string]any{}
	for k, rec := range registry {
		out = append(out, map[string]any{
			"name":       k,
			"zone":       rec.Zone,
			"service":    rec.Service,
			"ip":         rec.IP,
			"port":       rec.Port,
			"spiffe_id":  rec.SpiffeID,
			"expires_in": float64(int((rec.ExpiresAt-now)*10)) / 10,
			"lease_ttl":  rec.LeaseTTL,
		})
	}
	lock.Unlock()
	writeJSON(w, http.StatusOK, map[string]any{"records": out, "lease_ttl": leaseTTL})
}

// handleViews answers GET /views/<zone> with the rendered zone file.
func handleViews(w http.ResponseWriter, r *http.Request) {
	zone := r.URL.Path[len("/views/"):]
	path := filepath.Join(viewsDir, zone+".zone")
	data, err := os.ReadFile(path)
	if err != nil {
		writeJSON(w, http.StatusNotFound, map[string]any{"error": "no view for " + zone})
		return
	}
	w.Header().Set("Content-Type", "text/plain")
	w.WriteHeader(http.StatusOK)
	_, _ = w.Write(data)
}

// registerBody is the request body. It states intent only. The authorization
// never trusts it.
type registerBody struct {
	Zone    string `json:"zone"`
	Service string `json:"service"`
	IP      string `json:"ip"`
	Port    int    `json:"port"`
}

// handleRegister answers POST /register. It reads the caller from XFCC, checks
// the exact rule, and holds a lease. Renewal is just re-registration, so it
// takes the identical authorization path.
func handleRegister(w http.ResponseWriter, r *http.Request) {
	spiffeID := peerSpiffeID(r.Header.Get("x-forwarded-client-cert"))
	var req registerBody
	if err := json.NewDecoder(r.Body).Decode(&req); err != nil {
		writeJSON(w, http.StatusBadRequest, map[string]any{"error": "bad json"})
		return
	}

	ok, reason := authorize(spiffeID, req.Zone, req.Service)
	decision := "REFUSED"
	if ok {
		decision = "ACCEPTED"
	}
	log.Printf("[registry] %s caller=%s wants=%s.%s ip=%s :: %s", decision, spiffeID, req.Service, req.Zone, req.IP, reason)
	if !ok {
		writeJSON(w, http.StatusForbidden, map[string]any{
			"accepted": false, "caller": spiffeID,
			"requested": req.Service + "." + req.Zone, "reason": reason,
		})
		return
	}

	fqdn := req.Service + "." + req.Zone
	now := float64(time.Now().UnixNano()) / 1e9
	lock.Lock()
	_, renewal := registry[fqdn]
	registry[fqdn] = record{
		Zone: req.Zone, Service: req.Service, IP: req.IP, Port: req.Port,
		SpiffeID: spiffeID, ExpiresAt: now + float64(leaseTTL), LeaseTTL: leaseTTL,
	}
	lock.Unlock()
	views := renderViews()
	writeJSON(w, http.StatusOK, map[string]any{
		"accepted": true, "caller": spiffeID, "name": fqdn, "reason": reason,
		"views": views, "lease_ttl": leaseTTL, "renewal": renewal,
	})
}

func main() {
	mux := http.NewServeMux()
	mux.HandleFunc("/register", handleRegister)
	mux.HandleFunc("/registry", handleRegistry)
	mux.HandleFunc("/views/", handleViews)

	if err := os.MkdirAll(viewsDir, 0o755); err != nil {
		log.Fatalf("[registry] cannot make the views dir: %v", err)
	}
	renderViews()
	go reap()

	log.Printf("[registry] lease ttl %ds, reaping every %ds", leaseTTL, reapInterval)
	log.Printf("[registry] listening on %s (plain HTTP behind Envoy), trust domain %s", listenAddr, trustDomain)
	log.Printf("[registry] identity comes ONLY from the x-forwarded-client-cert header")
	if err := http.ListenAndServe(listenAddr, mux); err != nil {
		log.Fatalf("[registry] stopped: %v", err)
	}
}
