import { z } from 'zod';

export const createRoomSchema = z.object({
  name: z.string().min(2).max(80),
  type: z.enum(['open', 'closed']).default('open'),
  userIds: z.array(z.string()).default([])
});

export const openOrClosedSchema = z.object({
  name: z.string().trim().min(2).max(80).optional(),
  userIds: z.array(z.string().min(1)).optional(),
  user_ids: z.array(z.string().min(1)).optional(),
  room: z
    .object({
      name: z.string().trim().min(2).max(80).optional()
    })
    .optional()
});

export const createDirectSchema = z
  .object({
    userId: z.string().min(1).optional(),
    userIds: z.array(z.string().min(1)).optional(),
    user_ids: z.array(z.string().min(1)).optional()
  })
  .refine(
    (value) => Boolean(value.userId || (value.userIds && value.userIds.length > 0) || (value.user_ids && value.user_ids.length > 0)),
    { message: 'userId or userIds is required' }
  );

export const messagePayloadSchema = z.object({
  body: z.union([z.string().max(50000), z.object({ html: z.string().max(50000).optional(), plain: z.string().max(50000).optional() })]).optional(),
  clientMessageId: z.string().trim().min(1).max(128).optional()
});

export const updateInvolvementSchema = z.object({
  involvement: z.enum(['invisible', 'nothing', 'mentions', 'everything'])
});

export function normalizeUserIds(userIds: string[]) {
  return Array.from(new Set(userIds.map((id) => id.trim()).filter(Boolean)));
}

export function createDirectKey(userIds: string[]) {
  return Array.from(new Set(userIds.map((id) => id.trim()).filter(Boolean))).sort().join(':');
}

export function parseOpenOrClosedPayload(input: unknown) {
  const payload = openOrClosedSchema.parse(input);

  return {
    name: payload.room?.name ?? payload.name ?? 'New room',
    userIds: normalizeUserIds([...(payload.userIds ?? []), ...(payload.user_ids ?? [])])
  };
}

export function parseMessagePayload(input: unknown) {
  const extractBody = (value: unknown) => {
    if (typeof value === 'string') {
      return value;
    }

    if (value && typeof value === 'object') {
      const candidate = value as { html?: unknown; plain?: unknown };
      if (typeof candidate.html === 'string') {
        return candidate.html;
      }
      if (typeof candidate.plain === 'string') {
        return candidate.plain;
      }
    }

    return undefined;
  };

  let parsed: z.infer<typeof messagePayloadSchema>;

  if (typeof input === 'string') {
    parsed = messagePayloadSchema.parse({ body: input });
  } else if (!input || typeof input !== 'object') {
    parsed = messagePayloadSchema.parse(input);
  } else {
    const payload = input as {
      body?: unknown;
      clientMessageId?: unknown;
      client_message_id?: unknown;
      message?: {
        body?: unknown;
        clientMessageId?: unknown;
        client_message_id?: unknown;
      };
    };

    const message = payload.message;

    parsed = messagePayloadSchema.parse({
      body: extractBody(message?.body) ?? extractBody(payload.body),
      clientMessageId:
        (typeof message?.clientMessageId === 'string' ? message.clientMessageId : undefined) ??
        (typeof message?.client_message_id === 'string' ? message.client_message_id : undefined) ??
        (typeof payload.clientMessageId === 'string' ? payload.clientMessageId : undefined) ??
        (typeof payload.client_message_id === 'string' ? payload.client_message_id : undefined)
    });
  }

  const bodyValue = extractBody(parsed.body);
  if (!bodyValue?.trim()) {
    throw new Error('body is required');
  }

  return {
    body: bodyValue.trim(),
    clientMessageId: parsed.clientMessageId
  };
}
