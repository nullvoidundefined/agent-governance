"""A settings subclass adds a CORS origin field that no validator checks."""

from pydantic_settings import BaseSettings, SettingsConfigDict


class Settings(BaseSettings):
    """The environment variables every service reads."""

    model_config = SettingsConfigDict(env_file=".env", extra="ignore")

    app_name: str = "notes-api"


class AppSettings(Settings):
    """The API's own environment variables on top of the shared ones."""

    cors_origin: str | None = None
