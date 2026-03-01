import { Queue, Worker, type Job } from 'bullmq';
import { env } from '../config/env.js';
import { BoostModel } from '../models/boost.model.js';
import { MessageModel } from '../models/message.model.js';
import { removeMessageSearchIndexes } from '../services/message-search-index.js';
import { handleMessageRemoved } from '../services/message-events.js';

type ModerationJobData = {
  type: 'remove-banned-content';
  userId: string;
};

const QUEUE_NAME = `${env.REDIS_PREFIX}:moderation-events`;

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

export async function enqueueRemoveBannedContentJob(userId: string) {
  await ensureQueue().add('remove-banned-content', {
    type: 'remove-banned-content',
    userId
  });
}

async function processModerationJob(job: Job) {
  const data = job.data as ModerationJobData;

  if (data.type !== 'remove-banned-content') {
    return;
  }

  const messages = await MessageModel.find({ creatorId: data.userId }).lean();
  if (messages.length === 0) {
    return;
  }

  const messageIds = messages.map((message) => message._id);

  await Promise.all([
    MessageModel.deleteMany({ creatorId: data.userId }),
    BoostModel.deleteMany({ messageId: { $in: messageIds } }),
    removeMessageSearchIndexes(messageIds)
  ]);

  await Promise.all(messages.map((message) => handleMessageRemoved(message)));
}

export function startModerationWorker() {
  if (worker) {
    return worker;
  }

  worker = new Worker(QUEUE_NAME, processModerationJob, {
    connection: {
      url: env.REDIS_URL,
      maxRetriesPerRequest: null
    },
    concurrency: 2
  });

  return worker;
}

export async function stopModerationWorker() {
  await Promise.allSettled([
    worker?.close() ?? Promise.resolve(),
    queue?.close() ?? Promise.resolve()
  ]);

  worker = null;
  queue = null;
}
