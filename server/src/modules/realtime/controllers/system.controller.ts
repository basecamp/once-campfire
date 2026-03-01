import bcrypt from 'bcryptjs';
import crypto from 'node:crypto';
import type { FastifyReply, FastifyRequest } from 'fastify';
import QRCode from 'qrcode';
import { Types } from 'mongoose';
import { MembershipModel } from '../../rooms/models/membership.model.js';
import { PushSubscriptionModel } from '../../push/models/push-subscription.model.js';
import { SessionModel } from '../models/session.model.js';
import { AccountModel } from '../../account/models/account.model.js';
import UserModel from '../../users/models/user.model.js';
import { asObjectId, getAuthUserId, sendData, sendError } from '../../../shared/utils/controller.js';

interface UserLean {
  _id: Types.ObjectId;
  email: string;
  password?: string;
  roles?: string[];
  status?: string;
  transferId?: string | null;
  name?: {
    first?: string;
    last?: string;
  };
}

interface AccountLean {
  _id: Types.ObjectId;
  name: string;
  joinCode: string;
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

function parseSessionPayload(body: unknown) {
  if (!body || typeof body !== 'object') {
    return { emailAddress: null, password: null };
  }
  const raw = body as Record<string, unknown>;
  return {
    emailAddress: normalizeString(raw.emailAddress ?? raw.email_address ?? raw.email)?.toLowerCase() ?? null,
    password: normalizeString(raw.password)
  };
}

function parseFirstRunPayload(body: unknown) {
  if (!body || typeof body !== 'object') {
    return { name: null, emailAddress: null, password: null };
  }
  const raw = body as Record<string, unknown>;
  const nested = raw.user && typeof raw.user === 'object' ? (raw.user as Record<string, unknown>) : null;

  return {
    name: normalizeString(nested?.name ?? raw.name),
    emailAddress: normalizeString(
      nested?.emailAddress ?? nested?.email_address ?? raw.emailAddress ?? raw.email_address ?? raw.email
    )?.toLowerCase() ?? null,
    password: normalizeString(nested?.password ?? raw.password)
  };
}

async function ensureAccount(): Promise<AccountLean> {
  const existing = await AccountModel.findOne({}).sort({ createdAt: 1 }).lean<AccountLean>();
  if (existing) {
    return existing;
  }

  const account = await AccountModel.create({
    name: 'Campfire',
    joinCode: crypto.randomBytes(6).toString('base64url').replace(/[^a-zA-Z0-9]/g, '').slice(0, 8).toUpperCase()
  });
  return account.toObject() as AccountLean;
}

function decodeUrlSafeBase64(input: string): string | null {
  try {
    const value = Buffer.from(input, 'base64url').toString('utf8').trim();
    return value.length > 0 ? value : null;
  } catch {
    return null;
  }
}

export const systemController = {
  async welcome(request: FastifyRequest, reply: FastifyReply) {
    try {
      const authUserId = asObjectId(getAuthUserId(request));
      if (!authUserId) {
        return sendError(reply, 401, 'UNAUTHORIZED', 'Unauthorized');
      }

      const memberships = await MembershipModel.find({ userId: authUserId }, { roomId: 1, updatedAt: 1 })
        .sort({ updatedAt: -1 })
        .limit(1)
        .lean();
      const roomId = memberships[0]?.roomId ? String(memberships[0].roomId) : null;

      return sendData(request, reply, { app: 'campfire', ok: true, roomId, room_id: roomId });
    } catch {
      return sendError(reply, 500, 'INTERNAL_ERROR', 'Cannot load welcome payload');
    }
  },

  async firstRunShow(request: FastifyRequest, reply: FastifyReply) {
    try {
      const usersCount = await UserModel.countDocuments({});
      return sendData(request, reply, { firstRunRequired: usersCount === 0, first_run_required: usersCount === 0 });
    } catch {
      return sendError(reply, 500, 'INTERNAL_ERROR', 'Cannot check first run state');
    }
  },

  async firstRunCreate(request: FastifyRequest, reply: FastifyReply) {
    try {
      const usersCount = await UserModel.countDocuments({});
      if (usersCount > 0) {
        return sendError(reply, 409, 'CONFLICT', 'First run already completed');
      }

      const payload = parseFirstRunPayload(request.body);
      if (!payload.name || !payload.emailAddress || !payload.password) {
        return sendError(reply, 422, 'VALIDATION_ERROR', 'name, emailAddress and password are required');
      }

      const account = await ensureAccount();
      const user = new UserModel({
        name: splitName(payload.name),
        email: payload.emailAddress,
        password: payload.password,
        roles: ['administrator'],
        status: 'active',
        transferId: null
      });
      await user.save();

      return sendData(
        request,
        reply,
        {
          created: true,
          userId: String(user._id),
          user_id: String(user._id),
          accountId: String(account._id),
          account_id: String(account._id)
        },
        201
      );
    } catch {
      return sendError(reply, 500, 'INTERNAL_ERROR', 'Cannot complete first run');
    }
  },

  async sessionNew(request: FastifyRequest, reply: FastifyReply) {
    try {
      const usersCount = await UserModel.countDocuments({});
      return sendData(request, reply, { firstRunRequired: usersCount === 0, first_run_required: usersCount === 0 });
    } catch {
      return sendError(reply, 500, 'INTERNAL_ERROR', 'Cannot load session form state');
    }
  },

  async sessionCreate(request: FastifyRequest, reply: FastifyReply) {
    try {
      const payload = parseSessionPayload(request.body);
      if (!payload.emailAddress || !payload.password) {
        return sendError(reply, 422, 'VALIDATION_ERROR', 'emailAddress and password are required');
      }

      const user = await UserModel.findOne({
        email: payload.emailAddress,
        status: 'active'
      }).lean() as UserLean | null;
      if (!user || !user.password) {
        return sendError(reply, 401, 'UNAUTHORIZED', 'Unauthorized');
      }

      const validPassword = await bcrypt.compare(payload.password, user.password);
      if (!validPassword) {
        return sendError(reply, 401, 'UNAUTHORIZED', 'Unauthorized');
      }

      const token = crypto.randomBytes(24).toString('base64url');
      await SessionModel.create({
        userId: user._id,
        token,
        ipAddress: request.ip,
        userAgent: request.headers['user-agent'] ?? null,
        lastActiveAt: new Date()
      });

      return sendData(request, reply, {
        authenticated: true,
        userId: String(user._id),
        user_id: String(user._id),
        sessionToken: token,
        session_token: token
      });
    } catch {
      return sendError(reply, 500, 'INTERNAL_ERROR', 'Cannot create session');
    }
  },

  async sessionDestroy(request: FastifyRequest, reply: FastifyReply) {
    try {
      const authUserId = asObjectId(getAuthUserId(request));
      const endpoint = normalizeString(
        (request.body as { push_subscription_endpoint?: unknown; pushSubscriptionEndpoint?: unknown } | null)
          ?.push_subscription_endpoint ??
          (request.body as { pushSubscriptionEndpoint?: unknown } | null)?.pushSubscriptionEndpoint
      );

      if (authUserId) {
        await SessionModel.deleteMany({ userId: authUserId });
        if (endpoint) {
          await PushSubscriptionModel.deleteOne({ userId: authUserId, endpoint });
        }
      }

      return sendData(request, reply, { terminated: true });
    } catch {
      return sendError(reply, 500, 'INTERNAL_ERROR', 'Cannot destroy session');
    }
  },

  async sessionTransferShow(request: FastifyRequest, reply: FastifyReply) {
    try {
      const transferId = normalizeString((request.params as { id?: string }).id);
      if (!transferId) {
        return sendError(reply, 400, 'BAD_REQUEST', 'transfer id is required');
      }

      const user = await UserModel.findOne(
        { transferId, status: 'active' },
        { _id: 1, name: 1, email: 1 }
      ).lean() as UserLean | null;
      if (!user) {
        return sendError(reply, 404, 'NOT_FOUND', 'Transfer not found');
      }

      return sendData(request, reply, {
        valid: true,
        userId: String(user._id),
        user_id: String(user._id),
        name: displayName(user)
      });
    } catch {
      return sendError(reply, 500, 'INTERNAL_ERROR', 'Cannot load transfer');
    }
  },

  async sessionTransferUpdate(request: FastifyRequest, reply: FastifyReply) {
    try {
      const transferId = normalizeString((request.params as { id?: string }).id);
      if (!transferId) {
        return sendError(reply, 400, 'BAD_REQUEST', 'transfer id is required');
      }

      const user = await UserModel.findOne(
        { transferId, status: 'active' },
        { _id: 1 }
      ).lean() as UserLean | null;
      if (!user) {
        return sendError(reply, 400, 'BAD_REQUEST', 'Transfer not found');
      }

      const newTransferId = crypto.randomUUID();
      await UserModel.updateOne({ _id: user._id }, { $set: { transferId: newTransferId, updatedAt: new Date() } });

      return sendData(request, reply, {
        authenticated: true,
        userId: String(user._id),
        user_id: String(user._id)
      });
    } catch {
      return sendError(reply, 500, 'INTERNAL_ERROR', 'Cannot apply transfer');
    }
  },

  async qrCode(request: FastifyRequest, reply: FastifyReply) {
    try {
      const encoded = normalizeString((request.params as { id?: string }).id);
      if (!encoded) {
        return sendError(reply, 400, 'BAD_REQUEST', 'id is required');
      }

      const decoded = decodeUrlSafeBase64(encoded);
      if (!decoded) {
        return sendError(reply, 404, 'NOT_FOUND', 'QR payload not found');
      }

      const svg = await QRCode.toString(decoded, {
        type: 'svg',
        color: {
          dark: '#000000',
          light: '#ffffff'
        }
      });

      return sendData(request, reply, {
        contentType: 'image/svg+xml',
        sourceUrl: decoded,
        source_url: decoded,
        svg
      });
    } catch {
      return sendError(reply, 500, 'INTERNAL_ERROR', 'Cannot generate QR code');
    }
  },

  async pwaManifest(request: FastifyRequest, reply: FastifyReply) {
    const domain = process.env.DOMAIN ?? 'api.meteorhr.com';
    return sendData(request, reply, {
      name: 'Campfire',
      short_name: 'Campfire',
      start_url: '/',
      display: 'standalone',
      scope: '/',
      background_color: '#ffffff',
      theme_color: '#222222',
      icons: [
        {
          src: `https://${domain}/account/logo?size=small`,
          type: 'image/png',
          sizes: '192x192'
        }
      ]
    });
  },

  async serviceWorker(request: FastifyRequest, reply: FastifyReply) {
    return sendData(request, reply, {
      path: '/service-worker.js',
      cache: 'no-store',
      note: 'Service worker script should be served by frontend static host'
    });
  }
};
