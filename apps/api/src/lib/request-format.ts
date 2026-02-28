import type { FastifyRequest } from 'fastify';

function currentPath(request: FastifyRequest) {
  const url = request.raw.url ?? request.url ?? '';
  const queryIndex = url.indexOf('?');
  return queryIndex >= 0 ? url.slice(0, queryIndex) : url;
}

export function isApiPath(request: FastifyRequest) {
  return currentPath(request).startsWith('/api/');
}

export function acceptsHtml(request: FastifyRequest) {
  const accept = String(request.headers.accept ?? '').toLowerCase();
  return accept.includes('html');
}

export function isHtmlPageRequest(request: FastifyRequest) {
  return !isApiPath(request) && acceptsHtml(request);
}
