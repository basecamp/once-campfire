import type { FastifyPluginAsync } from 'fastify';
import { searchesController } from '../controllers/searches.controller.js';

const searchesRoutes: FastifyPluginAsync = async (app) => {
  app.get('/api/v1/searches', { preHandler: app.authenticate }, searchesController.index);
  app.post('/api/v1/searches', { preHandler: app.authenticate }, searchesController.create);
  app.delete('/api/v1/searches/clear', { preHandler: app.authenticate }, searchesController.clear);
};

export default searchesRoutes;
