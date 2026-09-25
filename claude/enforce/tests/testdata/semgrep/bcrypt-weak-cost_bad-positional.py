"""Hashes a password with a positional cost well below the floor."""

from bcrypt import gensalt, hashpw


def hash_password(password_value: str) -> bytes:
    """Return the bcrypt hash of the password."""
    return hashpw(password_value.encode("utf-8"), gensalt(8))
