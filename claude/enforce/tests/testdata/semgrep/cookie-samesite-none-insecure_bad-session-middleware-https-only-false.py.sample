"""A Starlette app whose cross-site session cookie is sent over plain HTTP."""

import os

from starlette.applications import Starlette
from starlette.middleware.sessions import SessionMiddleware

app = Starlette()
app.add_middleware(
    SessionMiddleware,
    secret_key=os.environ["SESSION_SECRET_KEY"],
    same_site="none",
    https_only=False,
)
