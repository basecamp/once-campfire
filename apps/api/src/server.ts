import { buildApp } from './app.js';
import { env } from './config/env.js';
import { startBotWebhookWorker, stopBotWebhookWorker } from './queues/bot-webhook.queue.js';
import { startModerationWorker, stopModerationWorker } from './queues/moderation.queue.js';
import { startPushMessageWorker, stopPushMessageWorker } from './queues/push-message.queue.js';
import { startWebhookWorker, stopWebhookWorker } from './queues/webhook.queue.js';
import { startRealtimeRedisBridge, stopRealtimeRedisBridge } from './realtime/redis-realtime.js';

const app = buildApp();

async function start() {
  try {
    await startRealtimeRedisBridge();
    startWebhookWorker();
    startPushMessageWorker();
    startBotWebhookWorker();
    startModerationWorker();

    await app.listen({
      host: env.HOST,
      port: env.PORT
    });

    app.log.info('Realtime Redis bridge and webhook worker started');
  } catch (error) {
    app.log.error(error);
    process.exit(1);
  }
}

async function shutdown(signal: string) {
  app.log.info(`Received ${signal}, shutting down`);

  try {
    await app.close();
    await Promise.all([
      stopWebhookWorker(),
      stopPushMessageWorker(),
      stopBotWebhookWorker(),
      stopModerationWorker(),
      stopRealtimeRedisBridge()
    ]);
  } finally {
    process.exit(0);
  }
}

process.on('SIGINT', () => {
  void shutdown('SIGINT');
});

process.on('SIGTERM', () => {
  void shutdown('SIGTERM');
});

start();
