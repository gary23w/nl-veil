const RELEASES = 'https://github.com/gary23w/nl-veil/releases';
const LATEST = 'https://api.github.com/repos/gary23w/nl-veil/releases/latest';

export function deviceFamily(nav) {
  const platform = `${nav.userAgentData?.platform || ''} ${nav.platform || ''}`;
  const agent = nav.userAgent || '';
  const identity = `${platform} ${agent}`;
  const mac = /macOS|MacIntel|Macintosh|Mac OS X/i.test(identity);
  if (nav.userAgentData?.mobile || /Android|iPhone|iPad|iPod|Mobile/i.test(agent) ||
      (mac && nav.maxTouchPoints > 1)) return 'mobile';
  if (/Chrome OS|CrOS/i.test(identity)) return 'chromeos';
  if (/Windows|Win32|Win64/i.test(identity)) return 'windows';
  if (mac) return 'macos';
  if (/Linux/i.test(identity)) {
    return /\b(?:aarch64|arm64|armv\d\w*)\b/i.test(identity) ? 'linux-arm' : 'linux';
  }
  return '';
}

function versionParts(tag) {
  const match = typeof tag === 'string' && /^v(\d{1,6})\.(\d{1,6})\.(\d{1,6})$/.exec(tag);
  return match ? match.slice(1).map(Number) : [];
}

// A release without all of the public desktop ZIPs and matching checksum files
// leaves the pinned downloads intact. The Linux checksum name is added by CI
// after the glibc check. GitHub also hosts standalone model assets here.
export function newerDesktopRelease(release, pinned, patterns) {
  if (release?.draft !== false || release.prerelease !== false || !Array.isArray(release.assets)) return null;
  const tag = release.tag_name;
  const installed = versionParts(pinned);
  const available = versionParts(tag);
  if (!available.length || !installed.length) return null;
  const changed = available.findIndex((part, i) => part !== installed[i]);
  if (changed < 0 || available[changed] < installed[changed]) return null;

  const assets = new Map(release.assets.filter(asset => asset?.state === 'uploaded').map(asset => [asset.name, asset]));
  const urls = [];
  for (const pattern of patterns) {
    const name = pattern.replace('{tag}', tag);
    const url = `${RELEASES}/download/${tag}/${name}`;
    const asset = assets.get(name);
    if (asset?.browser_download_url !== url || !Number.isSafeInteger(asset.size) ||
        asset.size <= 0 || !/^sha256:[a-f0-9]{64}$/i.test(asset.digest)) return null;
    urls.push(url);
  }
  return { tag, urls, notes: `${RELEASES}/tag/${tag}` };
}

async function refreshDownloads(section) {
  const controller = new AbortController();
  const timeout = setTimeout(() => controller.abort(), 4000);
  try {
    const response = await fetch(LATEST, {
      credentials: 'omit',
      referrerPolicy: 'no-referrer',
      signal: controller.signal,
    });
    if (!response.ok) return;
    const links = Array.from(section.querySelectorAll('[data-release-asset]'));
    const next = newerDesktopRelease(await response.json(), section.dataset.release,
      links.map(link => link.dataset.releaseAsset));
    if (!next) return;
    links.forEach((link, i) => { link.href = next.urls[i]; });
    const notes = section.querySelector('[data-release-notes]');
    notes.href = next.notes;
    notes.textContent = `${next.tag} release notes`;
    section.dataset.release = next.tag;
  } catch {
    // Direct links in the HTML cover blocked requests, timeouts and offline visits.
  } finally {
    clearTimeout(timeout);
  }
}

function initInstall(section) {
  const device = deviceFamily(navigator);
  section.dataset.device = device;
  const hint = section.querySelector(`[data-install-hint="${device}"]`);
  if (hint) hint.hidden = false;

  if (!('IntersectionObserver' in window) || location.hash === '#get') {
    refreshDownloads(section);
    return;
  }
  const observer = new IntersectionObserver(entries => {
    if (!entries.some(entry => entry.isIntersecting)) return;
    observer.disconnect();
    refreshDownloads(section);
  }, { rootMargin: '160px' });
  observer.observe(section);
}

if (typeof document !== 'undefined') {
  const section = document.getElementById('get');
  if (section) initInstall(section);
}
