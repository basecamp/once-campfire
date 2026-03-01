import { z } from 'zod';

export const createBoostSchema = z.object({
  content: z.string().trim().min(1).max(16)
});
