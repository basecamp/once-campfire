import Fastify from 'fastify';
import cors from '@fastify/cors';
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

export function buildApp() {
  const app = Fastify({ logger: true });

  app.register(cors, {
    origin: true,
    credentials: true
  });

  app.register(mongoosePlugin);
  app.register(authPlugin);

  app.register(healthRoute, { prefix: '/api/v1' });
  app.register(authRoutes, { prefix: '/api/v1/auth' });
  app.register(roomsRoutes, { prefix: '/api/v1/rooms' });
  app.register(messagesRoutes, { prefix: '/api/v1/messages' });
  app.register(searchesRoutes, { prefix: '/api/v1/searches' });
  app.register(webhooksRoutes, { prefix: '/api/v1/webhooks' });
  app.register(realtimeRoutes, { prefix: '/api/v1/realtime' });
  app.register(usersRoutes, { prefix: '/api/v1/users' });
  app.register(moderationRoutes, { prefix: '/api/v1' });
  app.register(pushSubscriptionsRoutes, { prefix: '/api/v1' });

  return app;
}
