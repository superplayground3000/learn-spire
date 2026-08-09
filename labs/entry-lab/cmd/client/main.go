// This program is the lab API client. It shows the full SPIFFE identity flow
// on the client side:
//
//	Workload API -> X509-SVID -> mTLS request -> peer SPIFFE ID check
//
// The client reads no certificate file and holds no API key. It asks the local
// SPIRE agent for an identity, and it accepts one server SPIFFE ID.
//
// The same binary runs under UID 10002 and under UID 10003. The client never
// selects its own identity, so the UID alone decides which SPIFFE ID it gets.
// The intruder demo uses this property.
package main

import (
	"context"
	"errors"
	"fmt"
	"io"
	"log"
	"net/http"
	"strings"
	"time"

	"github.com/spiffe/go-spiffe/v2/spiffeid"
	"github.com/spiffe/go-spiffe/v2/spiffetls/tlsconfig"
	"github.com/spiffe/go-spiffe/v2/svid/x509svid"
	"github.com/spiffe/go-spiffe/v2/workloadapi"
)

const (
	// This constant names the only server that this client accepts. Another
	// SPIFFE ID stops the TLS handshake, and the client sends no request.
	expectedServerID = "spiffe://lab.local/server"

	// The node container also answers to the network name "server".
	serverURL = "https://server:8443/hello"

	// This value is the time limit for the first SVID. If the agent gives no
	// identity, the client must stop with an error. It must not wait forever.
	firstSVIDTimeout = 30 * time.Second

	requestTimeout = 15 * time.Second

	// This value is the upper limit for the response body. The lab response
	// is small.
	maxBodyBytes = 64 << 10
)

func main() {
	// The output carries no timestamps because it is the transcript of one
	// demo run.
	log.SetFlags(0)
	if err := run(); err != nil {
		log.Fatalf("client failed: %v", err)
	}
}

func run() error {
	serverID, err := spiffeid.FromString(expectedServerID)
	if err != nil {
		return fmt.Errorf("bad expected server SPIFFE ID: %w", err)
	}

	source, err := newSource()
	if err != nil {
		return err
	}
	defer source.Close()

	log.Print("connecting to server")
	log.Printf("expected server: %s", serverID)
	log.Printf("url: %s", serverURL)

	// MTLSClientConfig does three things: it presents this client's SVID, it
	// verifies the server certificate against the SPIRE trust bundle, and it
	// permits one SPIFFE ID. go-spiffe replaces the usual hostname and web PKI
	// checks with this SPIFFE check, so the name "server" needs no web
	// certificate.
	tlsConfig := tlsconfig.MTLSClientConfig(source, source, tlsconfig.AuthorizeID(serverID))

	client := &http.Client{
		Timeout:   requestTimeout,
		Transport: &http.Transport{TLSClientConfig: tlsConfig},
	}
	defer client.CloseIdleConnections()

	return get(client)
}

// newSource gets the identity of this workload from the local SPIRE agent.
func newSource() (*workloadapi.X509Source, error) {
	// The address of the Workload API comes from the environment variable
	// SPIFFE_ENDPOINT_SOCKET. The node image sets it to
	// unix:///run/spire/agent.sock. The code names no socket path.
	ctx, cancel := context.WithTimeout(context.Background(), firstSVIDTimeout)
	defer cancel()

	// The client uses no Workload API logger. The output is the §16 demo
	// transcript, and a failure already surfaces as the returned error.
	source, err := workloadapi.NewX509Source(ctx)
	if err != nil {
		return nil, fmt.Errorf("the Workload API gave no X509-SVID: %w", err)
	}

	svid, err := source.GetX509SVID()
	if err != nil {
		source.Close()
		return nil, fmt.Errorf("cannot read the X509-SVID: %w", err)
	}
	log.Printf("client SPIFFE ID: %s", svid.ID)
	return source, nil
}

// get sends GET /hello and reports what the server proved and answered.
func get(client *http.Client) error {
	ctx, cancel := context.WithTimeout(context.Background(), requestTimeout)
	defer cancel()

	request, err := http.NewRequestWithContext(ctx, http.MethodGet, serverURL, nil)
	if err != nil {
		return fmt.Errorf("cannot build the request: %w", err)
	}

	response, err := client.Do(request)
	if err != nil {
		return fmt.Errorf("request to %s failed: %w", serverURL, err)
	}
	defer response.Body.Close()

	// The handshake is complete here, so the server proved this identity with
	// its private key. The client did not read it from a header or a hostname.
	authenticatedServer, err := serverIdentity(response)
	if err != nil {
		return err
	}

	log.Print("mTLS handshake: SUCCESS")
	log.Printf("authenticated server: %s", authenticatedServer)
	// The serial identifies the exact certificate that the server presented.
	// The rotation demo compares it across runs.
	log.Printf("server certificate serial: %X", response.TLS.PeerCertificates[0].SerialNumber)

	body, err := io.ReadAll(io.LimitReader(response.Body, maxBodyBytes))
	if err != nil {
		return fmt.Errorf("cannot read the response body: %w", err)
	}

	log.Printf("HTTP status: %d", response.StatusCode)
	log.Printf("body: %s", strings.TrimSpace(string(body)))

	if response.StatusCode != http.StatusOK {
		return fmt.Errorf("the server answered HTTP %d", response.StatusCode)
	}
	return nil
}

// serverIdentity reads the SPIFFE ID out of the server certificate of this
// connection.
func serverIdentity(response *http.Response) (spiffeid.ID, error) {
	if response.TLS == nil || len(response.TLS.PeerCertificates) == 0 {
		return spiffeid.ID{}, errors.New("the response has no server certificate")
	}
	return x509svid.IDFromCert(response.TLS.PeerCertificates[0])
}
