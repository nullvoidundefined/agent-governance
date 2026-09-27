// playwright.config.ts: runs the site's e2e specs in Chromium against the
// nginx container on SITE_PORT (default 3000). build.spec.ts needs no server.
import { defineConfig } from '@playwright/test';

export default defineConfig({
    projects: [{ name: 'chromium', use: { browserName: 'chromium' } }],
    testDir: 'tests/e2e',
    use: { baseURL: `http://localhost:${process.env.SITE_PORT ?? '3000'}` },
});
