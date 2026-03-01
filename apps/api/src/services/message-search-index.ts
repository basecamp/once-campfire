import { MessageSearchIndexModel } from '../models/message-search-index.model.js';
import { plainTextForMessage } from './rich-text.js';

function escapeRegex(value: string) {
  return value.replace(/[.*+?^${}()|[\]\\]/g, '\\$&');
}

export function sanitizeSearchText(input: string) {
  return input.replace(/[^\w]/g, ' ').replace(/\s+/g, ' ').trim();
}

export function extractSearchBodyForMessage(message: {
  bodyPlain?: string | null;
  body?: string | null;
  attachment?: {
    filename?: string | null;
  } | null;
}) {
  const primary = plainTextForMessage(message);
  return sanitizeSearchText(primary);
}

export async function upsertMessageSearchIndex({
  messageId,
  roomId,
  body
}: {
  messageId: unknown;
  roomId: unknown;
  body: string;
}) {
  await MessageSearchIndexModel.updateOne(
    { messageId },
    {
      $set: {
        roomId,
        body
      },
      $setOnInsert: {
        createdAt: new Date()
      }
    },
    { upsert: true }
  );
}

export async function removeMessageSearchIndexes(messageIds: unknown[]) {
  if (messageIds.length === 0) {
    return;
  }

  await MessageSearchIndexModel.deleteMany({
    messageId: { $in: messageIds }
  });
}

export async function searchIndexedMessageIds({
  query,
  roomIds,
  limit
}: {
  query: string;
  roomIds: unknown[];
  limit: number;
}) {
  const sanitizedQuery = sanitizeSearchText(query);
  if (!sanitizedQuery || roomIds.length === 0) {
    return [] as string[];
  }

  let indexHits = await MessageSearchIndexModel.find(
    {
      roomId: { $in: roomIds },
      $text: { $search: sanitizedQuery }
    },
    {
      messageId: 1,
      score: { $meta: 'textScore' }
    }
  )
    .sort({
      score: { $meta: 'textScore' },
      updatedAt: -1
    })
    .limit(limit)
    .lean();

  if (indexHits.length === 0) {
    const regex = new RegExp(escapeRegex(sanitizedQuery), 'i');
    indexHits = await MessageSearchIndexModel.find(
      {
        roomId: { $in: roomIds },
        body: regex
      },
      { messageId: 1 }
    )
      .sort({ updatedAt: -1 })
      .limit(limit)
      .lean();
  }

  return indexHits.map((hit) => String(hit.messageId));
}
