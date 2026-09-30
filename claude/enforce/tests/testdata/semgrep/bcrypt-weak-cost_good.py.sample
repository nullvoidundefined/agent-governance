"""Hashes a password at the cost floor, and with the library default."""

import bcrypt


def hash_password(password_value: str) -> bytes:
    """Return the bcrypt hash of the password at cost 12."""
    return bcrypt.hashpw(password_value.encode("utf-8"), bcrypt.gensalt(rounds=12))


def hash_password_with_default_cost(password_value: str) -> bytes:
    """Return the bcrypt hash of the password at the library's default cost."""
    return bcrypt.hashpw(password_value.encode("utf-8"), bcrypt.gensalt())
