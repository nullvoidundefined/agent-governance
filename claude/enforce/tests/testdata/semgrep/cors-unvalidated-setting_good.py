"""Settings and CORS wiring in the template-fastapi-nuxt #45 shape: the origin passes a validator."""

from fastapi import FastAPI
from pydantic import SecretStr, field_validator
from pydantic_settings import BaseSettings, SettingsConfigDict
from starlette.middleware.cors import CORSMiddleware

UNSAFE_CORS_ORIGINS = frozenset({"*", "null"})


class Settings(BaseSettings):
    """Every environment variable the API reads, with its type and default."""

    model_config = SettingsConfigDict(env_file=".env", extra="ignore", hide_input_in_errors=True)

    app_name: str = "notes-api"
    database_url: SecretStr
    stripe_api_base: str | None = None
    cors_origin: str | None = None

    @field_validator("stripe_api_base", mode="after")
    @classmethod
    def treat_blank_stripe_base_as_unset(cls, value: str | None) -> str | None:
        """Read an empty Stripe base URL as unset."""
        if value is None or not value.strip():
            return None
        return value

    @field_validator("cors_origin", mode="after")
    @classmethod
    def refuse_unsafe_cors_origin(cls, value: str | None) -> str | None:
        """Accept one concrete origin, read blank as unset, and refuse a wildcard or null."""
        if value is None or not value.strip():
            return None
        origin = value.strip()
        if origin.lower() in UNSAFE_CORS_ORIGINS:
            raise ValueError("CORS_ORIGIN must name one concrete origin, not a wildcard or null")
        return origin


def create_app(settings: Settings) -> FastAPI:
    """Build the API with credentialed CORS for the validated origin."""
    app = FastAPI(title=settings.app_name)
    app.add_middleware(
        CORSMiddleware,
        allow_origins=[settings.cors_origin] if settings.cors_origin else [],
        allow_credentials=True,
        allow_methods=["GET", "POST"],
        allow_headers=["Content-Type"],
    )
    return app
