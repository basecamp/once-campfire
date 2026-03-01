import type { FastifyPluginAsync } from 'fastify';
import { messagesController } from '../controllers/messages.controller.js';
import { boostsController } from '../controllers/boosts.controller.js';

const messagesRoutes: FastifyPluginAsync = async (app) => {
  app.get('/api/v1/rooms/:roomId/messages', { preHandler: app.authenticate }, messagesController.index);
  app.post('/api/v1/rooms/:roomId/messages', { preHandler: app.authenticate }, messagesController.create);
  app.get('/api/v1/rooms/:roomId/messages/:messageId', { preHandler: app.authenticate }, messagesController.show);
  app.patch('/api/v1/rooms/:roomId/messages/:messageId', { preHandler: app.authenticate }, messagesController.update);
  app.delete('/api/v1/rooms/:roomId/messages/:messageId', { preHandler: app.authenticate }, messagesController.destroy);
  app.post('/api/v1/rooms/:roomId/:botKey/messages', { preHandler: app.authenticate }, messagesController.createByBot);

  app.get('/api/v1/messages/:messageId/boosts', { preHandler: app.authenticate }, boostsController.index);
  app.post('/api/v1/messages/:messageId/boosts', { preHandler: app.authenticate }, boostsController.create);
  app.delete('/api/v1/messages/:messageId/boosts/:boostId', { preHandler: app.authenticate }, boostsController.destroy);
};

export default messagesRoutes;
