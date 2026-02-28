import type { FastifyPluginAsync } from 'fastify';

const healthRoute: FastifyPluginAsync = async (app) => {
  app.get('/health', async () => ({ status: 'ok' }));
  app.get('/up', async () => ({ status: 'ok' }));
};

export default healthRoute;
