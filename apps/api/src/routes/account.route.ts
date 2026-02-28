import { randomBytes, randomUUID } from 'node:crypto';
import { readFile } from 'node:fs/promises';
import { resolve } from 'node:path';
import type { FastifyPluginAsync, FastifyRequest, RouteHandlerMethod } from 'fastify';
import { z } from 'zod';
import { AccountModel } from '../models/account.model.js';
import { MembershipModel } from '../models/membership.model.js';
import { PushSubscriptionModel } from '../models/push-subscription.model.js';
import { RoomModel } from '../models/room.model.js';
import { SearchModel } from '../models/search.model.js';
import { SessionModel } from '../models/session.model.js';
import { UserModel } from '../models/user.model.js';
import { WebhookModel } from '../models/webhook.model.js';
import { disconnectUser } from '../realtime/connection-manager.js';
import { buildAccountLogoPath } from '../services/avatar-media.js';
import { getAccount, getOrCreateAccount, generateJoinCode } from '../services/account-singleton.js';
import { buildPngSquareVariant } from '../services/image-variants.js';
import { ensureImageUpload, parseBooleanField, pickField, readMultipartForm } from '../services/multipart-form.js';

const updateAccountSchema = z.object({
  name: z.string().trim().min(1).max(120).optional(),
  logoUrl: z.string().url().optional(),
  customStyles: z.string().max(50000).optional(),
  settings: z
    .object({
      restrictRoomCreationToAdministrators: z.boolean().optional()
    })
    .optional()
});

const updateUserRoleSchema = z.object({
  role: z.enum(['member', 'administrator', 'admin']).default('member')
});

const createOrUpdateBotSchema = z.object({
  name: z.string().trim().min(1).max(64),
  webhookUrl: z.string().url().optional()
});

function toRailsRole(role: string) {
  if (role === 'admin') {
    return 'administrator';
  }
  return role;
}

function toNodeRole(role: string): 'member' | 'admin' {
  if (role === 'administrator') {
    return 'admin';
  }
  return role === 'admin' ? 'admin' : 'member';
}

function generateBotToken() {
  return randomBytes(9).toString('base64url').replace(/[^a-zA-Z0-9]/g, '').slice(0, 12);
}

function parseAccountPayload(input: unknown) {
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

function parseRolePayload(input: unknown) {
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

function parseBotPayload(input: unknown) {
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

function pickFile<T>(files: Record<string, T>, names: string[]) {
  for (const name of names) {
    if (files[name]) {
      return files[name];
    }
  }

  return undefined;
}

async function parseAccountUpdateRequest(request: FastifyRequest) {
  if (!request.isMultipart()) {
    return { payload: parseAccountPayload(request.body), logo: undefined };
  }

  const { fields, files } = await readMultipartForm(request, {
    fileFields: ['logo', 'account[logo]', 'account.logo']
  });

  const restrictFlag = parseBooleanField(
    pickField(fields, [
      'restrictRoomCreationToAdministrators',
      'restrict_room_creation_to_administrators',
      'settings[restrict_room_creation_to_administrators]',
      'account[settings][restrict_room_creation_to_administrators]',
      'account.settings.restrict_room_creation_to_administrators'
    ])
  );

  const payload = parseAccountPayload({
    name: pickField(fields, ['name', 'account[name]']),
    logoUrl: pickField(fields, ['logoUrl', 'logo_url', 'account[logoUrl]', 'account[logo_url]']),
    customStyles: pickField(fields, ['customStyles', 'custom_styles', 'account[customStyles]', 'account[custom_styles]']),
    settings:
      restrictFlag === undefined
        ? undefined
        : {
            restrictRoomCreationToAdministrators: restrictFlag
          }
  });

  const logo = ensureImageUpload(pickFile(files, ['logo', 'account[logo]', 'account.logo']));
  return { payload, logo };
}

async function parseBotRequest(request: FastifyRequest) {
  if (!request.isMultipart()) {
    return { payload: parseBotPayload(request.body), avatar: undefined };
  }

  const { fields, files } = await readMultipartForm(request, {
    fileFields: ['avatar', 'user[avatar]', 'user.avatar']
  });

  const payload = parseBotPayload({
    name: pickField(fields, ['name', 'user[name]']),
    webhookUrl: pickField(fields, ['webhookUrl', 'webhook_url', 'user[webhookUrl]', 'user[webhook_url]'])
  });

  const avatar = ensureImageUpload(pickFile(files, ['avatar', 'user[avatar]', 'user.avatar']));
  return { payload, avatar };
}

async function ensureAdmin(actorId: string) {
  const actor = await UserModel.findById(actorId, { role: 1 }).lean();
  return actor?.role === 'admin';
}

function serializeAccount(account: {
  _id: unknown;
  name: string;
  joinCode: string;
  logo?: {
    contentType: string;
    filename: string;
    byteSize: number;
  } | null;
  logoUrl?: string;
  customStyles?: string;
  updatedAt?: Date;
  settings?: {
    restrictRoomCreationToAdministrators?: boolean;
  } | null;
}) {
  const logoPath = buildAccountLogoPath(account, 'large');

  return {
    id: String(account._id),
    name: account.name,
    joinCode: account.joinCode,
    join_code: account.joinCode,
    logoUrl: logoPath,
    logo_url: logoPath,
    customStyles: account.customStyles ?? '',
    custom_styles: account.customStyles ?? '',
    settings: {
      restrictRoomCreationToAdministrators: account.settings?.restrictRoomCreationToAdministrators ?? false,
      restrict_room_creation_to_administrators: account.settings?.restrictRoomCreationToAdministrators ?? false
    }
  };
}

async function deactivateUser(userId: string) {
  const memberships = await MembershipModel.find({ userId }, { roomId: 1 }).lean();
  const roomIds = memberships.map((membership) => membership.roomId);

  let removableRoomIds = roomIds;
  if (roomIds.length > 0) {
    const directRooms = await RoomModel.find({ _id: { $in: roomIds }, type: 'direct' }, { _id: 1 }).lean();
    const directIds = new Set(directRooms.map((room) => String(room._id)));
    removableRoomIds = roomIds.filter((roomId) => !directIds.has(String(roomId)));
  }

  const current = await UserModel.findById(userId, { emailAddress: 1 }).lean();
  const currentEmail = current?.emailAddress ?? `user-${userId}@example.local`;
  const deactivatedEmail = currentEmail.includes('@')
    ? currentEmail.replace('@', `-deactivated-${randomUUID()}@`)
    : `${currentEmail}-deactivated-${randomUUID()}@example.local`;

  await Promise.all([
    removableRoomIds.length > 0 ? MembershipModel.deleteMany({ userId, roomId: { $in: removableRoomIds } }) : Promise.resolve(),
    PushSubscriptionModel.deleteMany({ userId }),
    SearchModel.deleteMany({ userId }),
    SessionModel.deleteMany({ userId }),
    WebhookModel.deleteMany({ userId }),
    UserModel.updateOne({ _id: userId }, { $set: { status: 'deactivated', emailAddress: deactivatedEmail } })
  ]);

  disconnectUser(userId, {
    reason: 'deactivated',
    reconnect: false
  });
}

const accountRoutes: FastifyPluginAsync = async (app) => {
  const requireAdmin: RouteHandlerMethod = async (request, reply) => {
    const actorId = request.authUserId;
    if (!actorId) {
      return reply.code(401).send({ error: 'Unauthorized' });
    }

    if (!(await ensureAdmin(actorId))) {
      return reply.code(403).send({ error: 'Forbidden' });
    }
  };

  app.get('/account', { preHandler: app.authenticate }, async (request, reply) => {
    const userId = request.authUserId;
    if (!userId) {
      return reply.code(401).send({ error: 'Unauthorized' });
    }

    const account = await getOrCreateAccount();
    return { account: serializeAccount(account.toObject()) };
  });

  app.get('/account/edit', { preHandler: app.authenticate }, async (request, reply) => {
    const userId = request.authUserId;
    if (!userId) {
      return reply.code(401).send({ error: 'Unauthorized' });
    }

    const account = await getOrCreateAccount();
    return { account: serializeAccount(account.toObject()) };
  });

  app.patch('/account', { preHandler: [app.authenticate, requireAdmin] }, async (request) => {
    const account = await getOrCreateAccount();
    const { payload, logo } = await parseAccountUpdateRequest(request);

    if (payload.name !== undefined) {
      account.name = payload.name;
    }

    if (logo) {
      account.logo = logo;
      account.logoUrl = '';
    } else if (payload.logoUrl !== undefined) {
      account.logo = undefined;
      account.logoUrl = payload.logoUrl;
    }

    if (payload.customStyles !== undefined) {
      account.customStyles = payload.customStyles;
    }

    if (payload.settings) {
      account.settings = {
        restrictRoomCreationToAdministrators:
          payload.settings.restrictRoomCreationToAdministrators ??
          account.settings?.restrictRoomCreationToAdministrators ??
          false
      };
    }

    await account.save();

    return { account: serializeAccount(account.toObject()) };
  });

  app.get('/account/users', { preHandler: [app.authenticate, requireAdmin] }, async () => {
    const users = await UserModel.find({ status: 'active', role: { $ne: 'bot' } }, { name: 1, emailAddress: 1, role: 1, status: 1 })
      .sort({ name: 1 })
      .limit(500)
      .lean();

    return {
      users: users.map((user) => ({
        id: String(user._id),
        name: user.name,
        emailAddress: user.emailAddress,
        email_address: user.emailAddress,
        role: toRailsRole(user.role),
        status: user.status
      }))
    };
  });

  app.patch('/account/users/:id', { preHandler: [app.authenticate, requireAdmin] }, async (request, reply) => {
    const { id } = request.params as { id: string };

    const user = await UserModel.findOne({ _id: id, status: 'active' });
    if (!user) {
      return reply.code(404).send({ error: 'User not found' });
    }

    const payload = parseRolePayload(request.body);
    user.role = toNodeRole(payload.role);
    await user.save();

    return {
      user: {
        id: String(user._id),
        name: user.name,
        role: toRailsRole(user.role),
        status: user.status
      }
    };
  });

  app.delete('/account/users/:id', { preHandler: [app.authenticate, requireAdmin] }, async (request, reply) => {
    const { id } = request.params as { id: string };

    const user = await UserModel.findOne({ _id: id, status: 'active', role: { $ne: 'bot' } }).lean();
    if (!user) {
      return reply.code(404).send({ error: 'User not found' });
    }

    await deactivateUser(id);

    return reply.code(204).send();
  });

  app.get('/account/bots', { preHandler: [app.authenticate, requireAdmin] }, async () => {
    const bots = await UserModel.find({ role: 'bot', status: 'active' }, { name: 1, botToken: 1, botWebhookUrl: 1 })
      .sort({ name: 1 })
      .lean();

    return {
      bots: bots.map((bot) => ({
        id: String(bot._id),
        name: bot.name,
        botKey: `${String(bot._id)}-${bot.botToken ?? ''}`,
        bot_key: `${String(bot._id)}-${bot.botToken ?? ''}`,
        webhookUrl: bot.botWebhookUrl ?? '',
        webhook_url: bot.botWebhookUrl ?? ''
      }))
    };
  });

  app.post('/account/bots', { preHandler: [app.authenticate, requireAdmin] }, async (request, reply) => {
    const { payload, avatar } = await parseBotRequest(request);
    const token = generateBotToken();

    const bot = await UserModel.create({
      name: payload.name,
      emailAddress: `bot-${Date.now()}-${token.toLowerCase()}@bots.local`,
      passwordHash: randomUUID(),
      role: 'bot',
      status: 'active',
      botToken: token,
      botWebhookUrl: payload.webhookUrl ?? '',
      avatar: avatar ?? undefined
    });

    return reply.code(201).send({
      bot: {
        id: String(bot._id),
        name: bot.name,
        botKey: `${String(bot._id)}-${bot.botToken ?? ''}`,
        bot_key: `${String(bot._id)}-${bot.botToken ?? ''}`,
        webhookUrl: bot.botWebhookUrl ?? '',
        webhook_url: bot.botWebhookUrl ?? ''
      }
    });
  });

  app.get('/account/bots/:id', { preHandler: [app.authenticate, requireAdmin] }, async (request, reply) => {
    const { id } = request.params as { id: string };
    const bot = await UserModel.findOne({ _id: id, role: 'bot', status: 'active' }, { name: 1, botToken: 1, botWebhookUrl: 1 }).lean();

    if (!bot) {
      return reply.code(404).send({ error: 'Bot not found' });
    }

    return {
      bot: {
        id: String(bot._id),
        name: bot.name,
        botKey: `${String(bot._id)}-${bot.botToken ?? ''}`,
        bot_key: `${String(bot._id)}-${bot.botToken ?? ''}`,
        webhookUrl: bot.botWebhookUrl ?? '',
        webhook_url: bot.botWebhookUrl ?? ''
      }
    };
  });

  app.get('/account/bots/:id/edit', { preHandler: [app.authenticate, requireAdmin] }, async (request, reply) => {
    const { id } = request.params as { id: string };
    const bot = await UserModel.findOne({ _id: id, role: 'bot', status: 'active' }, { name: 1, botToken: 1, botWebhookUrl: 1 }).lean();

    if (!bot) {
      return reply.code(404).send({ error: 'Bot not found' });
    }

    return {
      bot: {
        id: String(bot._id),
        name: bot.name,
        botKey: `${String(bot._id)}-${bot.botToken ?? ''}`,
        bot_key: `${String(bot._id)}-${bot.botToken ?? ''}`,
        webhookUrl: bot.botWebhookUrl ?? '',
        webhook_url: bot.botWebhookUrl ?? ''
      }
    };
  });

  app.patch('/account/bots/:id', { preHandler: [app.authenticate, requireAdmin] }, async (request, reply) => {
    const { id } = request.params as { id: string };
    const bot = await UserModel.findOne({ _id: id, role: 'bot', status: 'active' });

    if (!bot) {
      return reply.code(404).send({ error: 'Bot not found' });
    }

    const { payload, avatar } = await parseBotRequest(request);

    bot.name = payload.name;
    bot.botWebhookUrl = payload.webhookUrl ?? '';
    if (avatar) {
      bot.avatar = avatar;
      bot.avatarUrl = '';
    }
    await bot.save();

    return {
      bot: {
        id: String(bot._id),
        name: bot.name,
        botKey: `${String(bot._id)}-${bot.botToken ?? ''}`,
        bot_key: `${String(bot._id)}-${bot.botToken ?? ''}`,
        webhookUrl: bot.botWebhookUrl ?? '',
        webhook_url: bot.botWebhookUrl ?? ''
      }
    };
  });

  app.delete('/account/bots/:id', { preHandler: [app.authenticate, requireAdmin] }, async (request, reply) => {
    const { id } = request.params as { id: string };
    const bot = await UserModel.findOne({ _id: id, role: 'bot', status: 'active' }).lean();

    if (!bot) {
      return reply.code(404).send({ error: 'Bot not found' });
    }

    await deactivateUser(id);

    return reply.code(204).send();
  });

  app.patch('/account/bots/:botId/key', { preHandler: [app.authenticate, requireAdmin] }, async (request, reply) => {
    const { botId } = request.params as { botId: string };
    const bot = await UserModel.findOne({ _id: botId, role: 'bot', status: 'active' });

    if (!bot) {
      return reply.code(404).send({ error: 'Bot not found' });
    }

    bot.botToken = generateBotToken();
    await bot.save();

    return {
      bot: {
        id: String(bot._id),
        botKey: `${String(bot._id)}-${bot.botToken ?? ''}`,
        bot_key: `${String(bot._id)}-${bot.botToken ?? ''}`
      }
    };
  });

  app.post('/account/join_code', { preHandler: [app.authenticate, requireAdmin] }, async () => {
    const account = await getOrCreateAccount();
    account.joinCode = generateJoinCode();
    await account.save();

    return { account: serializeAccount(account.toObject()) };
  });

  app.get('/account/logo', async (request, reply) => {
    const account = await getAccount();
    const size = (request.query as { size?: string } | undefined)?.size;
    reply.header('cache-control', 'public, max-age=300, stale-while-revalidate=604800');

    if (account?.logo?.data) {
      const variantPixels = size === 'small' ? 192 : 512;
      try {
        const variant = await buildPngSquareVariant(account.logo.data, variantPixels);
        const safeName = account.logo.filename.replace(/"/g, '').replace(/\.[^.]+$/, '') || 'logo';
        reply.header('content-type', 'image/png');
        reply.header('content-disposition', `inline; filename="${safeName}.png"`);
        return reply.send(variant);
      } catch {
        reply.header('content-type', account.logo.contentType || 'application/octet-stream');
        reply.header('content-disposition', `inline; filename="${account.logo.filename.replace(/"/g, '')}"`);
        return reply.send(account.logo.data);
      }
    }

    if (account?.logoUrl) {
      return reply.redirect(account.logoUrl);
    }

    const filename = size === 'small' ? 'app-icon-192.png' : 'app-icon.png';
    const stockLogoPath = resolve(process.cwd(), '../../app/assets/images/logos', filename);

    try {
      const content = await readFile(stockLogoPath);
      reply.header('content-type', 'image/png');
      return reply.send(content);
    } catch {
      return reply.code(404).send({ error: 'Logo not found' });
    }
  });

  app.delete('/account/logo', { preHandler: [app.authenticate, requireAdmin] }, async (request, reply) => {
    const account = await getOrCreateAccount();
    account.logo = undefined;
    account.logoUrl = '';
    await account.save();

    return reply.code(204).send();
  });

  app.get('/account/custom_styles', { preHandler: [app.authenticate, requireAdmin] }, async () => {
    const account = await getOrCreateAccount();
    return {
      customStyles: account.customStyles ?? '',
      custom_styles: account.customStyles ?? ''
    };
  });

  app.get('/account/custom_styles/edit', { preHandler: [app.authenticate, requireAdmin] }, async () => {
    const account = await getOrCreateAccount();
    return {
      customStyles: account.customStyles ?? '',
      custom_styles: account.customStyles ?? ''
    };
  });

  app.patch('/account/custom_styles', { preHandler: [app.authenticate, requireAdmin] }, async (request) => {
    const account = await getOrCreateAccount();
    const payload = parseAccountPayload(request.body);

    account.customStyles = payload.customStyles ?? '';
    await account.save();

    return {
      customStyles: account.customStyles,
      custom_styles: account.customStyles
    };
  });
};

export default accountRoutes;
