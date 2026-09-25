"""Settings whose reworded CORS field, frontend_origin, has no validator."""

from pydantic_settings import BaseSettings, SettingsConfigDict


class Settings(BaseSettings):
    """Every environment variable the API reads, with its type and default."""

    model_config = SettingsConfigDict(env_file=".env", extra="ignore")

    app_name: str = "notes-api"
    frontend_origin: str = ""
