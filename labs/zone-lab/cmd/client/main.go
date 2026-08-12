// Command client is the zone-lab caller app. It is a plain HTTP client.
//
// The app holds no go-spiffe code. It reads the mTLS material from files that
// the demo fetches from the SPIRE agent socket with the spire-agent CLI. So
// the identity still comes from SPIRE, but the app carries no SPIFFE library.
// This keeps the before/after teaching contrast: Lab 1 and Lab 2 authorized
// the peer in Go code; here Envoy authorizes, and the app only calls.
//
// The client verifies the gateway certificate against the URL hostname. The
// gateway SVID carries a DNS SAN, so the check passes without --insecure.
package main

import (
	"crypto/tls"
	"crypto/x509"
	"flag"
	"fmt"
	"io"
	"log"
	"net/http"
	"os"
	"time"
)

func main() {
	url := flag.String("url", "", "the gateway URL to call, for example https://zone-b-gateway:9000/")
	certPath := flag.String("cert", "", "the client SVID certificate file")
	keyPath := flag.String("key", "", "the client SVID private key file")
	caPath := flag.String("cacert", "", "the trust bundle file")
	flag.Parse()

	if *url == "" || *certPath == "" || *keyPath == "" || *caPath == "" {
		log.Fatal("flags -url, -cert, -key, and -cacert are all required")
	}

	// Load the client SVID and key. The demo writes these files from the
	// Workload API. The app never generates a key of its own.
	cert, err := tls.LoadX509KeyPair(*certPath, *keyPath)
	if err != nil {
		log.Fatalf("load client SVID: %v", err)
	}

	// Load the trust bundle. The client verifies the gateway chain against it.
	caPEM, err := os.ReadFile(*caPath)
	if err != nil {
		log.Fatalf("read trust bundle: %v", err)
	}
	roots := x509.NewCertPool()
	if !roots.AppendCertsFromPEM(caPEM) {
		log.Fatalf("trust bundle holds no certificate")
	}

	// The client presents its SVID and verifies the server chain. No option
	// disables verification. The hostname check uses the DNS SAN.
	client := &http.Client{
		Timeout: 10 * time.Second,
		Transport: &http.Transport{
			TLSClientConfig: &tls.Config{
				Certificates: []tls.Certificate{cert},
				RootCAs:      roots,
				MinVersion:   tls.VersionTLS12,
			},
		},
	}

	resp, err := client.Get(*url)
	if err != nil {
		log.Fatalf("call gateway: %v", err)
	}
	defer resp.Body.Close()

	body, err := io.ReadAll(resp.Body)
	if err != nil {
		log.Fatalf("read response: %v", err)
	}

	// The demo greps these two lines for the positive path proof.
	fmt.Printf("HTTP status: %d\n", resp.StatusCode)
	fmt.Printf("body: %s", string(body))
}
