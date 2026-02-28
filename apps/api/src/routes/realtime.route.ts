import type { FastifyPluginAsync } from 'fastify';
import { asObjectId } from '../lib/object-id.js';
import { MembershipModel } from '../models/membership.model.js';
import { UserModel } from '../models/user.model.js';
import { realtimeBus } from '../realtime/event-bus.js';
import { publishRealtimeEvent } from '../realtime/redis-realtime.js';
import { absentMembership, presentMembership, refreshMembership } from '../services/membership-connection.js';

async function ensureMembership(roomId: string, userId: string) {
  const roomObjectId = asObjectId(roomId);
  if (!roomObjectId) {
    return null;
  }

  return MembershipModel.findOne({ roomId: roomObjectId, userId }).lean();
}

const realtimeRoutes: FastifyPluginAsync = async (app) => {
  app.get('/stream', { preHandler: app.authenticate }, async (request, reply) => {
    const userId = request.authUserId;
    if (!userId) {
      return reply.code(401).send({ error: 'Unauthorized' });
    }

    const { roomId } = request.query as { roomId?: string };

    if (roomId) {
      const membership = await ensureMembership(roomId, userId);
      if (!membership) {
        return reply.code(403).send({ error: 'You are not a room member' });
      }
    }

    reply.hijack();

    reply.raw.writeHead(200, {
      'Content-Type': 'text/event-stream',
      'Cache-Control': 'no-cache, no-transform',
      Connection: 'keep-alive'
    });

    const sendEvent = (eventName: string, payload: unknown) => {
      reply.raw.write(`event: ${eventName}\n`);
      reply.raw.write(`data: ${JSON.stringify(payload)}\n\n`);
    };

    sendEvent('connected', { ok: true, now: new Date().toISOString() });

    const unsubscribe = realtimeBus.subscribe((event) => {
      if (roomId && event.roomId !== roomId) {
        return;
      }

      if (event.userIds && !event.userIds.includes(userId)) {
        return;
      }

      sendEvent(event.type, event.payload);
    });

    const heartbeat = setInterval(() => {
      sendEvent('heartbeat', { now: new Date().toISOString() });
    }, 25000);

    request.raw.on('close', () => {
      clearInterval(heartbeat);
      unsubscribe();
      reply.raw.end();
    });
  });

  app.post('/rooms/:roomId/presence/present', { preHandler: app.authenticate }, async (request, reply) => {
    const userId = request.authUserId;
    if (!userId) {
      return reply.code(401).send({ error: 'Unauthorized' });
    }

    const { roomId } = request.params as { roomId: string };
    const membership = await presentMembership(roomId, userId);

    if (!membership) {
      return reply.code(403).send({ error: 'You are not a room member' });
    }

    await publishRealtimeEvent({
      type: 'room.read',
      roomId,
      payload: { room_id: roomId },
      userIds: [userId]
    });

    return { ok: true };
  });

  app.post('/rooms/:roomId/presence/absent', { preHandler: app.authenticate }, async (request, reply) => {
    const userId = request.authUserId;
    if (!userId) {
      return reply.code(401).send({ error: 'Unauthorized' });
    }

    const { roomId } = request.params as { roomId: string };
    const membership = await absentMembership(roomId, userId);

    if (!membership) {
      return reply.code(403).send({ error: 'You are not a room member' });
    }

    return { ok: true };
  });

  app.post('/rooms/:roomId/presence/refresh', { preHandler: app.authenticate }, async (request, reply) => {
    const userId = request.authUserId;
    if (!userId) {
      return reply.code(401).send({ error: 'Unauthorized' });
    }

    const { roomId } = request.params as { roomId: string };
    const membership = await refreshMembership(roomId, userId);

    if (!membership) {
      return reply.code(403).send({ error: 'You are not a room member' });
    }

    return { ok: true };
  });

  app.post('/rooms/:roomId/typing/start', { preHandler: app.authenticate }, async (request, reply) => {
    const userId = request.authUserId;
    if (!userId) {
      return reply.code(401).send({ error: 'Unauthorized' });
    }

    const { roomId } = request.params as { roomId: string };
    const membership = await ensureMembership(roomId, userId);
    if (!membership) {
      return reply.code(403).send({ error: 'You are not a room member' });
    }

    const user = await UserModel.findById(userId, { name: 1 }).lean();
    if (!user) {
      return reply.code(404).send({ error: 'User not found' });
    }

    await publishRealtimeEvent({
      type: 'typing.start',
      roomId,
      payload: {
        action: 'start',
        user: {
          id: userId,
          name: user.name
        }
      }
    });

    return { ok: true };
  });

  app.post('/rooms/:roomId/typing/stop', { preHandler: app.authenticate }, async (request, reply) => {
    const userId = request.authUserId;
    if (!userId) {
      return reply.code(401).send({ error: 'Unauthorized' });
    }

    const { roomId } = request.params as { roomId: string };
    const membership = await ensureMembership(roomId, userId);
    if (!membership) {
      return reply.code(403).send({ error: 'You are not a room member' });
    }

    const user = await UserModel.findById(userId, { name: 1 }).lean();
    if (!user) {
      return reply.code(404).send({ error: 'User not found' });
    }

    await publishRealtimeEvent({
      type: 'typing.stop',
      roomId,
      payload: {
        action: 'stop',
        user: {
          id: userId,
          name: user.name
        }
      }
    });

    return { ok: true };
  });
};

export default realtimeRoutes;
