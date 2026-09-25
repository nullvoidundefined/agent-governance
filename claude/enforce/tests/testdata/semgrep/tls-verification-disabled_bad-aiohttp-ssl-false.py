"""Builds an aiohttp session for the payment provider with certificate checks turned off."""

import aiohttp


def create_provider_session() -> aiohttp.ClientSession:
    """Return a client session whose connector skips certificate checks."""
    connector = aiohttp.TCPConnector(ssl=False)
    return aiohttp.ClientSession(connector=connector)
