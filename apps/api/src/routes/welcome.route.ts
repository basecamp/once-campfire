import type { FastifyPluginAsync } from 'fastify';
import { isApiPath } from '../lib/request-format.js';
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

function renderWelcomeHtml(accountName: string) {
  return `<!doctype html>
<html lang="en">
  <head>
    <meta charset="utf-8" />
    <meta name="viewport" content="width=device-width, initial-scale=1" />
    <title>No rooms yet</title>
  </head>
  <body>
    <main>
      <h1>No rooms yet</h1>
      <p>${accountName}</p>
    </main>
  </body>
</html>`;
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
    const accountName = account?.name ?? 'Campfire';

    if (!isApiPath(request)) {
      reply.header('content-type', 'text/html; charset=utf-8');
      return reply.code(200).send(renderWelcomeHtml(accountName));
    }

    return {
      app: 'campfire',
      account: {
        name: accountName
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
    const accountName = account?.name ?? 'Campfire';

    if (!isApiPath(request)) {
      reply.header('content-type', 'text/html; charset=utf-8');
      return reply.code(200).send(renderWelcomeHtml(accountName));
    }

    return {
      app: 'campfire',
      account: {
        name: accountName
      },
      ok: true
    };
  });
};

export default welcomeRoutes;
