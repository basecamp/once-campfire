import type { FastifyPluginAsync } from 'fastify';
import { accountController } from '../controllers/account.controller.js';

const accountRoutes: FastifyPluginAsync = async (app) => {
  app.get('/account/edit', { preHandler: app.authenticate }, accountController.show);
  app.get('/api/v1/account', { preHandler: app.authenticate }, accountController.show);
  app.patch('/api/v1/account', { preHandler: app.authenticate }, accountController.update);

  app.get('/api/v1/account/users', { preHandler: app.authenticate }, accountController.usersIndex);
  app.patch('/api/v1/account/users/:id', { preHandler: app.authenticate }, accountController.usersUpdate);
  app.delete('/api/v1/account/users/:id', { preHandler: app.authenticate }, accountController.usersDestroy);

  app.get('/api/v1/account/bots', { preHandler: app.authenticate }, accountController.botsIndex);
  app.post('/api/v1/account/bots', { preHandler: app.authenticate }, accountController.botsCreate);
  app.get('/account/bots/:id/edit', { preHandler: app.authenticate }, accountController.botsEdit);
  app.patch('/api/v1/account/bots/:id', { preHandler: app.authenticate }, accountController.botsUpdate);
  app.delete('/api/v1/account/bots/:id', { preHandler: app.authenticate }, accountController.botsDestroy);
  app.patch('/api/v1/account/bots/:botId/key', { preHandler: app.authenticate }, accountController.botKeyReset);

  app.post('/api/v1/account/join_code', { preHandler: app.authenticate }, accountController.joinCodeReset);

  app.get('/api/v1/account/logo', accountController.logoShow);
  app.delete('/api/v1/account/logo', { preHandler: app.authenticate }, accountController.logoDestroy);

  app.get('/api/v1/account/custom_styles/edit', { preHandler: app.authenticate }, accountController.customStylesShow);
  app.patch('/api/v1/account/custom_styles', { preHandler: app.authenticate }, accountController.customStylesUpdate);
};

export default accountRoutes;
