import type { FastifyPluginAsync } from 'fastify';
import { createHmac } from 'node:crypto';
import { z } from 'zod';
import { asObjectId } from '../lib/object-id.js';
import { WebhookModel } from '../models/webhook.model.js';

function signPayload(secret: string, body: string) {
  if (!secret) {
    return '';
  }

  return createHmac('sha256', secret).update(body).digest('hex');
}

const createWebhookSchema = z.object({
  url: z.string().url(),
  secret: z.string().max(256).optional(),
  active: z.boolean().default(true),
  events: z.array(z.enum(['message.created', 'message.boosted'])).default(['message.created', 'message.boosted']),
  roomIds: z.array(z.string()).default([])
});

const webhooksRoutes: FastifyPluginAsync = async (app) => {
  app.get('/', { preHandler: app.authenticate }, async (request, reply) => {
    const userId = request.authUserId;
    if (!userId) {
      return reply.code(401).send({ error: 'Unauthorized' });
    }

    const webhooks = await WebhookModel.find({ userId }).sort({ createdAt: -1 }).lean();

    return {
      webhooks: webhooks.map((webhook) => ({
        id: String(webhook._id),
        url: webhook.url,
        active: webhook.active,
        events: webhook.events,
        roomIds: webhook.roomIds.map((roomId) => String(roomId)),
        lastSuccessAt: webhook.lastSuccessAt,
        lastError: webhook.lastError,
        createdAt: webhook.createdAt
      }))
    };
  });

  app.post('/', { preHandler: app.authenticate }, async (request, reply) => {
    const userId = request.authUserId;
    if (!userId) {
      return reply.code(401).send({ error: 'Unauthorized' });
    }

    const payload = createWebhookSchema.parse(request.body);

    const roomIds = payload.roomIds
      .map((roomId) => asObjectId(roomId))
      .filter((roomId): roomId is NonNullable<typeof roomId> => roomId !== null);

    const webhook = await WebhookModel.create({
      userId,
      url: payload.url,
      secret: payload.secret ?? '',
      active: payload.active,
      events: payload.events,
      roomIds
    });

    return reply.code(201).send({
      webhook: {
        id: String(webhook._id),
        url: webhook.url,
        active: webhook.active,
        events: webhook.events,
        roomIds: webhook.roomIds.map((roomId) => String(roomId)),
        createdAt: webhook.createdAt
      }
    });
  });

  app.delete('/:webhookId', { preHandler: app.authenticate }, async (request, reply) => {
    const userId = request.authUserId;
    if (!userId) {
      return reply.code(401).send({ error: 'Unauthorized' });
    }

    const { webhookId } = request.params as { webhookId: string };
    const webhookObjectId = asObjectId(webhookId);

    if (!webhookObjectId) {
      return reply.code(400).send({ error: 'Invalid webhook id' });
    }

    await WebhookModel.deleteOne({ _id: webhookObjectId, userId });

    return reply.code(204).send();
  });

  app.post('/:webhookId/test', { preHandler: app.authenticate }, async (request, reply) => {
    const userId = request.authUserId;
    if (!userId) {
      return reply.code(401).send({ error: 'Unauthorized' });
    }

    const { webhookId } = request.params as { webhookId: string };
    const webhookObjectId = asObjectId(webhookId);

    if (!webhookObjectId) {
      return reply.code(400).send({ error: 'Invalid webhook id' });
    }

    const webhook = await WebhookModel.findOne({ _id: webhookObjectId, userId }).lean();
    if (!webhook) {
      return reply.code(404).send({ error: 'Webhook not found' });
    }

    const body = JSON.stringify({
      event: 'message.created',
      occurredAt: new Date().toISOString(),
      payload: {
        test: true,
        webhookId: String(webhook._id)
      }
    });

    const signature = signPayload(webhook.secret ?? '', body);

    const response = await fetch(webhook.url, {
      method: 'POST',
      headers: {
        'content-type': 'application/json',
        'x-campfire-event': 'message.created',
        ...(signature ? { 'x-campfire-signature': signature } : {})
      },
      body
    });

    if (!response.ok) {
      await WebhookModel.updateOne(
        { _id: webhook._id },
        { $set: { lastError: `Test failed: ${response.status}` } }
      );
      return reply.code(502).send({ error: `Webhook test failed with status ${response.status}` });
    }

    await WebhookModel.updateOne(
      { _id: webhook._id },
      { $set: { lastSuccessAt: new Date(), lastError: '' } }
    );

    return { ok: true, status: response.status };
  });
};

export default webhooksRoutes;
