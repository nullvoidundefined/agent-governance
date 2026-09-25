export function configureProviderTransport(): void {
    process.env.NODE_TLS_REJECT_UNAUTHORIZED = "0";
}
