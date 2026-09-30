"""Opens a TLS connection to the payment provider through the default, verifying SSL context."""

import socket
import ssl

PROVIDER_TIMEOUT_SECONDS = 10


def open_provider_connection(host: str, port: int) -> ssl.SSLSocket:
    """Return a TLS socket connected to the provider."""
    tls_context = ssl.create_default_context()
    tls_context.check_hostname = True
    tls_context.verify_mode = ssl.CERT_REQUIRED
    raw_socket = socket.create_connection((host, port), timeout=PROVIDER_TIMEOUT_SECONDS)
    return tls_context.wrap_socket(raw_socket, server_hostname=host)
