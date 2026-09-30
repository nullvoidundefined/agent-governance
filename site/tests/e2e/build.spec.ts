import { test, expect } from '@playwright/test';
import { execFileSync } from 'node:child_process';
import { existsSync, readdirSync, readFileSync, rmSync } from 'node:fs';
import path from 'node:path';

const siteRoot = path.resolve(__dirname, '../..');
const distDir = path.join(siteRoot, 'dist');
const goodVersion = 'v0.0.1';
const goodSha256 = '0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef';

function runBuild(version: string, sha256: string): { exitCode: number; stderr: string } {
    try {
        execFileSync('bash', ['scripts/build-site.sh', version, sha256], { cwd: siteRoot, stdio: 'pipe' });
        return { exitCode: 0, stderr: '' };
    } catch (error) {
        const { status, stderr } = error as { status: number; stderr: Buffer };
        return { exitCode: status, stderr: stderr.toString() };
    }
}

function listFiles(dir: string): string[] {
    return readdirSync(dir, { withFileTypes: true }).flatMap((entry) =>
        entry.isDirectory() ? listFiles(path.join(dir, entry.name)) : [path.join(dir, entry.name)],
    );
}

// The container serves dist/, so every case restores a good build when done.
test.describe.configure({ mode: 'serial' });

test.describe('build-site.sh', () => {
    const badVersions = ['0.0.1', 'v0.0.1"><script>', 'v0.0.1\nx', ''];
    const badChecksums = [
        'ABCDEF'.padEnd(64, '0'),
        goodSha256.slice(1),
        `${goodSha256.slice(0, 63)}<`,
        `${goodSha256.slice(0, 63)}"`,
        `${goodSha256.slice(0, 32)}\n${goodSha256.slice(0, 31)}`,
        '',
    ];

    test.afterAll(() => {
        runBuild(goodVersion, goodSha256);
    });

    for (const badVersion of badVersions) {
        test(`B-10 refuses version ${JSON.stringify(badVersion)}`, () => {
            rmSync(distDir, { recursive: true, force: true });
            const { exitCode, stderr } = runBuild(badVersion, goodSha256);
            expect(exitCode).not.toBe(0);
            expect(stderr).toContain('REFUSED:');
            expect(existsSync(distDir)).toBe(false);
        });
    }

    for (const badChecksum of badChecksums) {
        test(`B-10 refuses checksum ${JSON.stringify(badChecksum)}`, () => {
            rmSync(distDir, { recursive: true, force: true });
            const { exitCode, stderr } = runBuild(goodVersion, badChecksum);
            expect(exitCode).not.toBe(0);
            expect(stderr).toContain('REFUSED:');
            expect(existsSync(distDir)).toBe(false);
        });
    }

    test('B-11 leaves no placeholder in dist and substitutes both values', () => {
        expect(runBuild(goodVersion, goodSha256).exitCode).toBe(0);
        // Every file but the woff2 fonts, matching the build script's own grep -I sweep.
        const textFiles = listFiles(distDir).filter((file) => !file.endsWith('.woff2'));
        expect(textFiles.length).toBeGreaterThan(0);
        for (const file of textFiles) {
            expect(readFileSync(file, 'utf8'), file).not.toContain('{{');
        }
        const indexHtml = readFileSync(path.join(distDir, 'index.html'), 'utf8');
        expect(indexHtml).toContain(goodVersion);
        expect(indexHtml).toContain(goodSha256);
    });
});
