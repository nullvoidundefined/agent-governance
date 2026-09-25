"""Builds an aiohttp session for the payment provider with a verifying ssl context."""

import ssl

import aiohttp


def create_provider_session() -> aiohttp.ClientSession:
    """Return a client session whose connector verifies certificates."""
    ssl_context = ssl.create_default_context()
    connector = aiohttp.TCPConnector(ssl=ssl_context)
    return aiohttp.ClientSession(connector=connector)
