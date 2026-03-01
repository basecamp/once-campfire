import type { FastifyReply, FastifyRequest } from 'fastify';
import { MembershipModel } from '../../rooms/models/membership.model.js';
import { getAuthUserId, sendData, sendError } from '../../../shared/utils/controller.js';

export const realtimeController = {
  async stream(request: FastifyRequest, reply: FastifyReply) {
    const userId = getAuthUserId(request);

    reply.raw.setHeader('Content-Type', 'text/event-stream');
    reply.raw.setHeader('Cache-Control', 'no-cache');
    reply.raw.setHeader('Connection', 'keep-alive');

    const heartbeat = setInterval(() => {
      reply.raw.write(`event: ping\ndata: ${JSON.stringify({ t: Date.now(), userId })}\n\n`);
    }, 15000);

    request.raw.on('close', () => {
      clearInterval(heartbeat);
      reply.raw.end();
    });

    reply.raw.write(`event: connected\ndata: ${JSON.stringify({ userId })}\n\n`);
    return reply;
  },

  async presencePresent(request: FastifyRequest, reply: FastifyReply) {
    const userId = getAuthUserId(request);
    const { roomId } = request.params as { roomId: string };

    const membership = await MembershipModel.findOneAndUpdate(
      { roomId, userId },
      { connectedAt: new Date(), $inc: { connections: 1 }, unreadAt: null },
      { new: true }
    ).lean();

    if (!membership) {
      return sendError(reply, 404, 'NOT_FOUND', 'Membership not found');
    }

    return sendData(request, reply, { roomId, present: true });
  },

  async presenceAbsent(request: FastifyRequest, reply: FastifyReply) {
    const userId = getAuthUserId(request);
    const { roomId } = request.params as { roomId: string };

    const membership = await MembershipModel.findOne({ roomId, userId });
    if (!membership) {
      return sendError(reply, 404, 'NOT_FOUND', 'Membership not found');
    }

    membership.connections = Math.max(0, (membership.connections ?? 0) - 1);
    if (membership.connections === 0) {
      membership.connectedAt = null;
    }
    await membership.save();

    return sendData(request, reply, { roomId, present: false });
  },

  async presenceRefresh(request: FastifyRequest, reply: FastifyReply) {
    const userId = getAuthUserId(request);
    const { roomId } = request.params as { roomId: string };

    const membership = await MembershipModel.findOneAndUpdate(
      { roomId, userId },
      { connectedAt: new Date() },
      { new: true }
    ).lean();

    if (!membership) {
      return sendError(reply, 404, 'NOT_FOUND', 'Membership not found');
    }

    return sendData(request, reply, { roomId, refreshed: true });
  },

  async typingStart(request: FastifyRequest, reply: FastifyReply) {
    const userId = getAuthUserId(request);
    const { roomId } = request.params as { roomId: string };
    return sendData(request, reply, { roomId, action: 'start', userId });
  },

  async typingStop(request: FastifyRequest, reply: FastifyReply) {
    const userId = getAuthUserId(request);
    const { roomId } = request.params as { roomId: string };
    return sendData(request, reply, { roomId, action: 'stop', userId });
  }
};
