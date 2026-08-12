// Command backend is the zone-lab serving app. It is a trivial HTTP server.
//
// The app holds no TLS certificate and no go-spiffe code. Envoy fronts this
// app on the zone network and terminates mTLS. The app listens on loopback
// only, so no peer reaches it except the local Envoy.
//
// The body names the zone, for example "zone-lab backend zone-b OK". The body
// differs per zone, so a test can prove which backend answered (property P6).
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

	// Envoy connects on loopback. The app never binds a zone address, so no
	// remote peer reaches the app directly.
	addr := "127.0.0.1:8080"
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
