import { Redis } from 'ioredis';
import { env } from '../config/env.js';
import { createRedisClient } from '../redis/clients.js';
import { realtimeBus, type RealtimeEvent } from './event-bus.js';

const CHANNEL = `${env.REDIS_PREFIX}:realtime`;

let publisher: Redis | null = null;
let subscriber: Redis | null = null;
let subscribed = false;

export async function startRealtimeRedisBridge() {
  if (publisher && subscriber && subscribed) {
    return;
  }

  publisher = createRedisClient('campfire-realtime-pub');
  subscriber = createRedisClient('campfire-realtime-sub');

  subscriber.on('message', (_channel: string, payload: string) => {
    try {
      const event = JSON.parse(payload) as RealtimeEvent;
      realtimeBus.publishLocal(event);
    } catch {
      // Ignore malformed payloads from external publishers.
    }
  });

  await subscriber.subscribe(CHANNEL);
  subscribed = true;
}

export async function publishRealtimeEvent(event: RealtimeEvent) {
  const payload = JSON.stringify(event);

  if (!publisher) {
    realtimeBus.publishLocal(event);
    return;
  }

  await publisher.publish(CHANNEL, payload);
}

export async function stopRealtimeRedisBridge() {
  const tasks: Promise<unknown>[] = [];

  if (subscriber) {
    if (subscribed) {
      tasks.push(subscriber.unsubscribe(CHANNEL));
    }
    tasks.push(subscriber.quit());
  }

  if (publisher) {
    tasks.push(publisher.quit());
  }

  subscribed = false;
  subscriber = null;
  publisher = null;

  await Promise.allSettled(tasks);
}
