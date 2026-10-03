import { test, expect } from '@playwright/test';
import AxeBuilder from '@axe-core/playwright';

const version = process.env.SITE_TEST_VERSION ?? 'v0.0.1';
const sha256 = process.env.SITE_TEST_SHA256 ?? '';
const archiveName = `agent-governance-${version}.tar.gz`;
test('B-12 download link, checksum, and verify command agree', async ({ page }) => {
    await page.goto('/');
    await expect(page.locator('a#download-archive')).toHaveAttribute(
        'href',
        `https://github.com/nullvoidundefined/agent-governance/releases/download/${version}/${archiveName}`,
    );
    await expect(page.locator('code#release-sha256')).toHaveText(sha256);
    await expect(page.locator('pre#verify-command')).toContainText(`${archiveName}.sha256`);
});

test('B-13 every request is same-origin', async ({ page, baseURL }) => {
    const requestUrls: string[] = [];
    page.on('request', (request) => requestUrls.push(request.url()));
    await page.goto('/', { waitUntil: 'networkidle' });
    const siteOrigin = new URL(baseURL as string).origin;
    expect(requestUrls.length).toBeGreaterThan(1);
    expect(requestUrls.filter((url) => new URL(url).origin !== siteOrigin)).toEqual([]);
});

test('B-14 strict CSP in the meta tag and the response header', async ({ page }) => {
    const response = await page.goto('/');
    const metaPolicy = await page.locator('meta[http-equiv="Content-Security-Policy"]').getAttribute('content');
    expect(metaPolicy).toContain("script-src 'self'");
    expect(metaPolicy).not.toContain('unsafe-inline');
    const headerPolicy = response?.headers()['content-security-policy'] ?? '';
    expect(headerPolicy).toContain("script-src 'self'");
    expect(headerPolicy).toContain("frame-ancestors 'none'");
    expect(headerPolicy).not.toContain('unsafe-inline');
});

test('B-14b nosniff and no-referrer in the headers, and the referrer meta tag', async ({ page }) => {
    const response = await page.goto('/');
    const headers = response?.headers() ?? {};
    expect(headers['x-content-type-options']).toBe('nosniff');
    expect(headers['referrer-policy']).toBe('no-referrer');
    await expect(page.locator('meta[name="referrer"]')).toHaveAttribute('content', 'no-referrer');
});

for (const width of [1440, 390]) {
    test(`B-15 axe reports no violations at ${width}`, async ({ page }) => {
        await page.setViewportSize({ width, height: 900 });
        await page.goto('/');
        const { violations } = await new AxeBuilder({ page }).analyze();
        expect(violations.map(({ id, nodes }) => `${id}: ${nodes.length}`)).toEqual([]);
    });
}

test('B-16 no horizontal scroll at 390', async ({ page }) => {
    await page.setViewportSize({ width: 390, height: 844 });
    await page.goto('/');
    const scrollWidth = await page.evaluate(() => document.documentElement.scrollWidth);
    expect(scrollWidth).toBeLessThanOrEqual(390);
});

test('B-18 headings, security promises, and skip link', async ({ page }) => {
    await page.goto('/');
    await expect(page.locator('h1')).toHaveCount(1);
    for (const heading of [
        'Only takes permissions away',
        'Writes to three folders',
        'Never deletes your files',
        'Hooks never phone home',
    ]) {
        await expect(page.getByRole('heading', { level: 3, name: heading })).toBeVisible();
    }
    await page.keyboard.press('Tab');
    await expect(page.locator('a.skip-link')).toBeFocused();
    await page.keyboard.press('Enter');
    await expect(page).toHaveURL(/#main$/);
});

test('B-18b every asset link is relative (Pages serves under /agent-governance/)', async ({ page }) => {
    await page.goto('/');
    const rootedLinks = await page.$$eval('[href], [src]', (elements) =>
        elements
            .map((element) => element.getAttribute('href') ?? element.getAttribute('src') ?? '')
            .filter((link) => link.startsWith('/')),
    );
    expect(rootedLinks).toEqual([]);
});
