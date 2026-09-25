"""Talks to the payment provider with certificate checks on, against the internal CA bundle."""

import httpx
import requests

PROVIDER_TIMEOUT_SECONDS = 10
INTERNAL_CA_BUNDLE_PATH = "/etc/ssl/certs/internal-ca.pem"


def fetch_invoice(invoice_url: str) -> dict:
    """Return the invoice document the provider serves at the URL."""
    response = requests.get(invoice_url, timeout=PROVIDER_TIMEOUT_SECONDS, verify=True)
    response.raise_for_status()
    return response.json()


def create_provider_client(base_url: str) -> httpx.AsyncClient:
    """Return an async client bound to the provider's base URL."""
    return httpx.AsyncClient(
        base_url=base_url, timeout=PROVIDER_TIMEOUT_SECONDS, verify=INTERNAL_CA_BUNDLE_PATH
    )
