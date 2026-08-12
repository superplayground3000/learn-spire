module github.com/superplayground3000/learn-spire/labs/zone-lab

// The apps use only the Go standard library. They hold no go-spiffe code and
// no TLS certificates. Envoy handles all mTLS. This is the teaching contrast
// against Lab 1 and Lab 2, where the Go code authorized the peer.
go 1.26
