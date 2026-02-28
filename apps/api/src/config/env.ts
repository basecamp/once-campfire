import { config as loadEnv } from 'dotenv';
import { z } from 'zod';

loadEnv();

const envSchema = z.object({
  NODE_ENV: z.enum(['development', 'test', 'production']).default('development'),
  PORT: z.coerce.number().default(4000),
  HOST: z.string().default('0.0.0.0'),
  MONGODB_URI: z.string().default('mongodb://127.0.0.1:27017/campfire'),
  REDIS_URL: z.string().default('redis://127.0.0.1:6379'),
  REDIS_PREFIX: z.string().default('campfire'),
  APP_BASE_URL: z.string().url().default('http://localhost:4000'),
  APP_VERSION: z.string().default('dev'),
  GIT_REVISION: z.string().default('dev'),
  VAPID_PUBLIC_KEY: z.string().optional(),
  VAPID_PRIVATE_KEY: z.string().optional(),
  VAPID_SUBJECT: z.string().default('mailto:support@example.com'),
  JWT_SECRET: z.string().min(16).default('change-me-please-secret')
});

export const env = envSchema.parse(process.env);
