import bcrypt from 'bcryptjs';
import type { FastifyInstance, FastifyPluginAsync, FastifyRequest } from 'fastify';
import { z } from 'zod';
import { isApiPath } from '../lib/request-format.js';
import { setAuthCookie } from '../plugins/auth.js';
import { AccountModel } from '../models/account.model.js';
import { MembershipModel } from '../models/membership.model.js';
import { RoomModel } from '../models/room.model.js';
import { UserModel } from '../models/user.model.js';
import { buildUserAvatarPath } from '../services/avatar-media.js';
import { generateJoinCode } from '../services/account-singleton.js';
import { ensureImageUpload, pickField, readMultipartForm } from '../services/multipart-form.js';
import { createSession } from '../services/session-auth.js';

const firstRunSchema = z.object({
  name: z.string().min(2).max(64),
  emailAddress: z.string().email().max(320),
  password: z.string().min(8).max(128),
  avatarUrl: z.string().url().optional()
});

function parseFirstRunPayload(input: unknown) {
  if (!input || typeof input !== 'object') {
    return firstRunSchema.parse(input);
  }

  const payload = input as {
    name?: unknown;
    emailAddress?: unknown;
    email_address?: unknown;
    password?: unknown;
    avatarUrl?: unknown;
    avatar_url?: unknown;
    user?: {
      name?: unknown;
      emailAddress?: unknown;
      email_address?: unknown;
      password?: unknown;
      avatarUrl?: unknown;
      avatar_url?: unknown;
    };
  };

  const user = payload.user;

  return firstRunSchema.parse({
    name: (typeof user?.name === 'string' ? user.name : undefined) ?? (typeof payload.name === 'string' ? payload.name : undefined),
    emailAddress:
      (typeof user?.emailAddress === 'string' ? user.emailAddress : undefined) ??
      (typeof user?.email_address === 'string' ? user.email_address : undefined) ??
      (typeof payload.emailAddress === 'string' ? payload.emailAddress : undefined) ??
      (typeof payload.email_address === 'string' ? payload.email_address : undefined),
    password:
      (typeof user?.password === 'string' ? user.password : undefined) ??
      (typeof payload.password === 'string' ? payload.password : undefined),
    avatarUrl:
      (typeof user?.avatarUrl === 'string' ? user.avatarUrl : undefined) ??
      (typeof user?.avatar_url === 'string' ? user.avatar_url : undefined) ??
      (typeof payload.avatarUrl === 'string' ? payload.avatarUrl : undefined) ??
      (typeof payload.avatar_url === 'string' ? payload.avatar_url : undefined)
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

async function parseFirstRunRequest(request: FastifyRequest) {
  if (!request.isMultipart()) {
    return { payload: parseFirstRunPayload(request.body), avatar: undefined };
  }

  const { fields, files } = await readMultipartForm(request, {
    fileFields: ['avatar', 'user[avatar]', 'user.avatar']
  });

  const payload = parseFirstRunPayload({
    name: pickField(fields, ['name', 'user[name]']),
    emailAddress: pickField(fields, ['emailAddress', 'email_address', 'user[emailAddress]', 'user[email_address]']),
    password: pickField(fields, ['password', 'user[password]']),
    avatarUrl: pickField(fields, ['avatarUrl', 'avatar_url', 'user[avatarUrl]', 'user[avatar_url]'])
  });

  const avatar = ensureImageUpload(pickFile(files, ['avatar', 'user[avatar]', 'user.avatar']));
  return { payload, avatar };
}

async function serializeUser(app: FastifyInstance, user: {
  _id: unknown;
  name: string;
  emailAddress: string;
  role: string;
  status: string;
  bio?: string;
  updatedAt?: Date;
}) {
  const avatarPath = await buildUserAvatarPath(app, user);

  return {
    id: String(user._id),
    name: user.name,
    emailAddress: user.emailAddress,
    email_address: user.emailAddress,
    role: user.role,
    status: user.status,
    bio: user.bio ?? '',
    avatarUrl: avatarPath,
    avatar_url: avatarPath
  };
}

function serializeRoom(room: {
  _id: unknown;
  name?: string | null;
  type: string;
  createdAt: Date;
  updatedAt: Date;
}) {
  return {
    id: String(room._id),
    name: room.name ?? '',
    type: room.type,
    createdAt: room.createdAt,
    updatedAt: room.updatedAt
  };
}

const firstRunRoutes: FastifyPluginAsync = async (app) => {
  app.get('/first_run', async (request, reply) => {
    const accountsCount = await AccountModel.countDocuments();
    if (accountsCount > 0 && !isApiPath(request)) {
      return reply.redirect('/');
    }

    return { allowed: accountsCount === 0 };
  });

  app.post('/first_run', async (request, reply) => {
    const accountsCount = await AccountModel.countDocuments();
    if (accountsCount > 0) {
      if (!isApiPath(request)) {
        return reply.redirect('/');
      }

      return reply.code(409).send({ error: 'First run already completed' });
    }

    const { payload, avatar } = await parseFirstRunRequest(request);

    const account = await AccountModel.create({
      name: 'Campfire',
      joinCode: generateJoinCode(),
      customStyles: '',
      settings: {
        restrictRoomCreationToAdministrators: false
      },
      singletonGuard: 0
    });

    const passwordHash = await bcrypt.hash(payload.password, 12);

    const user = await UserModel.create({
      name: payload.name,
      emailAddress: payload.emailAddress.toLowerCase(),
      passwordHash,
      role: 'admin',
      status: 'active',
      avatar: avatar ?? undefined,
      avatarUrl: avatar ? '' : (payload.avatarUrl ?? '')
    });

    const room = await RoomModel.create({
      name: 'All Talk',
      type: 'open',
      creatorId: user._id
    });

    await MembershipModel.create({
      roomId: room._id,
      userId: user._id,
      involvement: 'mentions'
    });

    const session = await createSession({
      userId: String(user._id),
      userAgent: request.headers['user-agent'] ?? '',
      ipAddress: request.ip
    });

    setAuthCookie(reply, session.token);

    if (!isApiPath(request)) {
      return reply.redirect('/');
    }

    return reply.code(201).send({
      user: await serializeUser(app, user.toObject()),
      room: serializeRoom(room.toObject()),
      account: {
        id: String(account._id),
        name: account.name,
        joinCode: account.joinCode,
        join_code: account.joinCode,
        customStyles: account.customStyles ?? '',
        custom_styles: account.customStyles ?? '',
        settings: account.settings ?? {}
      }
    });
  });
};

export default firstRunRoutes;
