import type { FastifyPluginAsync } from 'fastify';
import { moderationController } from '../controllers/moderation.controller.js';

const moderationRoutes: FastifyPluginAsync = async (app) => {
  app.post('/api/v1/moderation/users/:userId/ban', { preHandler: app.authenticate }, moderationController.ban);
  app.delete('/api/v1/moderation/users/:userId/ban', { preHandler: app.authenticate }, moderationController.unban);
};

export default moderationRoutes;
