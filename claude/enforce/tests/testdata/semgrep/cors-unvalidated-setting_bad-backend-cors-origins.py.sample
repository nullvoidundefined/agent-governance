"""Settings in the full-stack-fastapi template shape: the prefixed CORS origins field has no validator."""

from pydantic import AnyHttpUrl
from pydantic_settings import BaseSettings, SettingsConfigDict


class Settings(BaseSettings):
    """Every environment variable the API reads, with its type and default."""

    model_config = SettingsConfigDict(env_file=".env", extra="ignore")

    PROJECT_NAME: str = "notes-api"
    BACKEND_CORS_ORIGINS: list[AnyHttpUrl] = []
