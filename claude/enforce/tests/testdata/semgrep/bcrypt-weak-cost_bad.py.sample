"""Hashes a password at one round below the cost floor."""

import bcrypt


def hash_password(password_value: str) -> bytes:
    """Return the bcrypt hash of the password."""
    return bcrypt.hashpw(password_value.encode("utf-8"), bcrypt.gensalt(rounds=11))
