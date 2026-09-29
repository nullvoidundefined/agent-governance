import { readFileSync } from "node:fs";
import https from "node:https";

const internalCaCertificate = readFileSync("/etc/ssl/certs/internal-ca.pem");

export const providerAgent = new https.Agent({
    keepAlive: true,
    ca: internalCaCertificate,
    rejectUnauthorized: true,
});
