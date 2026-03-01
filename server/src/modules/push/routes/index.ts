import type { FastifyPluginAsync } from 'fastify';
import { pushSubscriptionsController } from '../controllers/push-subscriptions.controller.js';

const pushRoutes: FastifyPluginAsync = async (app) => {
  app.get('/api/v1/users/:userId/push_subscriptions', { preHandler: app.authenticate }, pushSubscriptionsController.index);
  app.post('/api/v1/users/:userId/push_subscriptions', { preHandler: app.authenticate }, pushSubscriptionsController.create);
  app.delete('/api/v1/users/:userId/push_subscriptions/:id', { preHandler: app.authenticate }, pushSubscriptionsController.destroy);
  app.post(
    '/api/v1/users/:userId/push_subscriptions/:subscriptionId/test_notifications',
    { preHandler: app.authenticate },
    pushSubscriptionsController.testNotification
  );
  app.post(
    '/api/v1/users/:userId/push_subscriptions/:push_subscription_id/test_notifications',
    { preHandler: app.authenticate },
    pushSubscriptionsController.testNotification
  );

  app.get('/api/v1/users/me/push_subscriptions', { preHandler: app.authenticate }, pushSubscriptionsController.index);
  app.post('/api/v1/users/me/push_subscriptions', { preHandler: app.authenticate }, pushSubscriptionsController.create);
  app.delete('/api/v1/users/me/push_subscriptions/:id', { preHandler: app.authenticate }, pushSubscriptionsController.destroy);
  app.post(
    '/api/v1/users/me/push_subscriptions/:subscriptionId/test_notifications',
    { preHandler: app.authenticate },
    pushSubscriptionsController.testNotification
  );
  app.post(
    '/api/v1/users/me/push_subscriptions/:push_subscription_id/test_notifications',
    { preHandler: app.authenticate },
    pushSubscriptionsController.testNotification
  );
};

export default pushRoutes;
