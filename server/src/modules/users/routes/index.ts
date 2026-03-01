import type { FastifyPluginAsync } from 'fastify';
import { usersController } from '../controllers/users.controller.js';

const usersRoutes: FastifyPluginAsync = async (app) => {
  app.get('/api/v1/join/:joinCode', usersController.joinNew);
  app.post('/api/v1/join/:joinCode', usersController.joinCreate);

  app.get('/api/v1/users/:id', { preHandler: app.authenticate }, usersController.show);

  app.get('/api/v1/users/:userId/avatar', { preHandler: app.authenticate }, usersController.avatarShow);
  app.delete('/api/v1/users/:userId/avatar', { preHandler: app.authenticate }, usersController.avatarDestroy);

  app.post('/api/v1/users/:userId/ban', { preHandler: app.authenticate }, usersController.banCreate);
  app.delete('/api/v1/users/:userId/ban', { preHandler: app.authenticate }, usersController.banDestroy);

  app.get('/api/v1/users/me/sidebar', { preHandler: app.authenticate }, usersController.sidebarShow);
  app.get('/api/v1/users/me/profile', { preHandler: app.authenticate }, usersController.profileShow);
  app.patch('/api/v1/users/me/profile', { preHandler: app.authenticate }, usersController.profileUpdate);

  app.get('/api/v1/autocompletable/users', { preHandler: app.authenticate }, usersController.autocompletableIndex);
};

export default usersRoutes;
