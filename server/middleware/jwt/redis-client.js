// redis-client.js
import Redis from 'ioredis';

// Используйте переменные окружения для конфигурации в продакшене
const redis = new Redis({
  host: process.env.REDIS_HOST,
  port: process.env.REDIS_PORT,
  password: process.env.REDIS_PASSWORD,
  maxRetriesPerRequest: null,
  connectTimeout: 180000,
  enableReadyCheck: false
});

redis.on('error', (err) => {
  console.error('Redis connection error:', err);
});

export default redis;
