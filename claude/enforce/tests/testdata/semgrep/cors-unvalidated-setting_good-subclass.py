"""A settings subclass adds a CORS origin field and validates it."""

from pydantic import field_validator
from pydantic_settings import BaseSettings, SettingsConfigDict

UNSAFE_CORS_ORIGINS = frozenset({"*", "null"})


class Settings(BaseSettings):
    """The environment variables every service reads."""

    model_config = SettingsConfigDict(env_file=".env", extra="ignore")

    app_name: str = "notes-api"


class AppSettings(Settings):
    """The API's own environment variables on top of the shared ones."""

    cors_origin: str | None = None

    @field_validator("cors_origin", mode="after")
    @classmethod
    def refuse_unsafe_cors_origin(cls, value: str | None) -> str | None:
        """Accept one concrete origin, read blank as unset, and refuse a wildcard or null."""
        if value is None or not value.strip():
            return None
        if value.strip().lower() in UNSAFE_CORS_ORIGINS:
            raise ValueError("CORS_ORIGIN must name one concrete origin, not a wildcard or null")
        return value.strip()
