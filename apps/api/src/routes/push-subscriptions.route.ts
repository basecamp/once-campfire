import { randomUUID } from 'node:crypto';
import webpush from 'web-push';
import type { FastifyPluginAsync, RouteHandlerMethod } from 'fastify';
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

function resolveUserId(rawUserId: string | undefined, authUserId: string) {
  if (!rawUserId || rawUserId === 'me') {
    return authUserId;
  }

  if (rawUserId !== authUserId) {
    return null;
  }

  return authUserId;
}

function parseSubscriptionPayload(input: unknown) {
  if (!input || typeof input !== 'object') {
    return createSubscriptionSchema.parse(input);
  }

  const payload = input as {
    endpoint?: unknown;
    p256dhKey?: unknown;
    p256dh_key?: unknown;
    authKey?: unknown;
    auth_key?: unknown;
    push_subscription?: {
      endpoint?: unknown;
      p256dhKey?: unknown;
      p256dh_key?: unknown;
      authKey?: unknown;
      auth_key?: unknown;
    };
  };

  const nested = payload.push_subscription;

  return createSubscriptionSchema.parse({
    endpoint:
      (typeof nested?.endpoint === 'string' ? nested.endpoint : undefined) ??
      (typeof payload.endpoint === 'string' ? payload.endpoint : undefined),
    p256dhKey:
      (typeof nested?.p256dhKey === 'string' ? nested.p256dhKey : undefined) ??
      (typeof nested?.p256dh_key === 'string' ? nested.p256dh_key : undefined) ??
      (typeof payload.p256dhKey === 'string' ? payload.p256dhKey : undefined) ??
      (typeof payload.p256dh_key === 'string' ? payload.p256dh_key : undefined),
    authKey:
      (typeof nested?.authKey === 'string' ? nested.authKey : undefined) ??
      (typeof nested?.auth_key === 'string' ? nested.auth_key : undefined) ??
      (typeof payload.authKey === 'string' ? payload.authKey : undefined) ??
      (typeof payload.auth_key === 'string' ? payload.auth_key : undefined)
  });
}

const pushSubscriptionsRoutes: FastifyPluginAsync = async (app) => {
  const listSubscriptions: RouteHandlerMethod = async (request, reply) => {
    const authUserId = request.authUserId;
    if (!authUserId) {
      return reply.code(401).send({ error: 'Unauthorized' });
    }

    const { userId: routeUserId } = request.params as { userId?: string };
    const userId = resolveUserId(routeUserId, authUserId);

    if (!userId) {
      return reply.code(403).send({ error: 'Forbidden' });
    }

    const subscriptions = await PushSubscriptionModel.find({ userId }).sort({ createdAt: -1 }).lean();

    return {
      subscriptions: subscriptions.map((subscription) => ({
        id: String(subscription._id),
        endpoint: subscription.endpoint,
        p256dhKey: subscription.p256dhKey,
        p256dh_key: subscription.p256dhKey,
        authKey: subscription.authKey,
        auth_key: subscription.authKey,
        userAgent: subscription.userAgent,
        user_agent: subscription.userAgent,
        createdAt: subscription.createdAt,
        created_at: subscription.createdAt
      }))
    };
  };

  const createSubscription: RouteHandlerMethod = async (request, reply) => {
    const authUserId = request.authUserId;
    if (!authUserId) {
      return reply.code(401).send({ error: 'Unauthorized' });
    }

    const { userId: routeUserId } = request.params as { userId?: string };
    const userId = resolveUserId(routeUserId, authUserId);

    if (!userId) {
      return reply.code(403).send({ error: 'Forbidden' });
    }

    const payload = parseSubscriptionPayload(request.body);

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
  };

  const deleteSubscription: RouteHandlerMethod = async (request, reply) => {
    const authUserId = request.authUserId;
    if (!authUserId) {
      return reply.code(401).send({ error: 'Unauthorized' });
    }

    const params = request.params as { userId?: string; subscriptionId?: string; id?: string };
    const userId = resolveUserId(params.userId, authUserId);

    if (!userId) {
      return reply.code(403).send({ error: 'Forbidden' });
    }

    const subscriptionId = params.subscriptionId ?? params.id;
    if (!subscriptionId) {
      return reply.code(400).send({ error: 'Invalid subscription id' });
    }

    const objectId = asObjectId(subscriptionId);
    if (!objectId) {
      return reply.code(400).send({ error: 'Invalid subscription id' });
    }

    await PushSubscriptionModel.deleteOne({ _id: objectId, userId });
    return reply.code(204).send();
  };

  const testSubscription: RouteHandlerMethod = async (request, reply) => {
    const authUserId = request.authUserId;
    if (!authUserId) {
      return reply.code(401).send({ error: 'Unauthorized' });
    }

    const params = request.params as {
      userId?: string;
      subscriptionId?: string;
      push_subscription_id?: string;
    };

    const userId = resolveUserId(params.userId, authUserId);

    if (!userId) {
      return reply.code(403).send({ error: 'Forbidden' });
    }

    const subscriptionId = params.subscriptionId ?? params.push_subscription_id;
    if (!subscriptionId) {
      return reply.code(400).send({ error: 'Invalid subscription id' });
    }

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
        icon: `${env.APP_BASE_URL}/account/logo`,
        data: {
          path: '/users/me/push_subscriptions',
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
  };

  app.get('/users/me/push-subscriptions', { preHandler: app.authenticate }, listSubscriptions);
  app.post('/users/me/push-subscriptions', { preHandler: app.authenticate }, createSubscription);
  app.delete('/users/me/push-subscriptions/:subscriptionId', { preHandler: app.authenticate }, deleteSubscription);
  app.post('/users/me/push-subscriptions/:subscriptionId/test', { preHandler: app.authenticate }, testSubscription);

  app.get('/users/:userId/push_subscriptions', { preHandler: app.authenticate }, listSubscriptions);
  app.post('/users/:userId/push_subscriptions', { preHandler: app.authenticate }, createSubscription);
  app.delete('/users/:userId/push_subscriptions/:id', { preHandler: app.authenticate }, deleteSubscription);
  app.post(
    '/users/:userId/push_subscriptions/:push_subscription_id/test_notifications',
    { preHandler: app.authenticate },
    testSubscription
  );
};

export default pushSubscriptionsRoutes;
