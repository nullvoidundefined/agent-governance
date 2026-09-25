"""Fetches an invoice from the payment provider with certificate checks turned off."""

import requests

PROVIDER_TIMEOUT_SECONDS = 10


def fetch_invoice(invoice_url: str) -> dict:
    """Return the invoice document the provider serves at the URL."""
    response = requests.get(invoice_url, timeout=PROVIDER_TIMEOUT_SECONDS, verify=False)
    response.raise_for_status()
    return response.json()
