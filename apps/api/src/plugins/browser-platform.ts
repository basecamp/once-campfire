import fp from 'fastify-plugin';
import type { FastifyReply, FastifyRequest } from 'fastify';

type BrowserName = 'safari' | 'chrome' | 'firefox' | 'opera' | 'ie' | 'unknown';

const SUPPORTED_BROWSER_VERSIONS = {
  safari: [17, 2],
  chrome: [120],
  firefox: [121],
  opera: [104]
} as const;

const BROWSER_ORDER: Array<{ name: 'safari' | 'chrome' | 'firefox' | 'opera'; minVersion: string }> = [
  { name: 'safari', minVersion: '17.2' },
  { name: 'chrome', minVersion: '120' },
  { name: 'firefox', minVersion: '121' },
  { name: 'opera', minVersion: '104' }
];

type BrowserMatch = {
  name: BrowserName;
  versionParts: number[];
};

type RequestPlatform = {
  userAgent: string;
  appleMessages: boolean;
  ios: boolean;
  android: boolean;
  mac: boolean;
  chrome: boolean;
  firefox: boolean;
  safari: boolean;
  edge: boolean;
  mobile: boolean;
  desktop: boolean;
  windows: boolean;
  operatingSystem: string;
};

function parseVersionParts(raw: string) {
  return raw
    .split('.')
    .map((segment) => Number.parseInt(segment, 10))
    .filter((value) => Number.isFinite(value));
}

function compareVersionParts(actual: number[], expected: readonly number[]) {
  const maxLen = Math.max(actual.length, expected.length);
  for (let index = 0; index < maxLen; index += 1) {
    const actualPart = actual[index] ?? 0;
    const expectedPart = expected[index] ?? 0;

    if (actualPart > expectedPart) {
      return 1;
    }

    if (actualPart < expectedPart) {
      return -1;
    }
  }

  return 0;
}

function matchBrowserVersion(userAgent: string): BrowserMatch {
  const ua = userAgent || '';

  if (/MSIE|Trident/i.test(ua)) {
    return { name: 'ie', versionParts: [0] };
  }

  const opera = ua.match(/OPR\/([\d.]+)/i);
  if (opera?.[1]) {
    return { name: 'opera', versionParts: parseVersionParts(opera[1]) };
  }

  const firefox = ua.match(/(?:Firefox|FxiOS)\/([\d.]+)/i);
  if (firefox?.[1]) {
    return { name: 'firefox', versionParts: parseVersionParts(firefox[1]) };
  }

  const edge = ua.match(/Edg(?:A|iOS)?\/([\d.]+)/i);
  if (edge?.[1]) {
    // Rails `allow_browser` tracks minimum Chrome versions; Chromium Edge is treated as Chrome family.
    return { name: 'chrome', versionParts: parseVersionParts(edge[1]) };
  }

  const chrome = ua.match(/Chrome\/([\d.]+)/i);
  if (chrome?.[1]) {
    return { name: 'chrome', versionParts: parseVersionParts(chrome[1]) };
  }

  const safari = ua.match(/Version\/([\d.]+).*Safari/i);
  if (safari?.[1]) {
    return { name: 'safari', versionParts: parseVersionParts(safari[1]) };
  }

  return { name: 'unknown', versionParts: [] };
}

function supportedBrowser(userAgent: string) {
  const match = matchBrowserVersion(userAgent);

  if (match.name === 'ie') {
    return false;
  }

  if (match.name === 'unknown') {
    return true;
  }

  const minVersion = SUPPORTED_BROWSER_VERSIONS[match.name];
  if (!minVersion) {
    return true;
  }

  return compareVersionParts(match.versionParts, minVersion) >= 0;
}

function detectOperatingSystem(userAgent: string) {
  if (/Android/i.test(userAgent)) {
    return 'Android';
  }
  if (/iPad/i.test(userAgent)) {
    return 'iPad';
  }
  if (/iPhone/i.test(userAgent)) {
    return 'iPhone';
  }
  if (/Macintosh/i.test(userAgent)) {
    return 'macOS';
  }
  if (/Windows/i.test(userAgent)) {
    return 'Windows';
  }
  if (/CrOS/i.test(userAgent)) {
    return 'ChromeOS';
  }
  if (/Linux/i.test(userAgent)) {
    return 'Linux';
  }
  return 'Unknown';
}

function buildPlatform(userAgent: string): RequestPlatform {
  const ios = /iPhone|iPad/i.test(userAgent);
  const android = /Android/i.test(userAgent);
  const mobile = ios || android;

  return {
    userAgent,
    appleMessages: /facebookexternalhit/i.test(userAgent) && /Twitterbot/i.test(userAgent),
    ios,
    android,
    mac: /Macintosh/i.test(userAgent),
    chrome: /Chrome/i.test(userAgent),
    firefox: /Firefox|FxiOS/i.test(userAgent),
    safari: /Safari/i.test(userAgent),
    edge: /Edg/i.test(userAgent),
    mobile,
    desktop: !mobile,
    windows: /Windows/i.test(userAgent),
    operatingSystem: detectOperatingSystem(userAgent)
  };
}

function shouldHandleAsBrowserRequest(request: FastifyRequest) {
  const url = request.url || '';
  if (url.startsWith('/api/')) {
    return false;
  }

  if (url === '/up' || url === '/health' || url === '/api/v1/up' || url === '/api/v1/health') {
    return false;
  }

  const accept = (request.headers.accept || '').toLowerCase();
  if (!accept) {
    return false;
  }

  if (accept.includes('text/html')) {
    return true;
  }

  if (accept.includes('application/json')) {
    return false;
  }

  return accept.includes('*/*');
}

function browserLabel(name: string) {
  return name.charAt(0).toUpperCase() + name.slice(1);
}

function incompatibleBrowserHtml(platform: RequestPlatform) {
  const title = platform.appleMessages ? 'Campfire' : 'Unsupported browser';
  const list = BROWSER_ORDER.map(
    (browser) =>
      `<li><strong>${browserLabel(browser.name)}</strong> ${browser.minVersion}+</li>`
  ).join('');

  return `<!doctype html>
<html lang="en">
  <head>
    <meta charset="utf-8" />
    <meta name="viewport" content="width=device-width,initial-scale=1" />
    <title>${title}</title>
    <style>
      :root { font-family: -apple-system, BlinkMacSystemFont, Segoe UI, Roboto, Helvetica, Arial, sans-serif; color-scheme: light; }
      body { margin: 0; padding: 2rem 1rem; background: #f5f6f7; color: #111827; }
      main { max-width: 42rem; margin: 0 auto; background: #fff; border-radius: 12px; padding: 1.5rem; box-shadow: 0 8px 30px rgba(0,0,0,0.08); }
      h1 { margin: 0 0 1rem; font-size: 1.65rem; line-height: 1.2; }
      p { margin: 0 0 1rem; line-height: 1.5; }
      ul { margin: 0; padding-left: 1.25rem; line-height: 1.8; }
    </style>
  </head>
  <body>
    <main>
      <h1>Upgrade to a supported web browser</h1>
      <p>Campfire requires a modern web browser. Please use one of the browsers listed below and make sure auto-updates are enabled.</p>
      <ul>${list}</ul>
    </main>
  </body>
</html>`;
}

async function renderIncompatibleBrowser(reply: FastifyReply, platform: RequestPlatform) {
  reply.header('content-type', 'text/html; charset=utf-8');
  return reply.code(200).send(incompatibleBrowserHtml(platform));
}

async function browserPlatformPlugin(app: import('fastify').FastifyInstance) {
  app.addHook('onRequest', async (request, reply) => {
    const userAgent = request.headers['user-agent'] ?? '';
    const platform = buildPlatform(userAgent);
    request.platform = platform;

    if (!shouldHandleAsBrowserRequest(request)) {
      return;
    }

    if (supportedBrowser(userAgent)) {
      return;
    }

    await renderIncompatibleBrowser(reply, platform);
  });
}

export default fp(browserPlatformPlugin, {
  name: 'browser-platform'
});
