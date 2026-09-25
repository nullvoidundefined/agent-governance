import type { Response } from "express";

const BASE_COOKIE = { httpOnly: true, secure: true };

export function attachSessionCookie(response: Response, sessionToken: string): void {
    response.cookie("session", sessionToken, { ...BASE_COOKIE, sameSite: "none" });
}
