import { z } from 'zod';

export const createSessionSchema = z.object({
  emailAddress: z.string().email(),
  password: z.string().min(8).max(128),
  pushSubscriptionEndpoint: z.string().url().optional()
});

export function parseSessionPayload(input: unknown) {
  if (!input || typeof input !== 'object') {
    return createSessionSchema.parse(input);
  }

  const payload = input as {
    emailAddress?: unknown;
    email_address?: unknown;
    password?: unknown;
    pushSubscriptionEndpoint?: unknown;
    push_subscription_endpoint?: unknown;
  };

  return createSessionSchema.parse({
    emailAddress:
      (typeof payload.emailAddress === 'string' ? payload.emailAddress : undefined) ??
      (typeof payload.email_address === 'string' ? payload.email_address : undefined),
    password: typeof payload.password === 'string' ? payload.password : undefined,
    pushSubscriptionEndpoint:
      (typeof payload.pushSubscriptionEndpoint === 'string' ? payload.pushSubscriptionEndpoint : undefined) ??
      (typeof payload.push_subscription_endpoint === 'string' ? payload.push_subscription_endpoint : undefined)
  });
}
