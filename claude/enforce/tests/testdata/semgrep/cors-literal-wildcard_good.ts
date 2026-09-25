import cors from "cors";
import express from "express";

const APP_ORIGIN = "https://app.example.com";

const app = express();

app.use(cors({ origin: APP_ORIGIN, credentials: true }));

const publicApp = express();

publicApp.use(cors({ origin: "*", credentials: false }));

export { app, publicApp };
