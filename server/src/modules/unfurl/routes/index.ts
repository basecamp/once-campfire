import type { FastifyPluginAsync } from 'fastify';
import { unfurlController } from '../controllers/unfurl.controller.js';

const unfurlRoutes: FastifyPluginAsync = async (app) => {
  app.post('/api/v1/unfurl_link', { preHandler: app.authenticate }, unfurlController.create);
};

export default unfurlRoutes;
