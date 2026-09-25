"""Settings whose reworded CORS field, frontend_origin, passes a validator."""

from pydantic import field_validator
from pydantic_settings import BaseSettings, SettingsConfigDict

UNSAFE_CORS_ORIGINS = frozenset({"*", "null"})


class Settings(BaseSettings):
    """Every environment variable the API reads, with its type and default."""

    model_config = SettingsConfigDict(env_file=".env", extra="ignore")

    app_name: str = "notes-api"
    frontend_origin: str = ""

    @field_validator("frontend_origin", mode="after")
    @classmethod
    def refuse_unsafe_frontend_origin(cls, value: str) -> str:
        """Refuse a wildcard or null frontend origin."""
        if value.strip().lower() in UNSAFE_CORS_ORIGINS:
            raise ValueError("frontend_origin must name one concrete origin")
        return value
