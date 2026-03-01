import type { FastifyPluginAsync } from 'fastify';
import { roomsController } from '../controllers/rooms.controller.js';

const roomsRoutes: FastifyPluginAsync = async (app) => {
  app.post('/rooms/opens', { preHandler: app.authenticate }, roomsController.openCreate);
  app.patch('/rooms/opens/:id', { preHandler: app.authenticate }, roomsController.openUpdate);
  app.post('/rooms/closeds', { preHandler: app.authenticate }, roomsController.closedCreate);
  app.patch('/rooms/closeds/:id', { preHandler: app.authenticate }, roomsController.closedUpdate);

  app.get('/api/v1/rooms', { preHandler: app.authenticate }, roomsController.index);
  app.get('/rooms', { preHandler: app.authenticate }, roomsController.index);

  app.post('/api/v1/rooms', { preHandler: app.authenticate }, async (request, reply) => {
    const type = String((request.body as { type?: unknown })?.type ?? '').toLowerCase();
    if (type === 'closed') {
      return roomsController.closedCreate(request, reply);
    }
    if (type === 'direct') {
      return roomsController.directCreate(request, reply);
    }
    return roomsController.openCreate(request, reply);
  });
  app.post('/rooms', { preHandler: app.authenticate }, async (request, reply) => {
    const type = String((request.body as { type?: unknown })?.type ?? '').toLowerCase();
    if (type === 'closed') {
      return roomsController.closedCreate(request, reply);
    }
    if (type === 'direct') {
      return roomsController.directCreate(request, reply);
    }
    return roomsController.openCreate(request, reply);
  });

  app.get('/api/v1/rooms/:roomId', { preHandler: app.authenticate }, roomsController.show);
  app.get('/rooms/:roomId', { preHandler: app.authenticate }, roomsController.show);
  app.get('/rooms/:roomId/@:messageId', { preHandler: app.authenticate }, roomsController.show);

  app.delete('/api/v1/rooms/:roomId', { preHandler: app.authenticate }, roomsController.destroy);
  app.delete('/rooms/:roomId', { preHandler: app.authenticate }, roomsController.destroy);

  app.get('/api/v1/rooms/:roomId/refresh', { preHandler: app.authenticate }, roomsController.refresh);
  app.get('/api/v1/rooms/:roomId/settings', { preHandler: app.authenticate }, roomsController.settingsShow);
  app.get('/api/v1/rooms/:roomId/involvement', { preHandler: app.authenticate }, roomsController.involvementShow);
  app.patch('/api/v1/rooms/:roomId/involvement', { preHandler: app.authenticate }, roomsController.involvementUpdate);

  app.post('/api/v1/rooms/directs', { preHandler: app.authenticate }, roomsController.directCreate);
};

export default roomsRoutes;
