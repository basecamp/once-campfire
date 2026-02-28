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

const searchesRoutes: FastifyPluginAsync = async (app) => {
  app.get('/', { preHandler: app.authenticate }, async (request, reply) => {
    const userId = request.authUserId;
    if (!userId) {
      return reply.code(401).send({ error: 'Unauthorized' });
    }

    const history = await SearchModel.find({ userId }).sort({ createdAt: -1 }).limit(20).lean();

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

    const payload = runSearchSchema.parse(request.body);

    const memberships = await MembershipModel.find({ userId }, { roomId: 1 }).lean();
    const memberRoomIds = memberships.map((membership) => membership.roomId);

    if (memberRoomIds.length === 0) {
      return { query: payload.query, results: [] };
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

    const regex = new RegExp(payload.query.replace(/[.*+?^${}()|[\]\\]/g, '\\$&'), 'i');

    const messages = await MessageModel.find({
      roomId: { $in: roomFilter },
      body: regex
    })
      .sort({ createdAt: -1 })
      .limit(50)
      .lean();

    const creatorIds = Array.from(new Set(messages.map((message) => String(message.creatorId))));
    const creators = await UserModel.find({ _id: { $in: creatorIds } }, { name: 1 }).lean();
    const creatorsById = new Map(creators.map((creator) => [String(creator._id), creator]));

    await SearchModel.create({ userId, query: payload.query });

    return {
      query: payload.query,
      results: messages.map((message) => ({
        id: String(message._id),
        roomId: String(message.roomId),
        creatorId: String(message.creatorId),
        creatorName: creatorsById.get(String(message.creatorId))?.name ?? 'Unknown',
        body: message.body,
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
