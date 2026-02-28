import type { FastifyPluginAsync } from 'fastify';
import { z } from 'zod';
import { asObjectId } from '../lib/object-id.js';
import { BoostModel } from '../models/boost.model.js';
import { MembershipModel } from '../models/membership.model.js';
import { MessageModel } from '../models/message.model.js';
import { UserModel } from '../models/user.model.js';
import { enqueueWebhookDispatch } from '../queues/webhook.queue.js';
import { publishRealtimeEvent } from '../realtime/redis-realtime.js';

const createBoostSchema = z.object({
  content: z.string().trim().min(1).max(16)
});

const messagesRoutes: FastifyPluginAsync = async (app) => {
  app.get('/:messageId/boosts', { preHandler: app.authenticate }, async (request, reply) => {
    const userId = request.authUserId;
    if (!userId) {
      return reply.code(401).send({ error: 'Unauthorized' });
    }

    const { messageId } = request.params as { messageId: string };
    const messageObjectId = asObjectId(messageId);
    if (!messageObjectId) {
      return reply.code(400).send({ error: 'Invalid message id' });
    }

    const message = await MessageModel.findById(messageObjectId).lean();
    if (!message) {
      return reply.code(404).send({ error: 'Message not found' });
    }

    const membership = await MembershipModel.findOne({ roomId: message.roomId, userId }).lean();
    if (!membership) {
      return reply.code(403).send({ error: 'You are not a room member' });
    }

    const boosts = await BoostModel.find({ messageId: messageObjectId }).sort({ createdAt: 1 }).lean();

    return {
      boosts: boosts.map((boost) => ({
        id: String(boost._id),
        messageId: String(boost.messageId),
        boosterId: String(boost.boosterId),
        content: boost.content,
        createdAt: boost.createdAt
      }))
    };
  });

  app.post('/:messageId/boosts', { preHandler: app.authenticate }, async (request, reply) => {
    const userId = request.authUserId;
    if (!userId) {
      return reply.code(401).send({ error: 'Unauthorized' });
    }

    const { messageId } = request.params as { messageId: string };
    const messageObjectId = asObjectId(messageId);
    if (!messageObjectId) {
      return reply.code(400).send({ error: 'Invalid message id' });
    }

    const payload = createBoostSchema.parse(request.body);

    const message = await MessageModel.findById(messageObjectId).lean();
    if (!message) {
      return reply.code(404).send({ error: 'Message not found' });
    }

    const membership = await MembershipModel.findOne({ roomId: message.roomId, userId }).lean();
    if (!membership) {
      return reply.code(403).send({ error: 'You are not a room member' });
    }

    const existing = await BoostModel.findOne({
      messageId: messageObjectId,
      boosterId: userId,
      content: payload.content
    }).lean();

    if (existing) {
      return reply.code(200).send({
        boost: {
          id: String(existing._id),
          messageId: String(existing.messageId),
          boosterId: String(existing.boosterId),
          content: existing.content,
          createdAt: existing.createdAt
        }
      });
    }

    const boost = await BoostModel.create({
      messageId: messageObjectId,
      boosterId: userId,
      content: payload.content
    });

    const actor = await UserModel.findById(userId, { name: 1 }).lean();

    const responseBoost = {
      id: String(boost._id),
      messageId: String(boost.messageId),
      boosterId: String(boost.boosterId),
      content: boost.content,
      actorName: actor?.name ?? 'Unknown',
      createdAt: boost.createdAt
    };

    await publishRealtimeEvent({
      type: 'message.boosted',
      roomId: String(message.roomId),
      payload: {
        messageId: String(message._id),
        boost: responseBoost
      }
    });

    await enqueueWebhookDispatch({
      event: 'message.boosted',
      roomId: String(message.roomId),
      payload: {
        messageId: String(message._id),
        boost: responseBoost
      }
    });

    return reply.code(201).send({ boost: responseBoost });
  });

  app.delete('/:messageId/boosts/:boostId', { preHandler: app.authenticate }, async (request, reply) => {
    const userId = request.authUserId;
    if (!userId) {
      return reply.code(401).send({ error: 'Unauthorized' });
    }

    const { messageId, boostId } = request.params as { messageId: string; boostId: string };
    const messageObjectId = asObjectId(messageId);
    const boostObjectId = asObjectId(boostId);

    if (!messageObjectId || !boostObjectId) {
      return reply.code(400).send({ error: 'Invalid id' });
    }

    const message = await MessageModel.findById(messageObjectId).lean();
    if (!message) {
      return reply.code(404).send({ error: 'Message not found' });
    }

    const membership = await MembershipModel.findOne({ roomId: message.roomId, userId }).lean();
    if (!membership) {
      return reply.code(403).send({ error: 'You are not a room member' });
    }

    const boost = await BoostModel.findById(boostObjectId).lean();
    if (!boost || String(boost.messageId) !== String(messageObjectId)) {
      return reply.code(404).send({ error: 'Boost not found' });
    }

    if (String(boost.boosterId) !== userId) {
      return reply.code(403).send({ error: 'You can only remove your own boosts' });
    }

    await BoostModel.deleteOne({ _id: boostObjectId });

    return reply.code(204).send();
  });
};

export default messagesRoutes;
