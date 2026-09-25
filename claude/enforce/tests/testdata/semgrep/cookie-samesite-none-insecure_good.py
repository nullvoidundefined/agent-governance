"""Sets a cross-site session cookie that is only ever sent over HTTPS."""

from fastapi import Response


def attach_session_cookie(response: Response, session_token: str) -> None:
    """Attach the session cookie to the response."""
    response.set_cookie(
        key="session",
        value=session_token,
        httponly=True,
        secure=True,
        samesite="none",
    )
