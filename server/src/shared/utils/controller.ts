import type { FastifyReply, FastifyRequest } from 'fastify';
import { Types } from 'mongoose';

export function getAuthUserId(request: FastifyRequest): string {
  const authUserId = (request as FastifyRequest & { authUserId?: string }).authUserId ?? normalizeUserId(request.session?._id);
  if (!authUserId) {
    throw new Error('UNAUTHORIZED');
  }
  return authUserId;
}

function normalizeUserId(value: unknown): string | undefined {
  if (typeof value === 'string') {
    const trimmed = value.trim();
    return trimmed.length > 0 ? trimmed : undefined;
  }
  if (typeof value === 'number' || typeof value === 'bigint') {
    return String(value);
  }
  if (value && typeof value === 'object' && 'toString' in value && typeof value.toString === 'function') {
    const parsed = String(value.toString()).trim();
    if (parsed && parsed !== '[object Object]') {
      return parsed;
    }
  }
  return undefined;
}

export function getAccessToken(request: FastifyRequest): string | null {
  return request.accessToken ?? null;
}

export function asObjectId(value: unknown): Types.ObjectId | null {
  if (typeof value !== 'string') {
    return null;
  }

  if (!Types.ObjectId.isValid(value)) {
    return null;
  }

  return new Types.ObjectId(value);
}

export function parseLimit(raw: unknown, fallback = 40, max = 200): number {
  const num = Number(raw);
  if (!Number.isFinite(num) || num <= 0) {
    return fallback;
  }

  return Math.min(Math.floor(num), max);
}

export function sendError(reply: FastifyReply, code: number, errorCode: string, message: string, details: unknown = null) {
  return reply.code(code).send({
    accessToken: getAccessToken(reply.request),
    error: {
      code: errorCode,
      message,
      details
    }
  });
}

export function sendData(request: FastifyRequest, reply: FastifyReply, data: unknown, statusCode = 200) {
  return reply.code(statusCode).send({
    accessToken: getAccessToken(request),
    data
  });
}

export function ensureArrayString(value: unknown): string[] {
  if (!Array.isArray(value)) {
    return [];
  }

  return value.filter((v): v is string => typeof v === 'string');
}
