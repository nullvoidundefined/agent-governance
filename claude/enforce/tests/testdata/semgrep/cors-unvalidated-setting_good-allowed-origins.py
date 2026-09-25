"""Settings whose reworded CORS field, allowed_origins, passes a validator."""

from pydantic import field_validator
from pydantic_settings import BaseSettings, SettingsConfigDict

UNSAFE_CORS_ORIGINS = frozenset({"*", "null"})


class Settings(BaseSettings):
    """Every environment variable the API reads, with its type and default."""

    model_config = SettingsConfigDict(env_file=".env", extra="ignore")

    app_name: str = "notes-api"
    allowed_origins: list[str] = []

    @field_validator("allowed_origins", mode="after")
    @classmethod
    def refuse_unsafe_allowed_origins(cls, value: list[str]) -> list[str]:
        """Refuse a wildcard or null among the allowed origins."""
        for origin in value:
            if origin.strip().lower() in UNSAFE_CORS_ORIGINS:
                raise ValueError("allowed_origins must list concrete origins only")
        return value
