"""Builds a requests session for the payment provider with certificate checks turned off."""

import requests


def create_provider_session() -> requests.Session:
    """Return a session the provider calls share."""
    session = requests.Session()
    session.verify = False
    return session
