import { MembershipModel } from '../models/membership.model.js';
import { MessageModel } from '../models/message.model.js';
import { UserModel } from '../models/user.model.js';
import { enqueuePushMessageJob } from '../queues/push-message.queue.js';
import { enqueueWebhookDispatch } from '../queues/webhook.queue.js';
import { publishRealtimeEvent } from '../realtime/redis-realtime.js';
import { disconnectedMembershipFilter } from './membership-connection.js';
import { serializeMessageAttachment } from './message-attachment.js';

type MessageResponse = {
  id: string;
  clientMessageId: string;
  body: string;
  roomId: string;
  creatorId: string;
  creator?: {
    name: string;
  };
  boosts: unknown[];
  boostSummary: Record<string, number>;
  attachment?: {
    contentType: string;
    content_type: string;
    filename: string;
    byteSize: number;
    byte_size: number;
    width?: number | null;
    height?: number | null;
    previewable: boolean;
    variable: boolean;
    path: string;
    downloadPath: string;
    download_path: string;
    previewPath: string;
    preview_path: string;
    thumbPath: string;
    thumb_path: string;
  };
  createdAt: Date;
  updatedAt: Date;
};

export async function buildMessageResponse(messageId: string): Promise<MessageResponse | null> {
  const message = await MessageModel.findById(messageId).lean();
  if (!message) {
    return null;
  }

  const creator = await UserModel.findById(message.creatorId, { name: 1 }).lean();

  return {
    id: String(message._id),
    clientMessageId: message.clientMessageId,
    body: message.body,
    roomId: String(message.roomId),
    creatorId: String(message.creatorId),
    creator: creator
      ? {
          name: creator.name
        }
      : undefined,
    boosts: [],
    boostSummary: {},
    attachment: message.attachment ? serializeMessageAttachment(String(message._id), message.attachment) : undefined,
    createdAt: message.createdAt,
    updatedAt: message.updatedAt
  };
}

export async function handleMessageCreated({
  messageId,
  roomId,
  creatorId,
  enqueuePush = true,
  enqueueWebhook = true,
  publishUnread = true
}: {
  messageId: string;
  roomId: string;
  creatorId: string;
  enqueuePush?: boolean;
  enqueueWebhook?: boolean;
  publishUnread?: boolean;
}) {
  const responseMessage = await buildMessageResponse(messageId);
  if (!responseMessage) {
    return null;
  }

  const memberships = await MembershipModel.find({ roomId }, { userId: 1, involvement: 1, connectedAt: 1 }).lean();

  await MembershipModel.updateMany(
    {
      roomId,
      userId: { $ne: creatorId },
      involvement: { $ne: 'invisible' },
      ...disconnectedMembershipFilter()
    },
    { $set: { unreadAt: responseMessage.createdAt } }
  );

  await publishRealtimeEvent({
    type: 'message.created',
    roomId,
    payload: { message: responseMessage }
  });

  if (publishUnread) {
    await publishRealtimeEvent({
      type: 'room.unread',
      roomId,
      payload: { roomId },
      userIds: memberships.map((membership) => String(membership.userId))
    });
  }

  if (enqueueWebhook) {
    await enqueueWebhookDispatch({
      event: 'message.created',
      roomId,
      payload: { message: responseMessage }
    });
  }

  if (enqueuePush) {
    await enqueuePushMessageJob({ roomId, messageId });
  }

  return responseMessage;
}

export async function handleMessageRemoved(message: { _id: unknown; roomId: unknown; clientMessageId?: string }) {
  await publishRealtimeEvent({
    type: 'message.removed',
    roomId: String(message.roomId),
    payload: {
      messageId: String(message._id),
      clientMessageId: message.clientMessageId ?? ''
    }
  });
}
