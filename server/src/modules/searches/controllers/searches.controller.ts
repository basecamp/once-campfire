import type { FastifyReply, FastifyRequest } from 'fastify';
import { Types } from 'mongoose';
import { SearchModel } from '../models/search.model.js';
import { MessageModel } from '../../messages/models/message.model.js';
import { MembershipModel } from '../../rooms/models/membership.model.js';
import { getAuthUserId, sendData, sendError } from '../../../shared/utils/controller.js';

function normalizeQuery(q: string) {
  return q.replace(/[^\w\s]/g, ' ').trim().replace(/\s+/g, ' ');
}

export const searchesController = {
  async index(request: FastifyRequest, reply: FastifyReply) {
    try {
      const userId = getAuthUserId(request);
      const queryRaw = String((request.query as { q?: string }).q ?? '');
      const q = normalizeQuery(queryRaw);

      const recent = await SearchModel.find({ userId }).sort({ updatedAt: -1 }).limit(10).lean();
      if (!q) {
        return sendData(request, reply, { messages: [], recent });
      }

      const memberships = await MembershipModel.find({ userId }, { roomId: 1 }).lean();
      const roomIds = memberships.map((m) => m.roomId);

      const regex = new RegExp(q.replace(/[.*+?^${}()|[\]\\]/g, '\\$&'), 'i');
      const messages = await MessageModel.find({
        roomId: { $in: roomIds },
        $or: [{ bodyPlain: regex }, { 'attachment.filename': regex }]
      })
        .sort({ createdAt: -1 })
        .limit(100)
        .lean();

      return sendData(request, reply, { messages, recent });
    } catch {
      return sendError(reply, 401, 'UNAUTHORIZED', 'Unauthorized');
    }
  },

  async create(request: FastifyRequest, reply: FastifyReply) {
    try {
      const userId = getAuthUserId(request);
      const rawQ = (request.body as { q?: string })?.q ?? '';
      const q = normalizeQuery(String(rawQ));

      if (!q) {
        return sendError(reply, 422, 'VALIDATION_ERROR', 'q is required');
      }

      const existing = await SearchModel.findOne({ userId, query: q });
      if (existing) {
        existing.updatedAt = new Date();
        await existing.save();
      } else {
        await SearchModel.create({ userId: new Types.ObjectId(userId), query: q });
      }

      const all = await SearchModel.find({ userId }).sort({ updatedAt: -1 }).lean();
      if (all.length > 10) {
        const idsToRemove = all.slice(10).map((x) => x._id);
        await SearchModel.deleteMany({ _id: { $in: idsToRemove } });
      }

      return sendData(request, reply, { recorded: q });
    } catch {
      return sendError(reply, 401, 'UNAUTHORIZED', 'Unauthorized');
    }
  },

  async clear(request: FastifyRequest, reply: FastifyReply) {
    try {
      const userId = getAuthUserId(request);
      await SearchModel.deleteMany({ userId: new Types.ObjectId(userId) });
      return sendData(request, reply, { cleared: true });
    } catch {
      return sendError(reply, 401, 'UNAUTHORIZED', 'Unauthorized');
    }
  }
};
