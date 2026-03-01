import { z } from 'zod';

export const updateAccountSchema = z.object({
  name: z.string().trim().min(1).max(120).optional(),
  logoUrl: z.string().url().optional(),
  customStyles: z.string().max(50000).optional(),
  settings: z
    .object({
      restrictRoomCreationToAdministrators: z.boolean().optional()
    })
    .optional()
});

export const updateUserRoleSchema = z.object({
  role: z.enum(['member', 'administrator', 'admin']).default('member')
});

export const createOrUpdateBotSchema = z.object({
  name: z.string().trim().min(1).max(64),
  webhookUrl: z.string().url().optional()
});

export function parseAccountPayload(input: unknown) {
  if (!input || typeof input !== 'object') {
    return updateAccountSchema.parse(input);
  }

  const payload = input as {
    name?: unknown;
    logoUrl?: unknown;
    logo_url?: unknown;
    customStyles?: unknown;
    custom_styles?: unknown;
    settings?: unknown;
    account?: {
      name?: unknown;
      logoUrl?: unknown;
      logo_url?: unknown;
      customStyles?: unknown;
      custom_styles?: unknown;
      settings?: unknown;
    };
  };

  const account = payload.account;

  return updateAccountSchema.parse({
    name: (typeof account?.name === 'string' ? account.name : undefined) ?? (typeof payload.name === 'string' ? payload.name : undefined),
    logoUrl:
      (typeof account?.logoUrl === 'string' ? account.logoUrl : undefined) ??
      (typeof account?.logo_url === 'string' ? account.logo_url : undefined) ??
      (typeof payload.logoUrl === 'string' ? payload.logoUrl : undefined) ??
      (typeof payload.logo_url === 'string' ? payload.logo_url : undefined),
    customStyles:
      (typeof account?.customStyles === 'string' ? account.customStyles : undefined) ??
      (typeof account?.custom_styles === 'string' ? account.custom_styles : undefined) ??
      (typeof payload.customStyles === 'string' ? payload.customStyles : undefined) ??
      (typeof payload.custom_styles === 'string' ? payload.custom_styles : undefined),
    settings:
      (typeof account?.settings === 'object' && account.settings !== null
        ? (account.settings as Record<string, unknown>)
        : typeof payload.settings === 'object' && payload.settings !== null
          ? (payload.settings as Record<string, unknown>)
          : undefined)
  });
}

export function parseRolePayload(input: unknown) {
  if (!input || typeof input !== 'object') {
    return updateUserRoleSchema.parse(input);
  }

  const payload = input as {
    role?: unknown;
    user?: {
      role?: unknown;
    };
  };

  return updateUserRoleSchema.parse({
    role:
      (typeof payload.user?.role === 'string' ? payload.user.role : undefined) ??
      (typeof payload.role === 'string' ? payload.role : undefined)
  });
}

export function parseBotPayload(input: unknown) {
  if (!input || typeof input !== 'object') {
    return createOrUpdateBotSchema.parse(input);
  }

  const payload = input as {
    name?: unknown;
    webhookUrl?: unknown;
    webhook_url?: unknown;
    user?: {
      name?: unknown;
      webhookUrl?: unknown;
      webhook_url?: unknown;
    };
  };

  return createOrUpdateBotSchema.parse({
    name:
      (typeof payload.user?.name === 'string' ? payload.user.name : undefined) ??
      (typeof payload.name === 'string' ? payload.name : undefined),
    webhookUrl:
      (typeof payload.user?.webhookUrl === 'string' ? payload.user.webhookUrl : undefined) ??
      (typeof payload.user?.webhook_url === 'string' ? payload.user.webhook_url : undefined) ??
      (typeof payload.webhookUrl === 'string' ? payload.webhookUrl : undefined) ??
      (typeof payload.webhook_url === 'string' ? payload.webhook_url : undefined)
  });
}

export function toRailsRole(role: string) {
  if (role === 'admin') {
    return 'administrator';
  }
  return role;
}

export function toNodeRole(role: string): 'member' | 'admin' {
  if (role === 'administrator') {
    return 'admin';
  }
  return role === 'admin' ? 'admin' : 'member';
}
