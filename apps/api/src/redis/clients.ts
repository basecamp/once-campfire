import { Redis } from 'ioredis';
import { env } from '../config/env.js';

export function createRedisClient(connectionName: string) {
  return new Redis(env.REDIS_URL, {
    maxRetriesPerRequest: null,
    enableReadyCheck: true,
    connectionName
  });
}
