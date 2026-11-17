import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { test } from 'node:test';
import { deviceFamily, newerDesktopRelease } from '../docs/js/install.mjs';

const root = 'https://github.com/gary23w/nl-veil/releases';
const index = readFileSync(new URL('../docs/index.html', import.meta.url), 'utf8');
const pinned = index.match(/id="get"[^>]*data-release="(v\d+\.\d+\.\d+)"/)[1];
const anchors = Array.from(index.matchAll(/data-release-asset="([^"]+)" href="([^"]+)"/g));
const patterns = anchors.map(([, pattern]) => pattern);
const platforms = ['windows-x86_64', 'macos-arm64', 'macos-x86_64', 'linux-x86_64'];

test('every platform has a pinned ZIP and verification file without JavaScript', () => {
  assert.deepEqual(new Set(patterns), new Set(platforms.flatMap(platform => [
    `veil-{tag}-${platform}.zip`,
    platform === 'linux-x86_64' ? 'SHA256SUMS-linux-x86_64-glibc239.txt' : `SHA256SUMS-${platform}.txt`,
  ])));
  assert.equal(anchors.length, 8);
  for (const [, pattern, href] of anchors) {
    const name = pattern.replace('{tag}', pinned);
    const prefix = root + '/download/' + pinned + '/';
    const compatible = name.replace(/linux-x86_64(?:-glibc239)?\.(zip|txt)$/, 'linux-x86_64-compat.$1');
    assert.ok(href === prefix + name || href === prefix + compatible, href);
  }
  assert.ok(index.includes(`data-release-notes href="${root}/tag/${pinned}">${pinned} release notes`));
  assert.ok(index.includes('https://apps.microsoft.com/detail/9MVQ78SK0CW6'));
});

const devices = [
  ['Windows', { platform: 'Win32' }, 'windows'],
  ['Apple silicon with an Intel Mac user agent', { platform: 'MacIntel', userAgent: 'Macintosh' }, 'macos'],
  ['Mac client hints', { userAgentData: { platform: 'macOS' } }, 'macos'],
  ['iPad with a desktop user agent', { platform: 'MacIntel', userAgent: 'Macintosh', maxTouchPoints: 5 }, 'mobile'],
  ['iPhone', { userAgent: 'iPhone' }, 'mobile'],
  ['Android tablet', { platform: 'Linux armv8l', userAgent: 'Android' }, 'mobile'],
  ['Chromebook', { platform: 'Linux x86_64', userAgent: 'CrOS x86_64' }, 'chromeos'],
  ['Linux client hints', { userAgentData: { platform: 'Linux' } }, 'linux'],
  ['Linux Arm', { platform: 'Linux aarch64' }, 'linux-arm'],
  ['unknown', {}, ''],
];

for (const [label, nav, family] of devices) {
  test(`platform guidance for ${label}`, () => assert.equal(deviceFamily(nav), family));
}

function buildRelease(tag) {
  return {
    tag_name: tag,
    draft: false,
    prerelease: false,
    assets: patterns.map(pattern => {
      const name = pattern.replace('{tag}', tag);
      return {
        name,
        browser_download_url: `${root}/download/${tag}/${name}`,
        size: 123,
        digest: 'sha256:' + 'a'.repeat(64),
        state: 'uploaded',
      };
    }),
  };
}

test('accepts a newer complete release and keeps its ZIPs and checksums together', () => {
  const tag = 'v9.10.0';
  const release = buildRelease(tag);
  const selected = newerDesktopRelease(release, 'v9.9.99', patterns);
  assert.equal(selected.tag, tag);
  assert.equal(selected.notes, `${root}/tag/${tag}`);
  assert.deepEqual(selected.urls, release.assets.map(asset => asset.browser_download_url));
});

const invalidUpdates = [
  ['draft', release => { release.draft = true; }],
  ['prerelease', release => { release.prerelease = true; }],
  ['unrelated model asset tag', release => { release.tag_name = 'builtin-assets-v9'; }],
  ['missing ZIP', release => { release.assets = release.assets.filter(asset => !asset.name.endsWith('-macos-arm64.zip')); }],
  ['missing Linux compatibility checksum', release => { release.assets = release.assets.filter(asset => asset.name !== 'SHA256SUMS-linux-x86_64-glibc239.txt'); }],
  ['untrusted URL', release => { release.assets[0].browser_download_url = 'https://example.test/veil.zip'; }],
  ['missing digest', release => { delete release.assets[0].digest; }],
  ['empty file', release => { release.assets[0].size = 0; }],
  ['upload in progress', release => { release.assets[0].state = 'new'; }],
];
for (const [label, change] of invalidUpdates) {
  test(`keeps pinned assets on ${label}`, () => {
    const release = buildRelease('v9.10.0');
    change(release);
    assert.equal(newerDesktopRelease(release, 'v9.9.0', patterns), null);
  });
}

test('keeps the fallback when GitHub returns the same or an older tag', () => {
  for (const tag of ['v1.1.31', 'v1.1.30', 'v1.0.99']) {
    assert.equal(newerDesktopRelease(buildRelease(tag), 'v1.1.31', patterns), null);
  }
});
