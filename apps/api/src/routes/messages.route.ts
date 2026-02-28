import type { FastifyPluginAsync } from 'fastify';
import { z } from 'zod';
import { asObjectId } from '../lib/object-id.js';
import { BoostModel } from '../models/boost.model.js';
import { MembershipModel } from '../models/membership.model.js';
import { MessageModel } from '../models/message.model.js';
import { UserModel } from '../models/user.model.js';
import { enqueueWebhookDispatch } from '../queues/webhook.queue.js';
import { publishRealtimeEvent } from '../realtime/redis-realtime.js';
import {
  buildAttachmentImageVariant,
  coerceAttachmentWithData,
  isAttachmentPreviewable,
  type StoredMessageAttachmentWithData
} from '../services/message-attachment.js';

const createBoostSchema = z.object({
  content: z.string().trim().min(1).max(16)
});

type AttachmentLoadResult =
  | { error: 'invalid_message_id' | 'message_not_found' | 'forbidden' | 'attachment_not_found' }
  | {
      message: {
        roomId: unknown;
      };
      attachment: StoredMessageAttachmentWithData;
    };

async function loadAttachmentForUser(messageId: string, userId: string): Promise<AttachmentLoadResult> {
  const messageObjectId = asObjectId(messageId);
  if (!messageObjectId) {
    return { error: 'invalid_message_id' as const };
  }

  const message = await MessageModel.findById(messageObjectId).lean();
  if (!message) {
    return { error: 'message_not_found' as const };
  }

  const membership = await MembershipModel.findOne({ roomId: message.roomId, userId }).lean();
  if (!membership) {
    return { error: 'forbidden' as const };
  }

  if (!message.attachment) {
    return { error: 'attachment_not_found' as const };
  }

  const attachment = coerceAttachmentWithData(message.attachment as { data: unknown; contentType: string; filename: string; byteSize: number });
  if (!attachment) {
    return { error: 'attachment_not_found' as const };
  }

  return {
    message,
    attachment
  };
}

function sendAttachmentLoadError(reply: import('fastify').FastifyReply, loaded: AttachmentLoadResult) {
  if (!('error' in loaded)) {
    return false;
  }

  switch (loaded.error) {
    case 'invalid_message_id':
      void reply.code(400).send({ error: 'Invalid message id' });
      return true;
    case 'message_not_found':
      void reply.code(404).send({ error: 'Message not found' });
      return true;
    case 'forbidden':
      void reply.code(403).send({ error: 'You are not a room member' });
      return true;
    case 'attachment_not_found':
      void reply.code(404).send({ error: 'Attachment not found' });
      return true;
    default:
      return false;
  }
}

function setAttachmentHeaders(
  reply: import('fastify').FastifyReply,
  attachment: { contentType: string; filename: string },
  disposition: 'inline' | 'attachment'
) {
  const safeFilename = attachment.filename.replace(/"/g, '');
  reply.header('content-type', attachment.contentType);
  reply.header('content-disposition', `${disposition}; filename="${safeFilename}"`);
}

const messagesRoutes: FastifyPluginAsync = async (app) => {
  app.get('/:messageId/attachment', { preHandler: app.authenticate }, async (request, reply) => {
    const userId = request.authUserId;
    if (!userId) {
      return reply.code(401).send({ error: 'Unauthorized' });
    }

    const { messageId } = request.params as { messageId: string };
    const loaded = await loadAttachmentForUser(messageId, userId);
    if ('error' in loaded) {
      sendAttachmentLoadError(reply, loaded);
      return;
    }

    const disposition = ((request.query as { disposition?: string } | undefined)?.disposition ?? '').toLowerCase();
    const normalizedDisposition = disposition === 'attachment' ? 'attachment' : 'inline';
    setAttachmentHeaders(reply, loaded.attachment, normalizedDisposition);

    return reply.send(loaded.attachment.data);
  });

  app.get('/:messageId/attachment/thumb', { preHandler: app.authenticate }, async (request, reply) => {
    const userId = request.authUserId;
    if (!userId) {
      return reply.code(401).send({ error: 'Unauthorized' });
    }

    const { messageId } = request.params as { messageId: string };
    const loaded = await loadAttachmentForUser(messageId, userId);
    if ('error' in loaded) {
      sendAttachmentLoadError(reply, loaded);
      return;
    }

    const variant = await buildAttachmentImageVariant(loaded.attachment);
    if (!variant) {
      return reply.code(404).send({ error: 'Thumbnail not available' });
    }

    setAttachmentHeaders(reply, variant, 'inline');
    return reply.send(variant.data);
  });

  app.get('/:messageId/attachment/preview', { preHandler: app.authenticate }, async (request, reply) => {
    const userId = request.authUserId;
    if (!userId) {
      return reply.code(401).send({ error: 'Unauthorized' });
    }

    const { messageId } = request.params as { messageId: string };
    const loaded = await loadAttachmentForUser(messageId, userId);
    if ('error' in loaded) {
      sendAttachmentLoadError(reply, loaded);
      return;
    }

    const variant = await buildAttachmentImageVariant(loaded.attachment);
    if (variant) {
      setAttachmentHeaders(reply, variant, 'inline');
      return reply.send(variant.data);
    }

    if (!isAttachmentPreviewable(loaded.attachment.contentType)) {
      return reply.code(404).send({ error: 'Preview not available' });
    }

    setAttachmentHeaders(reply, loaded.attachment, 'inline');
    return reply.send(loaded.attachment.data);
  });

  app.get('/:messageId/boosts', { preHandler: app.authenticate }, async (request, reply) => {
    const userId = request.authUserId;
    if (!userId) {
      return reply.code(401).send({ error: 'Unauthorized' });
    }

    const { messageId } = request.params as { messageId: string };
    const messageObjectId = asObjectId(messageId);
    if (!messageObjectId) {
      return reply.code(400).send({ error: 'Invalid message id' });
    }

    const message = await MessageModel.findById(messageObjectId).lean();
    if (!message) {
      return reply.code(404).send({ error: 'Message not found' });
    }

    const membership = await MembershipModel.findOne({ roomId: message.roomId, userId }).lean();
    if (!membership) {
      return reply.code(403).send({ error: 'You are not a room member' });
    }

    const boosts = await BoostModel.find({ messageId: messageObjectId }).sort({ createdAt: 1 }).lean();

    return {
      boosts: boosts.map((boost) => ({
        id: String(boost._id),
        messageId: String(boost.messageId),
        boosterId: String(boost.boosterId),
        content: boost.content,
        createdAt: boost.createdAt
      }))
    };
  });

  app.post('/:messageId/boosts', { preHandler: app.authenticate }, async (request, reply) => {
    const userId = request.authUserId;
    if (!userId) {
      return reply.code(401).send({ error: 'Unauthorized' });
    }

    const { messageId } = request.params as { messageId: string };
    const messageObjectId = asObjectId(messageId);
    if (!messageObjectId) {
      return reply.code(400).send({ error: 'Invalid message id' });
    }

    const payload = createBoostSchema.parse(request.body);

    const message = await MessageModel.findById(messageObjectId).lean();
    if (!message) {
      return reply.code(404).send({ error: 'Message not found' });
    }

    const membership = await MembershipModel.findOne({ roomId: message.roomId, userId }).lean();
    if (!membership) {
      return reply.code(403).send({ error: 'You are not a room member' });
    }

    const existing = await BoostModel.findOne({
      messageId: messageObjectId,
      boosterId: userId,
      content: payload.content
    }).lean();

    if (existing) {
      return reply.code(200).send({
        boost: {
          id: String(existing._id),
          messageId: String(existing.messageId),
          boosterId: String(existing.boosterId),
          content: existing.content,
          createdAt: existing.createdAt
        }
      });
    }

    const boost = await BoostModel.create({
      messageId: messageObjectId,
      boosterId: userId,
      content: payload.content
    });

    const actor = await UserModel.findById(userId, { name: 1 }).lean();

    const responseBoost = {
      id: String(boost._id),
      messageId: String(boost.messageId),
      boosterId: String(boost.boosterId),
      content: boost.content,
      actorName: actor?.name ?? 'Unknown',
      createdAt: boost.createdAt
    };

    await publishRealtimeEvent({
      type: 'message.boosted',
      roomId: String(message.roomId),
      payload: {
        messageId: String(message._id),
        boost: responseBoost
      }
    });

    await enqueueWebhookDispatch({
      event: 'message.boosted',
      roomId: String(message.roomId),
      payload: {
        messageId: String(message._id),
        boost: responseBoost
      }
    });

    return reply.code(201).send({ boost: responseBoost });
  });

  app.delete('/:messageId/boosts/:boostId', { preHandler: app.authenticate }, async (request, reply) => {
    const userId = request.authUserId;
    if (!userId) {
      return reply.code(401).send({ error: 'Unauthorized' });
    }

    const { messageId, boostId } = request.params as { messageId: string; boostId: string };
    const messageObjectId = asObjectId(messageId);
    const boostObjectId = asObjectId(boostId);

    if (!messageObjectId || !boostObjectId) {
      return reply.code(400).send({ error: 'Invalid id' });
    }

    const message = await MessageModel.findById(messageObjectId).lean();
    if (!message) {
      return reply.code(404).send({ error: 'Message not found' });
    }

    const membership = await MembershipModel.findOne({ roomId: message.roomId, userId }).lean();
    if (!membership) {
      return reply.code(403).send({ error: 'You are not a room member' });
    }

    const boost = await BoostModel.findById(boostObjectId).lean();
    if (!boost || String(boost.messageId) !== String(messageObjectId)) {
      return reply.code(404).send({ error: 'Boost not found' });
    }

    if (String(boost.boosterId) !== userId) {
      return reply.code(403).send({ error: 'You can only remove your own boosts' });
    }

    await BoostModel.deleteOne({ _id: boostObjectId });

    await publishRealtimeEvent({
      type: 'message.boost_removed',
      roomId: String(message.roomId),
      payload: {
        messageId: String(message._id),
        boostId: String(boost._id)
      }
    });

    return reply.code(204).send();
  });
};

export default messagesRoutes;
