import Fastify from 'fastify';
import cors from '@fastify/cors';
import formbody from '@fastify/formbody';
import multipart from '@fastify/multipart';
import websocket from '@fastify/websocket';
import browserPlatformPlugin from './plugins/browser-platform.js';
import banGuardPlugin from './plugins/ban-guard.js';
import mongoosePlugin from './plugins/mongoose.js';
import authPlugin from './plugins/auth.js';
import healthRoute from './routes/health.route.js';
import authRoutes from './routes/auth.route.js';
import roomsRoutes from './routes/rooms.route.js';
import messagesRoutes from './routes/messages.route.js';
import searchesRoutes from './routes/searches.route.js';
import webhooksRoutes from './routes/webhooks.route.js';
import realtimeRoutes from './routes/realtime.route.js';
import usersRoutes from './routes/users.route.js';
import moderationRoutes from './routes/moderation.route.js';
import pushSubscriptionsRoutes from './routes/push-subscriptions.route.js';
import firstRunRoutes from './routes/first-run.route.js';
import unfurlLinkRoutes from './routes/unfurl-link.route.js';
import accountRoutes from './routes/account.route.js';
import autocompletableRoutes from './routes/autocompletable.route.js';
import joinRoutes from './routes/join.route.js';
import sessionTransfersRoutes from './routes/session-transfers.route.js';
import sessionsRoutes from './routes/sessions.route.js';
import qrCodeRoutes from './routes/qr-code.route.js';
import pwaRoutes from './routes/pwa.route.js';
import welcomeRoutes from './routes/welcome.route.js';
import cableRoutes from './routes/cable.route.js';
import { env } from './config/env.js';

export function buildApp() {
  const app = Fastify({ logger: true });

  const bufferParser = (_request: unknown, body: Buffer, done: (error: Error | null, value: Buffer) => void) => {
    done(null, body);
  };

  app.addContentTypeParser('application/octet-stream', { parseAs: 'buffer' }, bufferParser);
  app.addContentTypeParser('application/pdf', { parseAs: 'buffer' }, bufferParser);
  app.addContentTypeParser(/^image\/.+/, { parseAs: 'buffer' }, bufferParser);
  app.addContentTypeParser(/^audio\/.+/, { parseAs: 'buffer' }, bufferParser);
  app.addContentTypeParser(/^video\/.+/, { parseAs: 'buffer' }, bufferParser);

  app.addHook('onSend', async (_request, reply, payload) => {
    reply.header('x-version', env.APP_VERSION);
    reply.header('x-rev', env.GIT_REVISION);
    return payload;
  });

  app.register(cors, {
    origin: true,
    credentials: true
  });
  app.register(formbody);

  app.register(multipart, {
    limits: {
      fileSize: 25 * 1024 * 1024,
      files: 1
    }
  });
  app.register(websocket);

  app.register(browserPlatformPlugin);
  app.register(mongoosePlugin);
  app.register(banGuardPlugin);
  app.register(authPlugin);

  app.register(healthRoute, { prefix: '/api/v1' });
  app.register(healthRoute);
  app.register(authRoutes, { prefix: '/api/v1/auth' });
  app.register(roomsRoutes, { prefix: '/api/v1/rooms' });
  app.register(messagesRoutes, { prefix: '/api/v1/messages' });
  app.register(searchesRoutes, { prefix: '/api/v1/searches' });
  app.register(webhooksRoutes, { prefix: '/api/v1/webhooks' });
  app.register(realtimeRoutes, { prefix: '/api/v1/realtime' });
  app.register(usersRoutes, { prefix: '/api/v1/users' });
  app.register(moderationRoutes, { prefix: '/api/v1' });
  app.register(pushSubscriptionsRoutes, { prefix: '/api/v1' });
  app.register(firstRunRoutes, { prefix: '/api/v1' });
  app.register(unfurlLinkRoutes, { prefix: '/api/v1' });
  app.register(accountRoutes, { prefix: '/api/v1' });
  app.register(autocompletableRoutes, { prefix: '/api/v1' });
  app.register(joinRoutes, { prefix: '/api/v1' });
  app.register(sessionTransfersRoutes, { prefix: '/api/v1' });
  app.register(sessionsRoutes, { prefix: '/api/v1' });
  app.register(qrCodeRoutes, { prefix: '/api/v1' });
  app.register(pwaRoutes, { prefix: '/api/v1' });
  app.register(welcomeRoutes);
  app.register(cableRoutes);

  // Rails path compatibility aliases (without /api/v1 prefix)
  app.register(roomsRoutes, { prefix: '/rooms' });
  app.register(messagesRoutes, { prefix: '/messages' });
  app.register(searchesRoutes, { prefix: '/searches' });
  app.register(usersRoutes, { prefix: '/users' });
  app.register(moderationRoutes);
  app.register(pushSubscriptionsRoutes);
  app.register(firstRunRoutes);
  app.register(unfurlLinkRoutes);
  app.register(accountRoutes);
  app.register(autocompletableRoutes);
  app.register(joinRoutes);
  app.register(sessionTransfersRoutes);
  app.register(sessionsRoutes);
  app.register(qrCodeRoutes);
  app.register(pwaRoutes);

  return app;
}
