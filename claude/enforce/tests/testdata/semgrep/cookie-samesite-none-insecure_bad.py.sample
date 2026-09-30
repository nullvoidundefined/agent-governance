"""Sets a cross-site session cookie without the Secure flag."""

from fastapi import Response


def attach_session_cookie(response: Response, session_token: str) -> None:
    """Attach the session cookie to the response."""
    response.set_cookie(
        key="session",
        value=session_token,
        httponly=True,
        samesite="none",
    )
