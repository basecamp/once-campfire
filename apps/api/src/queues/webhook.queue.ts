import { Queue, Worker, type Job } from 'bullmq';
import { env } from '../config/env.js';
import { dispatchWebhookEvent, type WebhookEventType } from '../services/webhook-dispatcher.js';

type WebhookDispatchJob = {
  event: WebhookEventType;
  roomId: string;
  payload: Record<string, unknown>;
};

const QUEUE_NAME = `${env.REDIS_PREFIX}:webhook-events`;

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
      attempts: 3,
      removeOnComplete: true,
      removeOnFail: 100,
      backoff: {
        type: 'exponential',
        delay: 750
      }
    }
  });

  return queue;
}

export async function enqueueWebhookDispatch(data: WebhookDispatchJob) {
  const webhookQueue = ensureQueue();

  await webhookQueue.add('dispatch', data);
}

async function processWebhookJob(job: Job) {
  const data = job.data as WebhookDispatchJob;
  await dispatchWebhookEvent(data);
}

export function startWebhookWorker() {
  if (worker) {
    return worker;
  }

  worker = new Worker(QUEUE_NAME, processWebhookJob, {
    connection: {
      url: env.REDIS_URL,
      maxRetriesPerRequest: null
    },
    concurrency: 20
  });

  return worker;
}

export async function stopWebhookWorker() {
  await Promise.allSettled([
    worker?.close() ?? Promise.resolve(),
    queue?.close() ?? Promise.resolve()
  ]);

  worker = null;
  queue = null;
}
