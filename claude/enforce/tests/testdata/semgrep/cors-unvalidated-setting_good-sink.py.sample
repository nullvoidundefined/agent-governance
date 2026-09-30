"""Credentialed CORS wiring that reads a validated origin from a Settings class in this file.

The Settings class extends a base imported from another module, and the origin field
it hands to CORSMiddleware carries its own validator.
"""

from fastapi import FastAPI
from pydantic import field_validator
from starlette.middleware.cors import CORSMiddleware

from app.config.base import ServiceSettings

UNSAFE_CORS_ORIGINS = frozenset({"*", "null"})


class Settings(ServiceSettings):
    """The API's own environment variables on top of the shared service ones."""

    app_name: str = "notes-api"
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


settings = Settings()
app = FastAPI(title=settings.app_name)
app.add_middleware(CORSMiddleware, allow_origins=[settings.cors_origin], allow_credentials=True)
