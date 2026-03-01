import type { FastifyReply, FastifyRequest } from 'fastify';
import { Types } from 'mongoose';
import { BoostModel } from '../models/boost.model.js';
import { MessageModel } from '../models/message.model.js';
import { MembershipModel } from '../../rooms/models/membership.model.js';
import { getAuthUserId, sendData, sendError } from '../../../shared/utils/controller.js';

export const boostsController = {
  async index(request: FastifyRequest, reply: FastifyReply) {
    try {
      const userId = getAuthUserId(request);
      const { messageId } = request.params as { messageId: string };

      const message = await MessageModel.findById(messageId, { roomId: 1 }).lean();
      if (!message) {
        return sendError(reply, 404, 'NOT_FOUND', 'Message not found');
      }

      const membership = await MembershipModel.findOne({ roomId: message.roomId, userId }).lean();
      if (!membership) {
        return sendError(reply, 404, 'NOT_FOUND', 'Message not reachable');
      }

      const boosts = await BoostModel.find({ messageId }).sort({ createdAt: 1 }).lean();
      return sendData(request, reply, boosts);
    } catch {
      return sendError(reply, 401, 'UNAUTHORIZED', 'Unauthorized');
    }
  },

  async create(request: FastifyRequest, reply: FastifyReply) {
    try {
      const userId = getAuthUserId(request);
      const { messageId } = request.params as { messageId: string };
      const content = (request.body as { content?: string })?.content?.trim();

      if (!content) {
        return sendError(reply, 422, 'VALIDATION_ERROR', 'Boost content is required');
      }

      const message = await MessageModel.findById(messageId, { roomId: 1 }).lean();
      if (!message) {
        return sendError(reply, 404, 'NOT_FOUND', 'Message not found');
      }

      const membership = await MembershipModel.findOne({ roomId: message.roomId, userId }).lean();
      if (!membership) {
        return sendError(reply, 404, 'NOT_FOUND', 'Message not reachable');
      }

      const boost = await BoostModel.create({
        messageId: new Types.ObjectId(messageId),
        boosterId: new Types.ObjectId(userId),
        content
      });

      return sendData(request, reply, boost.toObject(), 201);
    } catch {
      return sendError(reply, 401, 'UNAUTHORIZED', 'Unauthorized');
    }
  },

  async destroy(request: FastifyRequest, reply: FastifyReply) {
    try {
      const userId = getAuthUserId(request);
      const { boostId } = request.params as { boostId: string };

      const boost = await BoostModel.findById(boostId);
      if (!boost) {
        return sendError(reply, 404, 'NOT_FOUND', 'Boost not found');
      }

      if (String(boost.boosterId) !== userId) {
        return sendError(reply, 403, 'FORBIDDEN', 'Not enough permissions');
      }

      await boost.deleteOne();
      return sendData(request, reply, { removed: true });
    } catch {
      return sendError(reply, 401, 'UNAUTHORIZED', 'Unauthorized');
    }
  }
};
