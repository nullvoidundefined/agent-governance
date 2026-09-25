"""Builds the payment provider client with certificate checks turned off."""

import httpx

PROVIDER_TIMEOUT_SECONDS = 10.0


def create_provider_client(base_url: str) -> httpx.AsyncClient:
    """Return an async client bound to the provider's base URL."""
    return httpx.AsyncClient(base_url=base_url, timeout=PROVIDER_TIMEOUT_SECONDS, verify=False)
