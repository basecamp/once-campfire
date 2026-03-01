import Fastify from 'fastify';
import cors from '@fastify/cors';
import formbody from '@fastify/formbody';
import multipart from '@fastify/multipart';
import mongoose from 'mongoose';
import { mongoOptions, mongoUri } from './config/mongo.js';
import authPlugin from './plugins/auth.js';
import accountRoutes from './modules/account/routes/index.js';
import usersRoutes from './modules/users/routes/index.js';
import roomsRoutes from './modules/rooms/routes/index.js';
import messagesRoutes from './modules/messages/routes/index.js';
import searchesRoutes from './modules/searches/routes/index.js';
import pushRoutes from './modules/push/routes/index.js';
import moderationRoutes from './modules/moderation/routes/index.js';
import unfurlRoutes from './modules/unfurl/routes/index.js';
import realtimeRoutes from './modules/realtime/routes/index.js';

function isJsonReply(reply: { getHeader: (name: string) => unknown }) {
  const contentType = String(reply.getHeader('content-type') ?? '').toLowerCase();
  return contentType.includes('application/json');
}

function injectAccessToken(body: Record<string, unknown>, accessToken: string | null | undefined) {
  if (!Object.prototype.hasOwnProperty.call(body, 'accessToken')) {
    body.accessToken = accessToken ?? null;
  }
  return body;
}

export async function buildApp() {
  if (mongoose.connection.readyState === 0) {
    await mongoose.connect(mongoUri, mongoOptions);
  }

  const app = Fastify({ logger: true });

  app.addHook('onSend', async (request, reply, payload) => {
    if (reply.statusCode === 204 || !isJsonReply(reply) || payload === undefined || payload === null || payload === '') {
      return payload;
    }

    if (typeof payload === 'string') {
      try {
        const parsed = JSON.parse(payload);
        if (parsed && typeof parsed === 'object' && !Array.isArray(parsed)) {
          return JSON.stringify(injectAccessToken(parsed, request.accessToken));
        }
      } catch {
        return payload;
      }
      return payload;
    }

    if (Buffer.isBuffer(payload)) {
      try {
        const parsed = JSON.parse(payload.toString('utf8'));
        if (parsed && typeof parsed === 'object' && !Array.isArray(parsed)) {
          return JSON.stringify(injectAccessToken(parsed, request.accessToken));
        }
      } catch {
        return payload;
      }
      return payload;
    }

    if (typeof payload === 'object' && !Array.isArray(payload)) {
      return JSON.stringify(injectAccessToken(payload as Record<string, unknown>, request.accessToken));
    }

    return payload;
  });

  await app.register(cors, { origin: true, credentials: true });
  await app.register(formbody);
  await app.register(multipart, {
    limits: {
      fileSize: 25 * 1024 * 1024,
      files: 1
    }
  });

  await app.register(authPlugin);
  await app.register(accountRoutes);
  await app.register(usersRoutes);
  await app.register(roomsRoutes);
  await app.register(messagesRoutes);
  await app.register(searchesRoutes);
  await app.register(pushRoutes);
  await app.register(moderationRoutes);
  await app.register(unfurlRoutes);
  await app.register(realtimeRoutes);

  return app;
}
