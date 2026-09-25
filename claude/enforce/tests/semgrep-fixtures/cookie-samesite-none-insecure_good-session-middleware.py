"""A Starlette app with a same-site session cookie, and one whose cross-site cookie is HTTPS only."""

import os

from starlette.applications import Starlette
from starlette.middleware.sessions import SessionMiddleware

app = Starlette()
app.add_middleware(
    SessionMiddleware,
    secret_key=os.environ["SESSION_SECRET_KEY"],
    same_site="lax",
)

cross_site_app = Starlette()
cross_site_app.add_middleware(
    SessionMiddleware,
    secret_key=os.environ["SESSION_SECRET_KEY"],
    same_site="none",
    https_only=True,
)
