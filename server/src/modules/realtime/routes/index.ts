import type { FastifyPluginAsync } from 'fastify';
import { realtimeController } from '../controllers/realtime.controller.js';
import { systemController } from '../controllers/system.controller.js';
import { sendData } from '../../../shared/utils/controller.js';

const realtimeRoutes: FastifyPluginAsync = async (app) => {
  app.get('/up', async (request, reply) => sendData(request, reply, { ok: true }));
  app.get('/api/v1/health', async (request, reply) => sendData(request, reply, { ok: true }));

  app.get('/', { preHandler: app.authenticate }, systemController.welcome);

  app.get('/api/v1/first_run', systemController.firstRunShow);
  app.post('/api/v1/first_run', systemController.firstRunCreate);

  app.get('/session/new', systemController.sessionNew);
  app.post('/session', systemController.sessionCreate);
  app.delete('/session', { preHandler: app.authenticate }, systemController.sessionDestroy);

  app.get('/api/v1/session/transfers/:id', systemController.sessionTransferShow);
  app.patch('/api/v1/session/transfers/:id', systemController.sessionTransferUpdate);

  app.get('/qr_code/:id', systemController.qrCode);
  app.get('/api/v1/qr_code/:id', systemController.qrCode);

  app.get('/webmanifest', systemController.pwaManifest);
  app.get('/api/v1/webmanifest', systemController.pwaManifest);
  app.get('/service-worker', systemController.serviceWorker);
  app.get('/api/v1/service-worker', systemController.serviceWorker);

  app.get('/api/v1/realtime/stream', { preHandler: app.authenticate }, realtimeController.stream);
  app.post('/api/v1/realtime/rooms/:roomId/presence/present', { preHandler: app.authenticate }, realtimeController.presencePresent);
  app.post('/api/v1/realtime/rooms/:roomId/presence/absent', { preHandler: app.authenticate }, realtimeController.presenceAbsent);
  app.post('/api/v1/realtime/rooms/:roomId/presence/refresh', { preHandler: app.authenticate }, realtimeController.presenceRefresh);
  app.post('/api/v1/realtime/rooms/:roomId/typing/start', { preHandler: app.authenticate }, realtimeController.typingStart);
  app.post('/api/v1/realtime/rooms/:roomId/typing/stop', { preHandler: app.authenticate }, realtimeController.typingStop);
};

export default realtimeRoutes;
