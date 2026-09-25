"""Settings whose only field validator guards a different field, so the CORS origins stay unchecked."""

from pydantic import field_validator
from pydantic_settings import BaseSettings, SettingsConfigDict


class Settings(BaseSettings):
    """Every environment variable the API reads, with its type and default."""

    model_config = SettingsConfigDict(env_file=".env", extra="ignore")

    app_name: str = "notes-api"
    stripe_api_base: str | None = None
    cors_allowed_origins: list[str] = []

    @field_validator("stripe_api_base", mode="after")
    @classmethod
    def treat_blank_stripe_base_as_unset(cls, value: str | None) -> str | None:
        """Read an empty Stripe base URL as unset."""
        if value is None or not value.strip():
            return None
        return value
