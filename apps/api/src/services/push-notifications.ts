import webpush from 'web-push';
import { env } from '../config/env.js';
import { MembershipModel } from '../models/membership.model.js';
import { PushSubscriptionModel } from '../models/push-subscription.model.js';

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

type PushPayload = {
  title: string;
  body: string;
  path: string;
};

export async function deliverPushNotifications(userIds: string[], payload: PushPayload) {
  if (userIds.length === 0) {
    return;
  }

  if (!ensureVapid()) {
    return;
  }

  const subscriptions = await PushSubscriptionModel.find({ userId: { $in: userIds } }).lean();
  if (subscriptions.length === 0) {
    return;
  }

  const unreadByUserId = new Map(
    await Promise.all(
      userIds.map(async (userId) => {
        const count = await MembershipModel.countDocuments({ userId, unreadAt: { $ne: null } });
        return [userId, count] as const;
      })
    )
  );

  await Promise.all(
    subscriptions.map(async (subscription) => {
        const message = JSON.stringify({
          title: payload.title,
          options: {
            body: payload.body,
            icon: `${env.APP_BASE_URL}/account/logo`,
            data: {
              path: payload.path,
              badge: unreadByUserId.get(String(subscription.userId)) ?? 0
            }
          }
      });

      try {
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
      } catch (error) {
        const statusCode = (error as { statusCode?: number }).statusCode;
        if (statusCode === 404 || statusCode === 410) {
          await PushSubscriptionModel.deleteOne({ _id: subscription._id });
        }
      }
    })
  );
}
