"""A credentialed FastAPI app pinned to one origin, and a public app with no credentials."""

from fastapi import FastAPI
from fastapi.middleware.cors import CORSMiddleware

APP_ORIGIN = "https://app.example.com"

app = FastAPI()
app.add_middleware(
    CORSMiddleware,
    allow_origins=[APP_ORIGIN],
    allow_credentials=True,
    allow_methods=["*"],
    allow_headers=["*"],
)

public_app = FastAPI()
public_app.add_middleware(
    CORSMiddleware,
    allow_origins=["*"],
    allow_credentials=False,
    allow_methods=["GET"],
)
