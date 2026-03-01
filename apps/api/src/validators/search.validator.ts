import { z } from 'zod';

export const runSearchSchema = z.object({
  query: z.string().trim().min(1).max(200),
  roomId: z.string().optional()
});

export function parseSearchPayload(input: unknown) {
  if (!input || typeof input !== 'object') {
    return runSearchSchema.parse(input);
  }

  const payload = input as {
    query?: unknown;
    q?: unknown;
    roomId?: unknown;
    room_id?: unknown;
  };

  return runSearchSchema.parse({
    query:
      (typeof payload.query === 'string' ? payload.query : undefined) ??
      (typeof payload.q === 'string' ? payload.q : undefined),
    roomId:
      (typeof payload.roomId === 'string' ? payload.roomId : undefined) ??
      (typeof payload.room_id === 'string' ? payload.room_id : undefined)
  });
}
