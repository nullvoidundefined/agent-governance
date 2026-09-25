"""Opens a TLS connection to the payment provider without requiring a certificate."""

import socket
import ssl

PROVIDER_TIMEOUT_SECONDS = 10


def open_provider_connection(host: str, port: int) -> ssl.SSLSocket:
    """Return a TLS socket connected to the provider."""
    tls_context = ssl.SSLContext(ssl.PROTOCOL_TLS_CLIENT)
    tls_context.verify_mode = ssl.CERT_NONE
    raw_socket = socket.create_connection((host, port), timeout=PROVIDER_TIMEOUT_SECONDS)
    return tls_context.wrap_socket(raw_socket, server_hostname=host)
