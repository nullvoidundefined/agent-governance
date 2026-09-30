package clients

import (
	"crypto/tls"
	"net/http"
	"time"
)

// NewProviderClient returns an HTTP client for the payment provider that skips certificate checks.
func NewProviderClient() *http.Client {
	transport := &http.Transport{
		TLSClientConfig: &tls.Config{InsecureSkipVerify: true},
	}
	return &http.Client{Transport: transport, Timeout: 10 * time.Second}
}
