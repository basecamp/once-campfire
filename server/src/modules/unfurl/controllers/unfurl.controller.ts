import type { FastifyReply, FastifyRequest } from 'fastify';
import { sendData, sendError } from '../../../shared/utils/controller.js';

function pickMetaTag(html: string, key: string) {
  const escaped = key.replace(/[.*+?^${}()|[\]\\]/g, '\\$&');
  const regex = new RegExp(`<meta[^>]+(?:property|name)=["']${escaped}["'][^>]*content=["']([^"']+)["'][^>]*>`, 'i');
  const match = html.match(regex);
  return match?.[1] ?? null;
}

export const unfurlController = {
  async create(request: FastifyRequest, reply: FastifyReply) {
    const url = (request.body as { url?: string })?.url;
    if (!url || typeof url !== 'string') {
      return sendError(reply, 422, 'VALIDATION_ERROR', 'url is required');
    }

    try {
      const res = await fetch(url, { redirect: 'follow' });
      if (!res.ok) {
        return reply.code(204).send();
      }

      const contentType = res.headers.get('content-type') ?? '';
      if (!contentType.includes('text/html')) {
        return reply.code(204).send();
      }

      const html = await res.text();

      const title = pickMetaTag(html, 'og:title') ?? '';
      const description = pickMetaTag(html, 'og:description') ?? '';
      const image = pickMetaTag(html, 'og:image');
      const canonical = pickMetaTag(html, 'og:url') ?? url;

      if (!title || !description) {
        return reply.code(204).send();
      }

      return sendData(request, reply, {
        title,
        url: canonical,
        description,
        image
      });
    } catch {
      return reply.code(204).send();
    }
  }
};
