import Redis from 'ioredis';

// Используйте переменные окружения для конфигурации в продакшене
const redis = new Redis({
  host: process.env.REDIS_HOST,
  port: process.env.REDIS_PORT,
  password: process.env.REDIS_PASSWORD,
  maxRetriesPerRequest: 1,
  connectTimeout: 5000,
  enableReadyCheck: false,
  enableOfflineQueue: false
});

redis.on('error', (err) => {
  console.error('Redis connection error:', err);
});

export default redis;
