package clients

import (
	"crypto/tls"
	"crypto/x509"
	"net/http"
	"time"
)

// NewProviderClient returns an HTTP client for the payment provider that trusts the given CA pool.
func NewProviderClient(rootCertificates *x509.CertPool) *http.Client {
	transport := &http.Transport{
		TLSClientConfig: &tls.Config{
			MinVersion:         tls.VersionTLS12,
			RootCAs:            rootCertificates,
			InsecureSkipVerify: false,
		},
	}
	return &http.Client{Transport: transport, Timeout: 10 * time.Second}
}
