// Command backend is the zone-lab serving app. It is a trivial HTTP server.
//
// The app holds no TLS certificate and no go-spiffe code. Envoy fronts this
// app on the zone network and terminates mTLS. The app listens on loopback
// only, so no peer reaches it except the local Envoy.
//
// The body names the zone, for example "zone-lab backend zone-b OK". The body
// differs per zone, so a test can prove which backend answered (property P6).
//
// The listen address is 127.0.0.1:8080 by default. Only the local Envoy reaches
// the app. The LISTEN_ADDR environment variable changes the address. The zone-a
// peer sets 0.0.0.0:8080, so the client reaches the peer over plain HTTP. This
// call uses no mTLS and no gateway. It proves intra-zone plaintext (property
// P10).
package main

import (
	"fmt"
	"log"
	"net/http"
	"os"
)

func main() {
	// The zone name comes from the ZONE environment variable. Compose sets it
	// per backend container. An empty value becomes "unknown", so a missing
	// setting is visible, not silent.
	zone := os.Getenv("ZONE")
	if zone == "" {
		zone = "unknown"
	}

	// Envoy connects on loopback. The app binds loopback by default, so no
	// remote peer reaches a backend app directly. The peer overrides LISTEN_ADDR
	// with 0.0.0.0:8080, so the client reaches the peer over plain HTTP.
	addr := os.Getenv("LISTEN_ADDR")
	if addr == "" {
		addr = "127.0.0.1:8080"
	}
	body := fmt.Sprintf("zone-lab backend %s OK\n", zone)

	mux := http.NewServeMux()
	mux.HandleFunc("/", func(w http.ResponseWriter, r *http.Request) {
		log.Printf("backend %s answered %s %s", zone, r.Method, r.URL.Path)
		w.Header().Set("Content-Type", "text/plain")
		fmt.Fprint(w, body)
	})

	log.Printf("zone-lab backend %s listening on %s", zone, addr)
	if err := http.ListenAndServe(addr, mux); err != nil {
		log.Fatalf("backend stopped: %v", err)
	}
}
