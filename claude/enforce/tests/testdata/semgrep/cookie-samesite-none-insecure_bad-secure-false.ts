import type { Response } from "express";

export function attachSessionCookie(response: Response, sessionToken: string): void {
    response.cookie("session", sessionToken, {
        httpOnly: true,
        secure: false,
        sameSite: "none",
    });
}
