import { createHmac } from 'node:crypto';
import { MembershipModel } from '../models/membership.model.js';
import { WebhookModel } from '../models/webhook.model.js';

export type WebhookEventType = 'message.created' | 'message.boosted';

type DispatchOptions = {
  event: WebhookEventType;
  roomId: string;
  payload: Record<string, unknown>;
};

function signPayload(secret: string, body: string) {
  if (!secret) {
    return '';
  }

  return createHmac('sha256', secret).update(body).digest('hex');
}

async function postWebhook(url: string, secret: string, event: string, body: string) {
  const controller = new AbortController();
  const timeout = setTimeout(() => controller.abort(), 5000);

  try {
    const signature = signPayload(secret, body);

    const response = await fetch(url, {
      method: 'POST',
      headers: {
        'content-type': 'application/json',
        'x-campfire-event': event,
        ...(signature ? { 'x-campfire-signature': signature } : {})
      },
      body,
      signal: controller.signal
    });

    if (!response.ok) {
      throw new Error(`Webhook responded with status ${response.status}`);
    }

    return { ok: true as const };
  } catch (error) {
    return {
      ok: false as const,
      error: error instanceof Error ? error.message : 'Unknown webhook error'
    };
  } finally {
    clearTimeout(timeout);
  }
}

export async function dispatchWebhookEvent({ event, roomId, payload }: DispatchOptions) {
  const memberships = await MembershipModel.find({ roomId }, { userId: 1 }).lean();
  const memberIds = memberships.map((membership) => membership.userId);

  if (memberIds.length === 0) {
    return;
  }

  const webhooks = await WebhookModel.find({
    userId: { $in: memberIds },
    active: true,
    events: event
  }).lean();

  if (webhooks.length === 0) {
    return;
  }

  const body = JSON.stringify({
    event,
    occurredAt: new Date().toISOString(),
    payload
  });

  await Promise.all(
    webhooks.map(async (webhook) => {
      if (webhook.roomIds.length > 0 && !webhook.roomIds.some((currentRoomId) => String(currentRoomId) === roomId)) {
        return;
      }

      const result = await postWebhook(webhook.url, webhook.secret ?? '', event, body);

      if (result.ok) {
        await WebhookModel.updateOne(
          { _id: webhook._id },
          { $set: { lastSuccessAt: new Date(), lastError: '' } }
        );
      } else {
        await WebhookModel.updateOne(
          { _id: webhook._id },
          { $set: { lastError: result.error } }
        );
      }
    })
  );
}
