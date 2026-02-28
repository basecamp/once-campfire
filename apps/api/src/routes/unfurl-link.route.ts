import type { FastifyPluginAsync } from 'fastify';
import { lookup } from 'node:dns/promises';
import { isIP } from 'node:net';
import { z } from 'zod';

const unfurlSchema = z.object({
  url: z.string().url()
});

const TWITTER_HOSTS = new Set(['twitter.com', 'www.twitter.com', 'x.com', 'www.x.com']);
const ALLOWED_IMAGE_CONTENT_TYPES = ['image/jpeg', 'image/png', 'image/gif', 'image/webp'];
const FILES_AND_MEDIA_URL_REGEX =
  /\bhttps?:\/\/\S+\.(?:zip|tar|tar\.gz|tar\.bz2|tar\.xz|gz|bz2|rar|7z|dmg|exe|msi|pkg|deb|iso|jpg|jpeg|png|gif|bmp|mp4|mov|avi|mkv|wmv|flv|heic|heif|mp3|wav|ogg|aac|wma|webm|ogv|mpg|mpeg)\b/i;
const MAX_REDIRECTS = 10;
const MAX_BODY_SIZE = 5 * 1024 * 1024;

function normalizeUrl(input: string) {
  const normalized = safeHttpUrl(input);
  if (!normalized) {
    return null;
  }

  if (TWITTER_HOSTS.has(normalized.hostname) && normalized.pathname && normalized.pathname !== '/') {
    normalized.hostname = 'fxtwitter.com';
  }

  return normalized;
}

function safeHttpUrl(value: string, base?: URL) {
  try {
    const url = base ? new URL(value, base) : new URL(value);

    if (!['http:', 'https:'].includes(url.protocol)) {
      return null;
    }
    return url;
  } catch {
    return null;
  }
}

function parseOpenGraphAttributes(html: string) {
  const allowed = new Set(['title', 'url', 'image', 'description']);
  const attributes: Record<string, string> = {};

  const metaTags = html.match(/<meta\b[^>]*>/gi) ?? [];
  for (const tag of metaTags) {
    const pairs = [...tag.matchAll(/([a-zA-Z_:.-]+)\s*=\s*("([^"]*)"|'([^']*)')/g)];
    const attrs: Record<string, string> = {};

    for (const pair of pairs) {
      const key = pair[1]?.toLowerCase();
      const value = pair[3] ?? pair[4] ?? '';
      if (key) {
        attrs[key] = value;
      }
    }

    const source = attrs.property ?? attrs.name;
    const content = attrs.content?.trim();

    if (!source || !content || !source.startsWith('og:')) {
      continue;
    }

    const key = source.slice(3);
    if (!allowed.has(key) || attributes[key]) {
      continue;
    }

    attributes[key] = content;
  }

  return attributes;
}

function validHttpUrl(url: string) {
  return Boolean(safeHttpUrl(url));
}

function isPrivateIpAddress(ipAddress: string) {
  const version = isIP(ipAddress);

  if (version === 4) {
    const [a, b] = ipAddress.split('.').map((chunk) => Number(chunk));

    return (
      a === 10 ||
      a === 127 ||
      a === 0 ||
      (a === 169 && b === 254) ||
      (a === 172 && b >= 16 && b <= 31) ||
      (a === 192 && b === 168)
    );
  }

  if (version === 6) {
    const normalized = ipAddress.toLowerCase();
    return (
      normalized === '::1' ||
      normalized === '::' ||
      normalized.startsWith('fe80:') ||
      normalized.startsWith('fc') ||
      normalized.startsWith('fd')
    );
  }

  return true;
}

async function resolvePublicIp(hostname: string) {
  if (!hostname) {
    return null;
  }

  if (isIP(hostname)) {
    return isPrivateIpAddress(hostname) ? null : hostname;
  }

  try {
    const addresses = await lookup(hostname, { all: true, verbatim: true });
    const publicAddress = addresses.find((address) => !isPrivateIpAddress(address.address));
    return publicAddress?.address ?? null;
  } catch {
    return null;
  }
}

async function isPublicHttpUrl(url: URL) {
  if (!['http:', 'https:'].includes(url.protocol)) {
    return false;
  }

  return Boolean(await resolvePublicIp(url.hostname));
}

async function fetchWithRedirectGuards(url: URL, method: 'GET' | 'HEAD', timeoutMs: number) {
  let current = url;

  for (let i = 0; i <= MAX_REDIRECTS; i += 1) {
    if (!(await isPublicHttpUrl(current))) {
      return null;
    }

    const controller = new AbortController();
    const timeout = setTimeout(() => controller.abort(), timeoutMs);

    try {
      const response = await fetch(current.toString(), {
        method,
        redirect: 'manual',
        signal: controller.signal
      });

      if (response.status >= 300 && response.status < 400) {
        const location = response.headers.get('location');
        if (!location) {
          return null;
        }

        const redirected = safeHttpUrl(location, current);
        if (!redirected) {
          return null;
        }

        current = redirected;
        continue;
      }

      if (!response.ok) {
        return null;
      }

      return {
        response,
        finalUrl: current
      };
    } catch {
      return null;
    } finally {
      clearTimeout(timeout);
    }
  }

  return null;
}

async function readBodyLimited(response: Response, maxBytes: number) {
  const contentLength = Number(response.headers.get('content-length') ?? 0);
  if (Number.isFinite(contentLength) && contentLength > maxBytes) {
    return null;
  }

  const reader = response.body?.getReader();
  if (!reader) {
    return '';
  }

  const chunks: Uint8Array[] = [];
  let totalBytes = 0;

  while (true) {
    const { done, value } = await reader.read();
    if (done) {
      break;
    }

    if (!value) {
      continue;
    }

    totalBytes += value.byteLength;
    if (totalBytes > maxBytes) {
      return null;
    }

    chunks.push(value);
  }

  const output = new Uint8Array(totalBytes);
  let offset = 0;
  for (const chunk of chunks) {
    output.set(chunk, offset);
    offset += chunk.byteLength;
  }

  return new TextDecoder('utf-8', { fatal: false }).decode(output);
}

function sanitizeText(value: string) {
  return value.replace(/<[^>]*>/g, '').trim();
}

async function imageWithAllowedContentType(url: string | undefined) {
  if (!url) {
    return undefined;
  }

  const imageUrl = safeHttpUrl(url);
  if (!imageUrl) {
    return undefined;
  }

  const result = await fetchWithRedirectGuards(imageUrl, 'HEAD', 5000);
  if (!result) {
    return undefined;
  }

  const contentType = (result.response.headers.get('content-type') ?? '').toLowerCase();
  if (ALLOWED_IMAGE_CONTENT_TYPES.some((allowed) => contentType.startsWith(allowed))) {
    return result.finalUrl.toString();
  }

  return undefined;
}

async function fetchUnfurlData(inputUrl: string) {
  const normalizedUrl = normalizeUrl(inputUrl);
  if (!normalizedUrl) {
    return null;
  }

  if (FILES_AND_MEDIA_URL_REGEX.test(normalizedUrl.toString())) {
    return null;
  }

  const fetchResult = await fetchWithRedirectGuards(normalizedUrl, 'GET', 7000);
  if (!fetchResult) {
    return null;
  }

  const contentType = (fetchResult.response.headers.get('content-type') ?? '').toLowerCase();
  if (!contentType.startsWith('text/html')) {
    return null;
  }

  const html = await readBodyLimited(fetchResult.response, MAX_BODY_SIZE);
  if (html === null) {
    return null;
  }

  const attributes = parseOpenGraphAttributes(html);

  const title = attributes.title ? sanitizeText(attributes.title) : '';
  const description = attributes.description ? sanitizeText(attributes.description) : '';
  if (!title || !description) {
    return null;
  }

  let canonicalUrl = fetchResult.finalUrl.toString();
  if (attributes.url && validHttpUrl(attributes.url)) {
    const maybeCanonical = safeHttpUrl(attributes.url);
    if (maybeCanonical && (await isPublicHttpUrl(maybeCanonical))) {
      canonicalUrl = maybeCanonical.toString();
    }
  }

  const image = await imageWithAllowedContentType(attributes.image);

  return {
    title,
    description,
    url: canonicalUrl,
    image: image ?? null
  };
}

const unfurlLinkRoutes: FastifyPluginAsync = async (app) => {
  app.post('/unfurl_link', { preHandler: app.authenticate }, async (request, reply) => {
    const userId = request.authUserId;
    if (!userId) {
      return reply.code(401).send({ error: 'Unauthorized' });
    }

    const payload = unfurlSchema.parse(request.body);
    const metadata = await fetchUnfurlData(payload.url);

    if (!metadata) {
      return reply.code(204).send();
    }

    return metadata;
  });
};

export default unfurlLinkRoutes;
