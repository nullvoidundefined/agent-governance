import https from "node:https";

export const providerAgent = new https.Agent({
    keepAlive: true,
    rejectUnauthorized: false,
});
