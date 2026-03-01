import type { FastifyReply, FastifyRequest } from 'fastify';
import { Types } from 'mongoose';
import { MessageModel } from '../models/message.model.js';
import { MembershipModel } from '../../rooms/models/membership.model.js';
import { RoomModel } from '../../rooms/models/room.model.js';
import { getAuthUserId, parseLimit, sendData, sendError } from '../../../shared/utils/controller.js';

async function ensureRoomAccess(roomId: string, userId: string) {
  return MembershipModel.findOne({ roomId, userId }).lean();
}

export const messagesController = {
  async index(request: FastifyRequest, reply: FastifyReply) {
    try {
      const userId = getAuthUserId(request);
      const { roomId } = request.params as { roomId: string };
      const { before, after, limit } = request.query as { before?: string; after?: string; limit?: string };

      const membership = await ensureRoomAccess(roomId, userId);
      if (!membership) {
        return sendError(reply, 404, 'NOT_FOUND', 'Room not found or inaccessible');
      }

      const pageSize = parseLimit(limit, 40, 80);
      const filter: Record<string, unknown> = { roomId };

      if (before) {
        const beforeMessage = await MessageModel.findById(before, { createdAt: 1 }).lean();
        if (beforeMessage) {
          filter.createdAt = { $lt: beforeMessage.createdAt };
        }
      }

      if (after) {
        const afterMessage = await MessageModel.findById(after, { createdAt: 1 }).lean();
        if (afterMessage) {
          filter.createdAt = { $gt: afterMessage.createdAt };
        }
      }

      const sort = after ? { createdAt: 1 as const } : { createdAt: -1 as const };
      const messages = await MessageModel.find(filter).sort(sort).limit(pageSize).lean();

      if (!after) {
        messages.reverse();
      }

      return sendData(request, reply, messages);
    } catch {
      return sendError(reply, 401, 'UNAUTHORIZED', 'Unauthorized');
    }
  },

  async create(request: FastifyRequest, reply: FastifyReply) {
    try {
      const userId = getAuthUserId(request);
      const { roomId } = request.params as { roomId: string };
      const payload = request.body as { body?: string; clientMessageId?: string; bodyHtml?: string; bodyPlain?: string };

      const membership = await ensureRoomAccess(roomId, userId);
      if (!membership) {
        return sendError(reply, 404, 'NOT_FOUND', 'Room not found or inaccessible');
      }

      const room = await RoomModel.findById(roomId).lean();
      if (!room) {
        return sendError(reply, 404, 'NOT_FOUND', 'Room not found');
      }

      const bodyPlain = (payload.bodyPlain ?? payload.body ?? '').trim();
      const bodyHtml = (payload.bodyHtml ?? bodyPlain).trim();
      if (!bodyPlain && !bodyHtml) {
        return sendError(reply, 422, 'VALIDATION_ERROR', 'Message body cannot be empty');
      }

      const message = await MessageModel.create({
        roomId: new Types.ObjectId(roomId),
        creatorId: new Types.ObjectId(userId),
        clientMessageId: payload.clientMessageId ?? crypto.randomUUID(),
        bodyHtml,
        bodyPlain
      });

      return sendData(request, reply, message.toObject(), 201);
    } catch {
      return sendError(reply, 401, 'UNAUTHORIZED', 'Unauthorized');
    }
  },

  async createByBot(request: FastifyRequest, reply: FastifyReply) {
    return this.create(request, reply);
  },

  async show(request: FastifyRequest, reply: FastifyReply) {
    try {
      const userId = getAuthUserId(request);
      const { roomId, messageId } = request.params as { roomId: string; messageId: string };

      const membership = await ensureRoomAccess(roomId, userId);
      if (!membership) {
        return sendError(reply, 404, 'NOT_FOUND', 'Room not found or inaccessible');
      }

      const message = await MessageModel.findOne({ _id: messageId, roomId }).lean();
      if (!message) {
        return sendError(reply, 404, 'NOT_FOUND', 'Message not found');
      }

      return sendData(request, reply, message);
    } catch {
      return sendError(reply, 401, 'UNAUTHORIZED', 'Unauthorized');
    }
  },

  async update(request: FastifyRequest, reply: FastifyReply) {
    try {
      const userId = getAuthUserId(request);
      const { roomId, messageId } = request.params as { roomId: string; messageId: string };
      const payload = request.body as { body?: string; bodyHtml?: string; bodyPlain?: string };

      const membership = await ensureRoomAccess(roomId, userId);
      if (!membership) {
        return sendError(reply, 404, 'NOT_FOUND', 'Room not found or inaccessible');
      }

      const message = await MessageModel.findOne({ _id: messageId, roomId });
      if (!message) {
        return sendError(reply, 404, 'NOT_FOUND', 'Message not found');
      }

      if (String(message.creatorId) !== userId) {
        return sendError(reply, 403, 'FORBIDDEN', 'Not enough permissions');
      }

      const bodyPlain = (payload.bodyPlain ?? payload.body ?? message.bodyPlain).trim();
      const bodyHtml = (payload.bodyHtml ?? bodyPlain).trim();

      message.bodyPlain = bodyPlain;
      message.bodyHtml = bodyHtml;
      await message.save();

      return sendData(request, reply, message.toObject());
    } catch {
      return sendError(reply, 401, 'UNAUTHORIZED', 'Unauthorized');
    }
  },

  async destroy(request: FastifyRequest, reply: FastifyReply) {
    try {
      const userId = getAuthUserId(request);
      const { roomId, messageId } = request.params as { roomId: string; messageId: string };

      const membership = await ensureRoomAccess(roomId, userId);
      if (!membership) {
        return sendError(reply, 404, 'NOT_FOUND', 'Room not found or inaccessible');
      }

      const message = await MessageModel.findOne({ _id: messageId, roomId });
      if (!message) {
        return sendError(reply, 404, 'NOT_FOUND', 'Message not found');
      }

      if (String(message.creatorId) !== userId) {
        return sendError(reply, 403, 'FORBIDDEN', 'Not enough permissions');
      }

      await message.deleteOne();
      return sendData(request, reply, { removed: true });
    } catch {
      return sendError(reply, 401, 'UNAUTHORIZED', 'Unauthorized');
    }
  }
};
