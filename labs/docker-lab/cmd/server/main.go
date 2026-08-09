// This program is the lab API server. It shows the full SPIFFE identity flow
// on the server side:
//
//	Workload API -> X509-SVID -> mTLS listener -> peer SPIFFE ID check
//
// The server reads no certificate file and holds no shared secret. It asks the
// local SPIRE agent for an identity. SPIRE decides that identity from the
// label of this container. The server then accepts one peer SPIFFE ID, and no
// other.
package main

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"log"
	"net"
	"net/http"
	"os/signal"
	"syscall"
	"time"

	"github.com/spiffe/go-spiffe/v2/logger"
	"github.com/spiffe/go-spiffe/v2/spiffeid"
	"github.com/spiffe/go-spiffe/v2/spiffetls/tlsconfig"
	"github.com/spiffe/go-spiffe/v2/svid/x509svid"
	"github.com/spiffe/go-spiffe/v2/workloadapi"
)

const (
	// This constant names the identity that this server must receive. The
	// Workload API is the only source of the real identity. This constant
	// makes a wrong container label easy to see in the log.
	expectedServerID = "spiffe://lab.local/server"

	// The only peer this server accepts. The TLS handshake refuses a different
	// SPIFFE ID, and the HTTP handler does not run.
	authorizedClientID = "spiffe://lab.local/client"

	listenAddress = ":8443"

	// This value is the time limit for the first SVID. If the agent gives no
	// identity, the server must stop with an error. It must not wait forever.
	firstSVIDTimeout = 30 * time.Second

	// This line tells the start script that the listener is ready.
	readyMessage = "mTLS server listening on"
)

// helloResponse is the response body of GET /hello.
type helloResponse struct {
	Message  string `json:"message"`
	ServerID string `json:"server_id"`
	ClientID string `json:"client_id"`
}

func main() {
	log.SetFlags(log.LstdFlags)
	if err := run(); err != nil {
		log.Fatalf("server failed: %v", err)
	}
}

func run() error {
	serverID, err := spiffeid.FromString(expectedServerID)
	if err != nil {
		return fmt.Errorf("bad expected server SPIFFE ID: %w", err)
	}
	clientID, err := spiffeid.FromString(authorizedClientID)
	if err != nil {
		return fmt.Errorf("bad authorized client SPIFFE ID: %w", err)
	}

	log.Print("server starting")
	log.Printf("expected server SPIFFE ID: %s", serverID)
	log.Printf("authorized client: %s", clientID)

	source, err := newSource(serverID)
	if err != nil {
		return err
	}
	defer source.Close()

	// MTLSServerConfig does three things: it presents this server's SVID, it
	// asks the client for a certificate, and it verifies that certificate
	// against the SPIRE trust bundle. AuthorizeID then permits one SPIFFE ID.
	// The source supplies both the SVID and the bundle, and it keeps both
	// current while the server runs.
	tlsConfig := tlsconfig.MTLSServerConfig(source, source, tlsconfig.AuthorizeID(clientID))

	// Go does not repeat the SPIFFE check for a resumed TLS session. The
	// server refuses resumption, so every connection proves its identity.
	tlsConfig.SessionTicketsDisabled = true

	mux := http.NewServeMux()
	mux.HandleFunc("GET /hello", helloHandler(source))

	server := &http.Server{
		Addr:      listenAddress,
		Handler:   mux,
		TLSConfig: tlsConfig,
		// A slow or silent peer must not hold a connection open forever.
		ReadHeaderTimeout: 10 * time.Second,
	}

	return serve(server)
}

// newSource gets the identity of this workload from the local SPIRE agent.
func newSource(serverID spiffeid.ID) (*workloadapi.X509Source, error) {
	// The address of the Workload API comes from the environment variable
	// SPIFFE_ENDPOINT_SOCKET. The workload image sets it to
	// unix:///run/spire/agent.sock. The code names no socket path.
	ctx, cancel := context.WithTimeout(context.Background(), firstSVIDTimeout)
	defer cancel()

	// NewX509Source waits for the first SVID. The context limits only that
	// first wait. The source then watches for rotation with its own context.
	// The logger makes later Workload API failures visible in the server log.
	source, err := workloadapi.NewX509Source(ctx,
		workloadapi.WithClientOptions(workloadapi.WithLogger(logger.Std)))
	if err != nil {
		return nil, fmt.Errorf("the Workload API gave no X509-SVID: %w", err)
	}

	svid, err := source.GetX509SVID()
	if err != nil {
		source.Close()
		return nil, fmt.Errorf("cannot read the X509-SVID: %w", err)
	}
	log.Printf("X509-SVID received from the Workload API: %s", svid.ID)

	// SPIRE maps the label of this container to a SPIFFE ID. If the ID is
	// wrong, the container carries the wrong label. The client then refuses
	// this server. Therefore the server stops and reports the cause.
	if svid.ID != serverID {
		source.Close()
		return nil, fmt.Errorf("the received identity is %s, not %s: check the label of this container", svid.ID, serverID)
	}
	return source, nil
}

// helloHandler answers GET /hello. The TLS handshake already authenticated
// and authorized the peer, so this handler runs only for the permitted client.
func helloHandler(source *workloadapi.X509Source) http.HandlerFunc {
	return func(w http.ResponseWriter, r *http.Request) {
		// The peer identity comes from the verified certificate. The lab never
		// reads it from a header, a hostname, or the request body.
		clientID, err := peerID(r)
		if err != nil {
			log.Printf("request refused: %v", err)
			http.Error(w, "no authenticated peer identity", http.StatusForbidden)
			return
		}

		// Read the SVID again for each request. After a rotation the server
		// reports the identity that it holds now.
		svid, err := source.GetX509SVID()
		if err != nil {
			log.Printf("request failed: %v", err)
			http.Error(w, "no server identity", http.StatusInternalServerError)
			return
		}

		log.Printf("GET /hello from authenticated client: %s", clientID)

		w.Header().Set("Content-Type", "application/json")
		if err := json.NewEncoder(w).Encode(helloResponse{
			Message:  "hello from SPIFFE server",
			ServerID: svid.ID.String(),
			ClientID: clientID.String(),
		}); err != nil {
			log.Printf("cannot write the response: %v", err)
		}
	}
}

// peerID reads the SPIFFE ID out of the client certificate of this connection.
func peerID(r *http.Request) (spiffeid.ID, error) {
	if r.TLS == nil || len(r.TLS.PeerCertificates) == 0 {
		return spiffeid.ID{}, errors.New("the request has no client certificate")
	}
	return x509svid.IDFromCert(r.TLS.PeerCertificates[0])
}

// serve runs the listener and stops it on SIGINT or SIGTERM.
func serve(server *http.Server) error {
	ctx, stop := signal.NotifyContext(context.Background(), syscall.SIGINT, syscall.SIGTERM)
	defer stop()

	// Bind the port first. The ready line is a promise to the start script,
	// so the server prints it only after the listener is open.
	listener, err := net.Listen("tcp", server.Addr)
	if err != nil {
		return fmt.Errorf("cannot open the listener on %s: %w", server.Addr, err)
	}

	listenErr := make(chan error, 1)
	go func() {
		// The two empty strings are the certificate and key file names. They
		// stay empty because the SVID source supplies the certificate.
		listenErr <- server.ServeTLS(listener, "", "")
	}()

	log.Printf("%s %s", readyMessage, server.Addr)

	select {
	case err := <-listenErr:
		if err != nil && !errors.Is(err, http.ErrServerClosed) {
			return err
		}
		return nil
	case <-ctx.Done():
		log.Print("stop signal received, the server is closing")
		shutdownCtx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
		defer cancel()
		return server.Shutdown(shutdownCtx)
	}
}
