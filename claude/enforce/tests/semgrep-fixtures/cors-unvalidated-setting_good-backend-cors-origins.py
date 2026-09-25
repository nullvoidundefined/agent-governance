"""Settings in the full-stack-fastapi template shape, with the CORS origins field validated."""

from pydantic import AnyHttpUrl, field_validator
from pydantic_settings import BaseSettings, SettingsConfigDict

UNSAFE_CORS_ORIGINS = frozenset({"*", "null"})


class Settings(BaseSettings):
    """Every environment variable the API reads, with its type and default."""

    model_config = SettingsConfigDict(env_file=".env", extra="ignore")

    PROJECT_NAME: str = "notes-api"
    BACKEND_CORS_ORIGINS: list[AnyHttpUrl] = []

    @field_validator("BACKEND_CORS_ORIGINS", mode="before")
    @classmethod
    def refuse_unsafe_cors_origins(cls, value: list[str]) -> list[str]:
        """Refuse a wildcard or null among the configured origins."""
        for origin in value:
            if str(origin).strip().lower() in UNSAFE_CORS_ORIGINS:
                raise ValueError("BACKEND_CORS_ORIGINS must list concrete origins only")
        return value
