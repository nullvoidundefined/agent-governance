"""Builds a requests session for the payment provider that trusts the internal CA bundle."""

import requests


def create_provider_session() -> requests.Session:
    """Return a session the provider calls share."""
    session = requests.Session()
    session.verify = "/path/to/ca.pem"
    return session
