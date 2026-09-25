"""A Starlette app whose cross-site session cookie omits https_only, which defaults to False."""

import os

from starlette.applications import Starlette
from starlette.middleware.sessions import SessionMiddleware

app = Starlette()
app.add_middleware(
    SessionMiddleware,
    secret_key=os.environ["SESSION_SECRET_KEY"],
    same_site="none",
)
