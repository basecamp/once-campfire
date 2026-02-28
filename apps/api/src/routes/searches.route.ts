import type { FastifyPluginAsync } from 'fastify';
import { z } from 'zod';
import { asObjectId } from '../lib/object-id.js';
import { MembershipModel } from '../models/membership.model.js';
import { MessageModel } from '../models/message.model.js';
import { SearchModel } from '../models/search.model.js';
import { UserModel } from '../models/user.model.js';

const runSearchSchema = z.object({
  query: z.string().trim().min(1).max(200),
  roomId: z.string().optional()
});

function sanitizeQuery(input: string) {
  return input.replace(/[^\w]/g, ' ').replace(/\s+/g, ' ').trim();
}

function parseSearchPayload(input: unknown) {
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

const searchesRoutes: FastifyPluginAsync = async (app) => {
  app.get('/', { preHandler: app.authenticate }, async (request, reply) => {
    const userId = request.authUserId;
    if (!userId) {
      return reply.code(401).send({ error: 'Unauthorized' });
    }

    const history = await SearchModel.find({ userId }).sort({ updatedAt: -1 }).limit(10).lean();

    return {
      searches: history.map((item) => ({
        id: String(item._id),
        query: item.query,
        createdAt: item.createdAt
      }))
    };
  });

  app.post('/', { preHandler: app.authenticate }, async (request, reply) => {
    const userId = request.authUserId;
    if (!userId) {
      return reply.code(401).send({ error: 'Unauthorized' });
    }

    const payload = parseSearchPayload(request.body);
    const normalizedQuery = sanitizeQuery(payload.query);
    if (!normalizedQuery) {
      return reply.code(422).send({ error: 'Query is empty after normalization' });
    }

    const memberships = await MembershipModel.find({ userId }, { roomId: 1 }).lean();
    const memberRoomIds = memberships.map((membership) => membership.roomId);

    if (memberRoomIds.length === 0) {
      return { query: normalizedQuery, results: [] };
    }

    let roomFilter = memberRoomIds;

    if (payload.roomId) {
      const roomObjectId = asObjectId(payload.roomId);
      if (!roomObjectId) {
        return reply.code(400).send({ error: 'Invalid room id' });
      }

      const isMember = memberRoomIds.some((roomId) => String(roomId) === String(roomObjectId));
      if (!isMember) {
        return reply.code(403).send({ error: 'You are not a room member' });
      }

      roomFilter = [roomObjectId];
    }

    const regex = new RegExp(normalizedQuery.replace(/[.*+?^${}()|[\]\\]/g, '\\$&'), 'i');

    const messages = await MessageModel.find({
      roomId: { $in: roomFilter },
      $or: [{ body: regex }, { 'attachment.filename': regex }]
    })
      .sort({ createdAt: -1 })
      .limit(100)
      .lean();

    const creatorIds = Array.from(new Set(messages.map((message) => String(message.creatorId))));
    const creators = await UserModel.find({ _id: { $in: creatorIds } }, { name: 1 }).lean();
    const creatorsById = new Map(creators.map((creator) => [String(creator._id), creator]));

    await SearchModel.findOneAndUpdate(
      { userId, query: normalizedQuery },
      { $set: { updatedAt: new Date() }, $setOnInsert: { query: normalizedQuery, userId, createdAt: new Date() } },
      { upsert: true }
    );

    const oldSearches = await SearchModel.find({ userId }).sort({ updatedAt: -1 }).skip(10).select({ _id: 1 }).lean();
    if (oldSearches.length > 0) {
      await SearchModel.deleteMany({ _id: { $in: oldSearches.map((item) => item._id) } });
    }

    return {
      query: normalizedQuery,
      results: messages.map((message) => ({
        id: String(message._id),
        roomId: String(message.roomId),
        creatorId: String(message.creatorId),
        creatorName: creatorsById.get(String(message.creatorId))?.name ?? 'Unknown',
        body: message.body?.trim() || message.attachment?.filename || '',
        attachment: message.attachment
          ? {
              contentType: message.attachment.contentType,
              filename: message.attachment.filename,
              byteSize: message.attachment.byteSize,
              path: `/api/v1/messages/${String(message._id)}/attachment`
            }
          : undefined,
        createdAt: message.createdAt
      }))
    };
  });

  app.delete('/clear', { preHandler: app.authenticate }, async (request, reply) => {
    const userId = request.authUserId;
    if (!userId) {
      return reply.code(401).send({ error: 'Unauthorized' });
    }

    await SearchModel.deleteMany({ userId });

    return reply.code(204).send();
  });
};

export default searchesRoutes;
