import { Queue, Worker, type Job } from 'bullmq';
import { env } from '../config/env.js';
import { MessageModel } from '../models/message.model.js';
import { RoomModel } from '../models/room.model.js';
import { UserModel } from '../models/user.model.js';
import { handleMessageCreated } from '../services/message-events.js';

type BotWebhookJobData = {
  botUserId: string;
  messageId: string;
};

const QUEUE_NAME = `${env.REDIS_PREFIX}:bot-webhook-events`;

let queue: Queue | null = null;
let worker: Worker | null = null;

function ensureQueue() {
  if (queue) {
    return queue;
  }

  queue = new Queue(QUEUE_NAME, {
    connection: {
      url: env.REDIS_URL,
      maxRetriesPerRequest: null
    },
    defaultJobOptions: {
      attempts: 2,
      removeOnComplete: true,
      removeOnFail: 100
    }
  });

  return queue;
}

export async function enqueueBotWebhookJob(data: BotWebhookJobData) {
  await ensureQueue().add('bot-webhook', data);
}

function buildBotPayload(
  bot: { botToken?: string | null; _id: unknown; name: string },
  room: { _id: unknown; name?: string | null },
  message: {
    _id: unknown;
    body: string;
    attachment?: {
      filename?: string;
    } | null;
  },
  creator: { _id: unknown; name: string }
) {
  const plainMessageBody = withoutRecipientMentions(
    message.body?.trim() || message.attachment?.filename?.trim() || '',
    bot.name
  );

  return {
    user: { id: String(creator._id), name: creator.name },
    room: {
      id: String(room._id),
      name: room.name ?? '',
      path: `/rooms/${String(room._id)}/${String(bot._id)}-${bot.botToken ?? ''}/messages`
    },
    message: {
      id: String(message._id),
      body: {
        html: null,
        plain: plainMessageBody
      },
      path: `/rooms/${String(room._id)}/@${String(message._id)}`
    }
  };
}

function escapeRegex(value: string) {
  return value.replace(/[.*+?^${}()|[\]\\]/g, '\\$&');
}

function withoutRecipientMentions(body: string, recipientName: string) {
  const mention = `@${recipientName}`.trim();
  if (!mention || mention === '@') {
    return body.trim();
  }

  return body.replace(new RegExp(escapeRegex(mention), 'g'), '').trim();
}

async function publishBotMessage({
  roomId,
  creatorId,
  body,
  attachment
}: {
  roomId: string;
  creatorId: string;
  body: string;
  attachment?: {
    data: Buffer;
    contentType: string;
    filename: string;
    byteSize: number;
  };
}) {
  const botMessage = await MessageModel.create({
    roomId,
    creatorId,
    body,
    ...(attachment ? { attachment } : {})
  });

  await handleMessageCreated({
    roomId: String(roomId),
    messageId: String(botMessage._id),
    creatorId: String(creatorId),
    enqueuePush: true,
    enqueueWebhook: true,
    publishUnread: true
  });
}

function extensionForMimeType(contentType: string) {
  const normalized = contentType.toLowerCase().split(';')[0]?.trim() ?? '';

  if (normalized === 'image/jpeg') {
    return 'jpg';
  }
  if (normalized === 'image/png') {
    return 'png';
  }
  if (normalized === 'image/gif') {
    return 'gif';
  }
  if (normalized === 'image/webp') {
    return 'webp';
  }
  if (normalized === 'application/pdf') {
    return 'pdf';
  }
  if (normalized.startsWith('text/')) {
    return 'txt';
  }

  return 'bin';
}

async function processBotWebhook(job: Job) {
  const data = job.data as BotWebhookJobData;

  const [bot, message] = await Promise.all([
    UserModel.findById(data.botUserId).lean(),
    MessageModel.findById(data.messageId).lean()
  ]);

  if (!bot || !message || bot.role !== 'bot' || bot.status !== 'active' || !bot.botWebhookUrl) {
    return;
  }

  const [room, creator] = await Promise.all([
    RoomModel.findById(message.roomId).lean(),
    UserModel.findById(message.creatorId, { name: 1 }).lean()
  ]);

  if (!room || !creator) {
    return;
  }

  const controller = new AbortController();
  const timeout = setTimeout(() => controller.abort(), 7000);
  let didTimeout = false;

  try {
    const response = await fetch(bot.botWebhookUrl, {
      method: 'POST',
      headers: {
        'content-type': 'application/json'
      },
      body: JSON.stringify(buildBotPayload(bot, room, message, creator)),
      signal: controller.signal
    });

    const contentType = response.headers.get('content-type') ?? '';

    if (!response.ok) {
      return;
    }

    if (contentType.includes('text/plain') || contentType.includes('text/html')) {
      const text = (await response.text()).trim();
      if (text) {
        await publishBotMessage({
          roomId: String(room._id),
          creatorId: String(bot._id),
          body: text
        });
      }

      return;
    }

    const bytes = Buffer.from(await response.arrayBuffer());
    if (bytes.byteLength === 0) {
      return;
    }

    const normalizedContentType = contentType.split(';')[0]?.trim() || 'application/octet-stream';
    const extension = extensionForMimeType(normalizedContentType);

    await publishBotMessage({
      roomId: String(room._id),
      creatorId: String(bot._id),
      body: '',
      attachment: {
        data: bytes,
        contentType: normalizedContentType,
        filename: `attachment.${extension}`,
        byteSize: bytes.byteLength
      }
    });
  } catch (error) {
    if ((error as { name?: string }).name === 'AbortError') {
      didTimeout = true;
    }
  } finally {
    clearTimeout(timeout);
  }

  if (didTimeout) {
    await publishBotMessage({
      roomId: String(room._id),
      creatorId: String(bot._id),
      body: 'Failed to respond within 7 seconds'
    });
  }
}

export function startBotWebhookWorker() {
  if (worker) {
    return worker;
  }

  worker = new Worker(QUEUE_NAME, processBotWebhook, {
    connection: {
      url: env.REDIS_URL,
      maxRetriesPerRequest: null
    },
    concurrency: 8
  });

  return worker;
}

export async function stopBotWebhookWorker() {
  await Promise.allSettled([
    worker?.close() ?? Promise.resolve(),
    queue?.close() ?? Promise.resolve()
  ]);

  worker = null;
  queue = null;
}
