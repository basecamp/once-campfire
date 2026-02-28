import { randomUUID } from 'node:crypto';
import webpush from 'web-push';
import type { FastifyPluginAsync } from 'fastify';
import { z } from 'zod';
import { env } from '../config/env.js';
import { asObjectId } from '../lib/object-id.js';
import { PushSubscriptionModel } from '../models/push-subscription.model.js';

const createSubscriptionSchema = z.object({
  endpoint: z.string().url(),
  p256dhKey: z.string().min(1),
  authKey: z.string().min(1)
});

let vapidConfigured = false;

function ensureVapid() {
  if (vapidConfigured) {
    return true;
  }

  if (!env.VAPID_PUBLIC_KEY || !env.VAPID_PRIVATE_KEY) {
    return false;
  }

  webpush.setVapidDetails(env.VAPID_SUBJECT, env.VAPID_PUBLIC_KEY, env.VAPID_PRIVATE_KEY);
  vapidConfigured = true;
  return true;
}

const pushSubscriptionsRoutes: FastifyPluginAsync = async (app) => {
  app.get('/users/me/push-subscriptions', { preHandler: app.authenticate }, async (request, reply) => {
    const userId = request.authUserId;
    if (!userId) {
      return reply.code(401).send({ error: 'Unauthorized' });
    }

    const subscriptions = await PushSubscriptionModel.find({ userId }).sort({ createdAt: -1 }).lean();

    return {
      subscriptions: subscriptions.map((subscription) => ({
        id: String(subscription._id),
        endpoint: subscription.endpoint,
        p256dhKey: subscription.p256dhKey,
        authKey: subscription.authKey,
        userAgent: subscription.userAgent,
        createdAt: subscription.createdAt
      }))
    };
  });

  app.post('/users/me/push-subscriptions', { preHandler: app.authenticate }, async (request, reply) => {
    const userId = request.authUserId;
    if (!userId) {
      return reply.code(401).send({ error: 'Unauthorized' });
    }

    const payload = createSubscriptionSchema.parse(request.body);

    const existing = await PushSubscriptionModel.findOne({
      endpoint: payload.endpoint,
      p256dhKey: payload.p256dhKey,
      authKey: payload.authKey
    });

    if (existing) {
      existing.userId = asObjectId(userId) ?? existing.userId;
      existing.userAgent = request.headers['user-agent'] ?? '';
      await existing.save();
      return { ok: true };
    }

    await PushSubscriptionModel.create({
      userId,
      endpoint: payload.endpoint,
      p256dhKey: payload.p256dhKey,
      authKey: payload.authKey,
      userAgent: request.headers['user-agent'] ?? ''
    });

    return { ok: true };
  });

  app.delete('/users/me/push-subscriptions/:subscriptionId', { preHandler: app.authenticate }, async (request, reply) => {
    const userId = request.authUserId;
    if (!userId) {
      return reply.code(401).send({ error: 'Unauthorized' });
    }

    const { subscriptionId } = request.params as { subscriptionId: string };
    const objectId = asObjectId(subscriptionId);
    if (!objectId) {
      return reply.code(400).send({ error: 'Invalid subscription id' });
    }

    await PushSubscriptionModel.deleteOne({ _id: objectId, userId });
    return reply.code(204).send();
  });

  app.post('/users/me/push-subscriptions/:subscriptionId/test', { preHandler: app.authenticate }, async (request, reply) => {
    const userId = request.authUserId;
    if (!userId) {
      return reply.code(401).send({ error: 'Unauthorized' });
    }

    const { subscriptionId } = request.params as { subscriptionId: string };
    const objectId = asObjectId(subscriptionId);
    if (!objectId) {
      return reply.code(400).send({ error: 'Invalid subscription id' });
    }

    const subscription = await PushSubscriptionModel.findOne({ _id: objectId, userId }).lean();
    if (!subscription) {
      return reply.code(404).send({ error: 'Subscription not found' });
    }

    if (!ensureVapid()) {
      return reply.code(400).send({ error: 'VAPID keys are not configured' });
    }

    const message = JSON.stringify({
      title: 'Campfire Test',
      options: {
        body: randomUUID(),
        icon: `${env.APP_BASE_URL}/favicon.ico`,
        data: {
          path: '/users/me/push-subscriptions',
          badge: 0
        }
      }
    });

    await webpush.sendNotification(
      {
        endpoint: subscription.endpoint,
        keys: {
          p256dh: subscription.p256dhKey,
          auth: subscription.authKey
        }
      },
      message,
      {
        urgency: 'high'
      }
    );

    return { ok: true };
  });
};

export default pushSubscriptionsRoutes;
