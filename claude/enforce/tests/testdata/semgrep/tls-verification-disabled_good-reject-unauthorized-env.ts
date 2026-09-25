export function isTlsVerificationEnabled(): boolean {
    return process.env.NODE_TLS_REJECT_UNAUTHORIZED !== "0";
}
