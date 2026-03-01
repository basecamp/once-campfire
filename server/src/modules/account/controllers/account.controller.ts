import crypto from 'node:crypto';
import type { FastifyReply, FastifyRequest } from 'fastify';
import { Types } from 'mongoose';
import { MembershipModel } from '../../rooms/models/membership.model.js';
import { PushSubscriptionModel } from '../../push/models/push-subscription.model.js';
import { SearchModel } from '../../searches/models/search.model.js';
import { SessionModel } from '../../realtime/models/session.model.js';
import { WebhookModel } from '../../bots/models/webhook.model.js';
import { AccountModel } from '../models/account.model.js';
import UserModel from '../../users/models/user.model.js';
import { asObjectId, getAuthUserId, sendData, sendError } from '../../../shared/utils/controller.js';

type StoredRole = 'member' | 'administrator' | 'bot';
type UserStatus = 'active' | 'banned' | 'deactivated';

interface UserLean {
  _id: Types.ObjectId;
  email: string;
  roles?: StoredRole[];
  status?: UserStatus;
  botToken?: string | null;
  botWebhookUrl?: string | null;
  avatarSource?: string | null;
  name?: {
    first?: string;
    last?: string;
  };
  createdAt?: Date;
  updatedAt?: Date;
}

interface AccountLean {
  _id: Types.ObjectId;
  name: string;
  joinCode: string;
  logoUrl?: string | null;
  customStyles?: string | null;
  settings?: {
    restrictRoomCreationToAdministrators?: boolean;
  };
  createdAt?: Date;
  updatedAt?: Date;
}

function normalizeString(value: unknown): string | null {
  if (typeof value !== 'string') {
    return null;
  }
  const trimmed = value.trim();
  return trimmed.length > 0 ? trimmed : null;
}

function splitName(value: string): { first: string; last: string } {
  const normalized = value.trim().replace(/\s+/g, ' ');
  const [first = 'User', ...rest] = normalized.split(' ');
  return {
    first,
    last: rest.join(' ')
  };
}

function displayName(user: UserLean): string {
  const first = normalizeString(user.name?.first) ?? '';
  const last = normalizeString(user.name?.last) ?? '';
  const combined = `${first} ${last}`.trim();
  if (combined.length > 0) {
    return combined;
  }
  return user.email.split('@')[0] ?? 'User';
}

function primaryRole(user: UserLean): StoredRole {
  if (Array.isArray(user.roles) && user.roles.length > 0) {
    return user.roles[0];
  }
  return 'member';
}

function normalizeSessionCompanyId(request: FastifyRequest): Types.ObjectId | null {
  const company = request.session?.company;
  if (typeof company === 'string') {
    return asObjectId(company);
  }
  if (company && typeof company === 'object') {
    const withIds = company as { _id?: unknown; id?: unknown };
    const fromId = normalizeString(withIds._id);
    if (fromId) {
      return asObjectId(fromId);
    }
    const fromAlias = normalizeString(withIds.id);
    if (fromAlias) {
      return asObjectId(fromAlias);
    }
  }
  return null;
}

function roleFromSession(request: FastifyRequest): string | null {
  const sessionRole = normalizeString(request.session?.role);
  if (sessionRole) {
    return sessionRole;
  }

  const sessionUser = request.session?.user;
  if (!sessionUser || typeof sessionUser !== 'object') {
    return null;
  }

  const rawRole = (sessionUser as { role?: unknown }).role;
  return normalizeString(rawRole);
}

function toRailsRole(role: StoredRole): 'member' | 'administrator' | 'bot' {
  return role;
}

function toStoredRole(input: unknown): StoredRole {
  const value = normalizeString(input)?.toLowerCase() ?? 'member';
  if (value === 'administrator' || value === 'admin') {
    return 'administrator';
  }
  if (value === 'bot') {
    return 'bot';
  }
  return 'member';
}

function generateJoinCode() {
  return crypto.randomBytes(6).toString('base64url').replace(/[^a-zA-Z0-9]/g, '').slice(0, 8).toUpperCase();
}

function generateBotToken() {
  return crypto.randomBytes(9).toString('base64url').replace(/[^a-zA-Z0-9]/g, '').slice(0, 12);
}

function parseBotPayload(body: unknown): { name: string | null; webhookUrl: string | null } {
  if (!body || typeof body !== 'object') {
    return { name: null, webhookUrl: null };
  }

  const raw = body as Record<string, unknown>;
  const nested = raw.user && typeof raw.user === 'object' ? (raw.user as Record<string, unknown>) : null;

  const name = normalizeString(nested?.name ?? raw.name);
  const webhookUrl = normalizeString(
    nested?.webhookUrl ?? nested?.webhook_url ?? raw.webhookUrl ?? raw.webhook_url
  );

  return { name, webhookUrl };
}

function parseAccountPayload(body: unknown): { name: string | null; customStyles: string | null; logoUrl: string | null } {
  if (!body || typeof body !== 'object') {
    return { name: null, customStyles: null, logoUrl: null };
  }
  const raw = body as Record<string, unknown>;
  const nested = raw.account && typeof raw.account === 'object' ? (raw.account as Record<string, unknown>) : null;

  const name = normalizeString(nested?.name ?? raw.name);
  const customStyles = normalizeString(nested?.customStyles ?? nested?.custom_styles ?? raw.customStyles ?? raw.custom_styles);
  const logoUrl = normalizeString(nested?.logoUrl ?? nested?.logo_url ?? raw.logoUrl ?? raw.logo_url);

  return { name, customStyles, logoUrl };
}

async function getOrCreateAccount(request: FastifyRequest): Promise<AccountLean> {
  const accountId = normalizeSessionCompanyId(request);

  if (accountId) {
    const byId = await AccountModel.findById(accountId).lean<AccountLean>();
    if (byId) {
      return byId;
    }
  }

  const existing = await AccountModel.findOne({}).sort({ createdAt: 1 }).lean<AccountLean>();
  if (existing) {
    return existing;
  }

  const account = await AccountModel.create({
    name: 'Campfire',
    joinCode: generateJoinCode(),
    customStyles: '',
    logoUrl: null,
    settings: {
      restrictRoomCreationToAdministrators: false
    }
  });
  return account.toObject() as AccountLean;
}

async function ensureAdminOrReject(request: FastifyRequest, reply: FastifyReply): Promise<boolean> {
  const sessionRole = roleFromSession(request)?.toLowerCase();
  if (sessionRole === 'admin' || sessionRole === 'administrator') {
    return true;
  }

  const userId = getAuthUserId(request);
  const userObjectId = asObjectId(userId);
  if (!userObjectId) {
    sendError(reply, 403, 'FORBIDDEN', 'Not enough permissions');
    return false;
  }

  const user = await UserModel.findById(userObjectId, { roles: 1 }).lean() as UserLean | null;
  if (!user || !user.roles?.includes('administrator')) {
    sendError(reply, 403, 'FORBIDDEN', 'Not enough permissions');
    return false;
  }

  return true;
}

function serializeAccount(account: AccountLean) {
  return {
    id: String(account._id),
    name: account.name,
    joinCode: account.joinCode,
    join_code: account.joinCode,
    logoUrl: account.logoUrl ?? null,
    logo_url: account.logoUrl ?? null,
    customStyles: account.customStyles ?? '',
    custom_styles: account.customStyles ?? '',
    settings: {
      restrictRoomCreationToAdministrators: Boolean(account.settings?.restrictRoomCreationToAdministrators),
      restrict_room_creation_to_administrators: Boolean(account.settings?.restrictRoomCreationToAdministrators)
    }
  };
}

async function deactivateUser(userId: Types.ObjectId) {
  const existing = await UserModel.findById(userId, { email: 1 }).lean() as UserLean | null;
  const baseEmail = existing?.email ?? `user-${userId.toHexString()}@example.local`;
  const deactivatedEmail = baseEmail.includes('@')
    ? baseEmail.replace('@', `-deactivated-${crypto.randomUUID()}@`)
    : `${baseEmail}-deactivated-${crypto.randomUUID()}@example.local`;

  await Promise.all([
    UserModel.updateOne(
      { _id: userId },
      { $set: { status: 'deactivated', email: deactivatedEmail, updatedAt: new Date() } }
    ),
    MembershipModel.deleteMany({ userId }),
    PushSubscriptionModel.deleteMany({ userId }),
    SearchModel.deleteMany({ userId }),
    SessionModel.deleteMany({ userId }),
    WebhookModel.deleteMany({ userId })
  ]);
}

export const accountController = {
  async show(request: FastifyRequest, reply: FastifyReply) {
    try {
      const account = await getOrCreateAccount(request);
      return sendData(request, reply, { account: serializeAccount(account) });
    } catch {
      return sendError(reply, 500, 'INTERNAL_ERROR', 'Cannot load account');
    }
  },

  async update(request: FastifyRequest, reply: FastifyReply) {
    try {
      if (!(await ensureAdminOrReject(request, reply))) {
        return reply;
      }

      const account = await getOrCreateAccount(request);
      const payload = parseAccountPayload(request.body);
      const patch: Partial<AccountLean> = { updatedAt: new Date() };

      if (payload.name) {
        patch.name = payload.name;
      }
      if (payload.customStyles !== null) {
        patch.customStyles = payload.customStyles;
      }
      if (payload.logoUrl !== null) {
        patch.logoUrl = payload.logoUrl;
      }

      const raw = request.body && typeof request.body === 'object' ? (request.body as Record<string, unknown>) : null;
      const accountBody = raw?.account && typeof raw.account === 'object' ? (raw.account as Record<string, unknown>) : null;
      const settings = accountBody?.settings ?? raw?.settings;
      if (settings && typeof settings === 'object') {
        const value =
          (settings as Record<string, unknown>).restrictRoomCreationToAdministrators ??
          (settings as Record<string, unknown>).restrict_room_creation_to_administrators;
        if (typeof value === 'boolean') {
          patch.settings = { restrictRoomCreationToAdministrators: value };
        }
      }

      await AccountModel.updateOne({ _id: account._id }, { $set: patch });
      const updated = await AccountModel.findById(account._id).lean<AccountLean>();
      if (!updated) {
        return sendError(reply, 500, 'INTERNAL_ERROR', 'Cannot update account');
      }

      return sendData(request, reply, { account: serializeAccount(updated) });
    } catch {
      return sendError(reply, 500, 'INTERNAL_ERROR', 'Cannot update account');
    }
  },

  async usersIndex(request: FastifyRequest, reply: FastifyReply) {
    try {
      if (!(await ensureAdminOrReject(request, reply))) {
        return reply;
      }

      const users = await UserModel.find(
        { status: 'active', roles: { $nin: ['bot'] } },
        { name: 1, email: 1, roles: 1, status: 1 }
      ).sort({ 'name.first': 1, 'name.last': 1 }).limit(500).lean() as UserLean[];

      return sendData(
        request,
        reply,
        users.map((user: UserLean) => ({
          id: String(user._id),
          name: displayName(user),
          emailAddress: user.email,
          email_address: user.email,
          role: toRailsRole(primaryRole(user)),
          status: user.status ?? 'active'
        }))
      );
    } catch {
      return sendError(reply, 500, 'INTERNAL_ERROR', 'Cannot load users');
    }
  },

  async usersUpdate(request: FastifyRequest, reply: FastifyReply) {
    try {
      if (!(await ensureAdminOrReject(request, reply))) {
        return reply;
      }

      const id = normalizeString((request.params as { id?: string; userId?: string }).id) ??
        normalizeString((request.params as { userId?: string }).userId);
      const userId = asObjectId(id);
      if (!userId) {
        return sendError(reply, 422, 'VALIDATION_ERROR', 'Invalid user id');
      }

      const raw = request.body && typeof request.body === 'object' ? (request.body as Record<string, unknown>) : {};
      const nested = raw.user && typeof raw.user === 'object' ? (raw.user as Record<string, unknown>) : {};
      const role = toStoredRole(nested.role ?? raw.role);
      if (role === 'bot') {
        return sendError(reply, 422, 'VALIDATION_ERROR', 'Invalid role');
      }

      const result = await UserModel.findOneAndUpdate(
        { _id: userId, status: 'active' },
        { $set: { roles: [role], updatedAt: new Date() } },
        { new: true }
      ).lean() as UserLean | null;
      if (!result) {
        return sendError(reply, 404, 'NOT_FOUND', 'User not found');
      }

      return sendData(request, reply, {
        id: String(result._id),
        name: displayName(result),
        role: toRailsRole(primaryRole(result)),
        status: result.status ?? 'active'
      });
    } catch {
      return sendError(reply, 500, 'INTERNAL_ERROR', 'Cannot update user');
    }
  },

  async usersDestroy(request: FastifyRequest, reply: FastifyReply) {
    try {
      if (!(await ensureAdminOrReject(request, reply))) {
        return reply;
      }

      const id = normalizeString((request.params as { id?: string; userId?: string }).id) ??
        normalizeString((request.params as { userId?: string }).userId);
      const userId = asObjectId(id);
      if (!userId) {
        return sendError(reply, 422, 'VALIDATION_ERROR', 'Invalid user id');
      }

      const user = await UserModel.findOne(
        { _id: userId, status: 'active', roles: { $nin: ['bot'] } },
        { _id: 1 }
      ).lean() as UserLean | null;
      if (!user) {
        return sendError(reply, 404, 'NOT_FOUND', 'User not found');
      }

      await deactivateUser(userId);
      return sendData(request, reply, { removed: true });
    } catch {
      return sendError(reply, 500, 'INTERNAL_ERROR', 'Cannot deactivate user');
    }
  },

  async botsIndex(request: FastifyRequest, reply: FastifyReply) {
    try {
      if (!(await ensureAdminOrReject(request, reply))) {
        return reply;
      }

      const bots = await UserModel.find(
        { status: 'active', roles: 'bot' },
        { name: 1, botToken: 1, botWebhookUrl: 1, email: 1 }
      ).sort({ 'name.first': 1, 'name.last': 1 }).lean() as UserLean[];

      return sendData(
        request,
        reply,
        bots.map((bot: UserLean) => ({
          id: String(bot._id),
          name: displayName(bot),
          webhookUrl: bot.botWebhookUrl ?? '',
          webhook_url: bot.botWebhookUrl ?? '',
          botKey: `${String(bot._id)}-${bot.botToken ?? ''}`,
          bot_key: `${String(bot._id)}-${bot.botToken ?? ''}`
        }))
      );
    } catch {
      return sendError(reply, 500, 'INTERNAL_ERROR', 'Cannot load bots');
    }
  },

  async botsEdit(request: FastifyRequest, reply: FastifyReply) {
    try {
      if (!(await ensureAdminOrReject(request, reply))) {
        return reply;
      }

      const id = normalizeString((request.params as { id?: string }).id);
      const botId = asObjectId(id);
      if (!botId) {
        return sendError(reply, 422, 'VALIDATION_ERROR', 'Invalid bot id');
      }

      const bot = await UserModel.findOne(
        { _id: botId, roles: 'bot', status: 'active' },
        { name: 1, botToken: 1, botWebhookUrl: 1, email: 1 }
      ).lean() as UserLean | null;
      if (!bot) {
        return sendError(reply, 404, 'NOT_FOUND', 'Bot not found');
      }

      return sendData(request, reply, {
        id: String(bot._id),
        name: displayName(bot),
        webhookUrl: bot.botWebhookUrl ?? '',
        webhook_url: bot.botWebhookUrl ?? '',
        botKey: `${String(bot._id)}-${bot.botToken ?? ''}`,
        bot_key: `${String(bot._id)}-${bot.botToken ?? ''}`
      });
    } catch {
      return sendError(reply, 500, 'INTERNAL_ERROR', 'Cannot load bot');
    }
  },

  async botsCreate(request: FastifyRequest, reply: FastifyReply) {
    try {
      if (!(await ensureAdminOrReject(request, reply))) {
        return reply;
      }

      const { name, webhookUrl } = parseBotPayload(request.body);
      if (!name) {
        return sendError(reply, 422, 'VALIDATION_ERROR', 'Bot name is required');
      }

      const token = generateBotToken();
      const bot = new UserModel({
        name: splitName(name),
        email: `bot-${Date.now()}-${token.toLowerCase()}@bots.local`,
        password: crypto.randomUUID(),
        roles: ['bot'],
        status: 'active',
        botToken: token,
        botWebhookUrl: webhookUrl ?? null
      });
      await bot.save();

      if (webhookUrl) {
        await WebhookModel.updateOne(
          { userId: bot._id },
          { $set: { url: webhookUrl }, $setOnInsert: { createdAt: new Date() } },
          { upsert: true }
        );
      }

      return sendData(
        request,
        reply,
        {
          id: String(bot._id),
          name: displayName(bot.toObject() as UserLean),
          webhookUrl: webhookUrl ?? '',
          webhook_url: webhookUrl ?? '',
          botKey: `${String(bot._id)}-${token}`,
          bot_key: `${String(bot._id)}-${token}`
        },
        201
      );
    } catch {
      return sendError(reply, 500, 'INTERNAL_ERROR', 'Cannot create bot');
    }
  },

  async botsUpdate(request: FastifyRequest, reply: FastifyReply) {
    try {
      if (!(await ensureAdminOrReject(request, reply))) {
        return reply;
      }

      const id = normalizeString((request.params as { id?: string }).id);
      const botId = asObjectId(id);
      if (!botId) {
        return sendError(reply, 422, 'VALIDATION_ERROR', 'Invalid bot id');
      }

      const { name, webhookUrl } = parseBotPayload(request.body);
      const patch: Record<string, unknown> = { updatedAt: new Date() };
      if (name) {
        patch.name = splitName(name);
      }
      if (webhookUrl !== null) {
        patch.botWebhookUrl = webhookUrl;
      }

      const bot = await UserModel.findOneAndUpdate(
        { _id: botId, roles: 'bot', status: 'active' },
        { $set: patch },
        { new: true }
      ).lean() as UserLean | null;
      if (!bot) {
        return sendError(reply, 404, 'NOT_FOUND', 'Bot not found');
      }

      if (webhookUrl !== null) {
        await WebhookModel.updateOne(
          { userId: botId },
          { $set: { url: webhookUrl, updatedAt: new Date() }, $setOnInsert: { createdAt: new Date() } },
          { upsert: true }
        );
      }

      return sendData(request, reply, {
        id: String(bot._id),
        name: displayName(bot),
        webhookUrl: bot.botWebhookUrl ?? '',
        webhook_url: bot.botWebhookUrl ?? '',
        botKey: `${String(bot._id)}-${bot.botToken ?? ''}`,
        bot_key: `${String(bot._id)}-${bot.botToken ?? ''}`
      });
    } catch {
      return sendError(reply, 500, 'INTERNAL_ERROR', 'Cannot update bot');
    }
  },

  async botsDestroy(request: FastifyRequest, reply: FastifyReply) {
    try {
      if (!(await ensureAdminOrReject(request, reply))) {
        return reply;
      }

      const id = normalizeString((request.params as { id?: string }).id);
      const botId = asObjectId(id);
      if (!botId) {
        return sendError(reply, 422, 'VALIDATION_ERROR', 'Invalid bot id');
      }

      const result = await UserModel.updateOne(
        { _id: botId, roles: 'bot', status: 'active' },
        { $set: { status: 'deactivated', updatedAt: new Date() } }
      );
      if (result.matchedCount === 0) {
        return sendError(reply, 404, 'NOT_FOUND', 'Bot not found');
      }

      await WebhookModel.deleteMany({ userId: botId });
      return sendData(request, reply, { removed: true });
    } catch {
      return sendError(reply, 500, 'INTERNAL_ERROR', 'Cannot deactivate bot');
    }
  },

  async botKeyReset(request: FastifyRequest, reply: FastifyReply) {
    try {
      if (!(await ensureAdminOrReject(request, reply))) {
        return reply;
      }

      const rawBotId = normalizeString((request.params as { botId?: string; bot_id?: string }).botId) ??
        normalizeString((request.params as { bot_id?: string }).bot_id);
      const botId = asObjectId(rawBotId);
      if (!botId) {
        return sendError(reply, 422, 'VALIDATION_ERROR', 'Invalid bot id');
      }

      const newToken = generateBotToken();
      const bot = await UserModel.findOneAndUpdate(
        { _id: botId, roles: 'bot', status: 'active' },
        { $set: { botToken: newToken, updatedAt: new Date() } },
        { new: true }
      ).lean() as UserLean | null;
      if (!bot) {
        return sendError(reply, 404, 'NOT_FOUND', 'Bot not found');
      }

      return sendData(request, reply, {
        id: String(bot._id),
        botKey: `${String(bot._id)}-${newToken}`,
        bot_key: `${String(bot._id)}-${newToken}`
      });
    } catch {
      return sendError(reply, 500, 'INTERNAL_ERROR', 'Cannot reset bot key');
    }
  },

  async joinCodeReset(request: FastifyRequest, reply: FastifyReply) {
    try {
      if (!(await ensureAdminOrReject(request, reply))) {
        return reply;
      }

      const account = await getOrCreateAccount(request);
      const joinCode = generateJoinCode();
      await AccountModel.updateOne({ _id: account._id }, { $set: { joinCode, updatedAt: new Date() } });

      return sendData(request, reply, { joinCode, join_code: joinCode });
    } catch {
      return sendError(reply, 500, 'INTERNAL_ERROR', 'Cannot rotate join code');
    }
  },

  async logoShow(request: FastifyRequest, reply: FastifyReply) {
    try {
      const account = await getOrCreateAccount(request);
      return sendData(request, reply, {
        url: account.logoUrl ?? null,
        contentType: account.logoUrl ? 'image/png' : null,
        cacheTtlSeconds: 300
      });
    } catch {
      return sendError(reply, 500, 'INTERNAL_ERROR', 'Cannot load logo');
    }
  },

  async logoDestroy(request: FastifyRequest, reply: FastifyReply) {
    try {
      if (!(await ensureAdminOrReject(request, reply))) {
        return reply;
      }

      const account = await getOrCreateAccount(request);
      await AccountModel.updateOne({ _id: account._id }, { $set: { logoUrl: null, updatedAt: new Date() } });

      return sendData(request, reply, { removed: true });
    } catch {
      return sendError(reply, 500, 'INTERNAL_ERROR', 'Cannot remove logo');
    }
  },

  async customStylesShow(request: FastifyRequest, reply: FastifyReply) {
    try {
      const account = await getOrCreateAccount(request);
      return sendData(request, reply, { customStyles: account.customStyles ?? '', custom_styles: account.customStyles ?? '' });
    } catch {
      return sendError(reply, 500, 'INTERNAL_ERROR', 'Cannot load custom styles');
    }
  },

  async customStylesUpdate(request: FastifyRequest, reply: FastifyReply) {
    try {
      if (!(await ensureAdminOrReject(request, reply))) {
        return reply;
      }

      const account = await getOrCreateAccount(request);
      const payload = parseAccountPayload(request.body);
      if (payload.customStyles === null) {
        return sendError(reply, 422, 'VALIDATION_ERROR', 'customStyles is required');
      }

      await AccountModel.updateOne(
        { _id: account._id },
        { $set: { customStyles: payload.customStyles, updatedAt: new Date() } }
      );

      return sendData(request, reply, { customStyles: payload.customStyles, custom_styles: payload.customStyles });
    } catch {
      return sendError(reply, 500, 'INTERNAL_ERROR', 'Cannot update custom styles');
    }
  }
};
