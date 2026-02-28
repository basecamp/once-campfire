import type { FastifyPluginAsync } from 'fastify';
import { getAccount } from '../services/account-singleton.js';
import { MembershipModel } from '../models/membership.model.js';

const LAST_ROOM_COOKIE = 'last_room';

async function resolveWelcomeRedirectRoomId(userId: string, lastRoomId?: string) {
  const memberships = await MembershipModel.find({ userId }, { roomId: 1, createdAt: 1 })
    .sort({ createdAt: 1 })
    .lean();

  if (memberships.length === 0) {
    return null;
  }

  const roomIds = new Set(memberships.map((membership) => String(membership.roomId)));
  if (lastRoomId && roomIds.has(lastRoomId)) {
    return lastRoomId;
  }

  return String(memberships[0]?.roomId);
}

const welcomeRoutes: FastifyPluginAsync = async (app) => {
  app.get('/', async (request, reply) => {
    const auth = await app.tryAuthenticate(request);
    if (!auth) {
      return reply.redirect('/session/new');
    }

    const roomId = await resolveWelcomeRedirectRoomId(auth.userId, request.cookies[LAST_ROOM_COOKIE]);
    if (roomId) {
      return reply.redirect(`/rooms/${roomId}`);
    }

    const account = await getAccount();

    return {
      app: 'campfire',
      account: {
        name: account?.name ?? 'Campfire'
      },
      ok: true
    };
  });

  app.get('/welcome', async (request, reply) => {
    const auth = await app.tryAuthenticate(request);
    if (!auth) {
      return reply.redirect('/session/new');
    }

    const roomId = await resolveWelcomeRedirectRoomId(auth.userId, request.cookies[LAST_ROOM_COOKIE]);
    if (roomId) {
      return reply.redirect(`/rooms/${roomId}`);
    }

    const account = await getAccount();

    return {
      app: 'campfire',
      account: {
        name: account?.name ?? 'Campfire'
      },
      ok: true
    };
  });
};

export default welcomeRoutes;
