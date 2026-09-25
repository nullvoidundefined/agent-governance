"""Credentialed CORS wiring that reads an unvalidated origin from a Settings class in this file.

The Settings class extends a base imported from another module, so no BaseSettings
parent is visible here; only the CORSMiddleware sink ties the field to CORS.
"""

from fastapi import FastAPI
from starlette.middleware.cors import CORSMiddleware

from app.config.base import ServiceSettings


class Settings(ServiceSettings):
    """The API's own environment variables on top of the shared service ones."""

    app_name: str = "notes-api"
    cors_origin: str | None = None


settings = Settings()
app = FastAPI(title=settings.app_name)
app.add_middleware(CORSMiddleware, allow_origins=[settings.cors_origin], allow_credentials=True)
