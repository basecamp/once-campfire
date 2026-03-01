import type { FastifyReply, FastifyRequest } from 'fastify';
import { Types } from 'mongoose';
import { BanModel } from '../models/ban.model.js';
import { SessionModel } from '../../realtime/models/session.model.js';
import { MessageModel } from '../../messages/models/message.model.js';
import { sendData, sendError } from '../../../shared/utils/controller.js';

export const moderationController = {
  async ban(request: FastifyRequest, reply: FastifyReply) {
    const { userId } = request.params as { userId: string };
    if (!Types.ObjectId.isValid(userId)) {
      return sendError(reply, 422, 'VALIDATION_ERROR', 'Invalid userId');
    }

    const sessions = await SessionModel.find({ userId }, { ipAddress: 1 }).lean();
    const ips = Array.from(new Set(sessions.map((s) => s.ipAddress).filter((ip): ip is string => Boolean(ip))));

    if (ips.length > 0) {
      await BanModel.insertMany(
        ips.map((ipAddress) => ({ userId: new Types.ObjectId(userId), ipAddress })),
        { ordered: false }
      ).catch(() => undefined);
    }

    await SessionModel.deleteMany({ userId: new Types.ObjectId(userId) });
    await MessageModel.deleteMany({ creatorId: new Types.ObjectId(userId) });

    return sendData(request, reply, { banned: true, userId, ips });
  },

  async unban(request: FastifyRequest, reply: FastifyReply) {
    const { userId } = request.params as { userId: string };
    if (!Types.ObjectId.isValid(userId)) {
      return sendError(reply, 422, 'VALIDATION_ERROR', 'Invalid userId');
    }

    await BanModel.deleteMany({ userId: new Types.ObjectId(userId) });
    return sendData(request, reply, { unbanned: true, userId });
  }
};
