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
  bot: { botToken?: string | null; _id: unknown },
  room: { _id: unknown; name?: string | null },
  message: { _id: unknown; body: string },
  creator: { _id: unknown; name: string }
) {
  return {
    user: { id: String(creator._id), name: creator.name },
    room: {
      id: String(room._id),
      name: room.name ?? '',
      path: `/api/v1/rooms/${String(room._id)}/${String(bot._id)}-${bot.botToken ?? ''}/messages`
    },
    message: {
      id: String(message._id),
      body: {
        html: null,
        plain: message.body
      },
      path: `/rooms/${String(room._id)}@${String(message._id)}`
    }
  };
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

    if (response.ok && (contentType.includes('text/plain') || contentType.includes('text/html'))) {
      const text = (await response.text()).trim();
      if (text) {
        const botMessage = await MessageModel.create({
          roomId: room._id,
          creatorId: bot._id,
          body: text
        });

        await handleMessageCreated({
          roomId: String(room._id),
          messageId: String(botMessage._id),
          creatorId: String(bot._id),
          enqueuePush: true,
          enqueueWebhook: true,
          publishUnread: true
        });
      }
    }
  } catch {
    // Ignore bot webhook failures; retries are handled by queue attempts.
  } finally {
    clearTimeout(timeout);
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
