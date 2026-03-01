import type { FastifyReply, FastifyRequest } from 'fastify';
import { Types } from 'mongoose';
import { PushSubscriptionModel } from '../models/push-subscription.model.js';
import { getAuthUserId, sendData, sendError } from '../../../shared/utils/controller.js';

export const pushSubscriptionsController = {
  async index(request: FastifyRequest, reply: FastifyReply) {
    try {
      const userId = getAuthUserId(request);
      const subscriptions = await PushSubscriptionModel.find({ userId }).sort({ updatedAt: -1 }).lean();
      return sendData(request, reply, subscriptions);
    } catch {
      return sendError(reply, 401, 'UNAUTHORIZED', 'Unauthorized');
    }
  },

  async create(request: FastifyRequest, reply: FastifyReply) {
    try {
      const userId = getAuthUserId(request);
      const body = request.body as {
        endpoint?: string;
        p256dhKey?: string;
        p256dh_key?: string;
        authKey?: string;
        auth_key?: string;
      };

      const endpoint = body?.endpoint ?? null;
      const p256dhKey = body?.p256dhKey ?? body?.p256dh_key ?? null;
      const authKey = body?.authKey ?? body?.auth_key ?? null;

      if (!endpoint || !p256dhKey || !authKey) {
        return sendError(reply, 422, 'VALIDATION_ERROR', 'endpoint, p256dhKey and authKey are required');
      }

      let subscription = await PushSubscriptionModel.findOne({ userId, endpoint, p256dhKey, authKey });
      if (!subscription) {
        subscription = await PushSubscriptionModel.create({
          userId: new Types.ObjectId(userId),
          endpoint,
          p256dhKey,
          authKey,
          userAgent: request.headers['user-agent'] ?? null
        });
      } else {
        subscription.updatedAt = new Date();
        await subscription.save();
      }

      return sendData(request, reply, subscription.toObject());
    } catch {
      return sendError(reply, 401, 'UNAUTHORIZED', 'Unauthorized');
    }
  },

  async destroy(request: FastifyRequest, reply: FastifyReply) {
    try {
      const userId = getAuthUserId(request);
      const id = (request.params as { id?: string; subscriptionId?: string }).id ??
        (request.params as { subscriptionId?: string; push_subscription_id?: string }).subscriptionId ??
        (request.params as { push_subscription_id?: string }).push_subscription_id;

      if (!id) {
        return sendError(reply, 400, 'BAD_REQUEST', 'subscription id is required');
      }

      await PushSubscriptionModel.deleteOne({ _id: id, userId });
      return sendData(request, reply, { removed: true });
    } catch {
      return sendError(reply, 401, 'UNAUTHORIZED', 'Unauthorized');
    }
  },

  async testNotification(request: FastifyRequest, reply: FastifyReply) {
    try {
      const userId = getAuthUserId(request);
      const id = (request.params as { id?: string; subscriptionId?: string }).id ??
        (request.params as { subscriptionId?: string; push_subscription_id?: string }).subscriptionId ??
        (request.params as { push_subscription_id?: string }).push_subscription_id;

      if (!id) {
        return sendError(reply, 400, 'BAD_REQUEST', 'subscription id is required');
      }

      const subscription = await PushSubscriptionModel.findOne({ _id: id, userId }).lean();
      if (!subscription) {
        return sendError(reply, 404, 'NOT_FOUND', 'Subscription not found');
      }

      return sendData(request, reply, {
        tested: true,
        payload: {
          title: 'Campfire Test',
          body: crypto.randomUUID()
        },
        subscriptionId: String(subscription._id)
      });
    } catch {
      return sendError(reply, 401, 'UNAUTHORIZED', 'Unauthorized');
    }
  }
};
