import bcrypt from 'bcryptjs';
import type { FastifyInstance, FastifyPluginAsync, FastifyRequest } from 'fastify';
import { z } from 'zod';
import { isApiPath } from '../lib/request-format.js';
import { setAuthCookie } from '../plugins/auth.js';
import { MembershipModel } from '../models/membership.model.js';
import { RoomModel } from '../models/room.model.js';
import { UserModel } from '../models/user.model.js';
import { buildUserAvatarPath } from '../services/avatar-media.js';
import { getAccount } from '../services/account-singleton.js';
import { ensureImageUpload, pickField, readMultipartForm } from '../services/multipart-form.js';
import { createSession } from '../services/session-auth.js';

const joinSchema = z.object({
  name: z.string().trim().min(2).max(64),
  emailAddress: z.string().email().max(320),
  password: z.string().min(8).max(128),
  avatarUrl: z.string().url().optional()
});

function parseJoinPayload(input: unknown) {
  if (!input || typeof input !== 'object') {
    return joinSchema.parse(input);
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

  return joinSchema.parse({
    name:
      (typeof user?.name === 'string' ? user.name : undefined) ??
      (typeof payload.name === 'string' ? payload.name : undefined),
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

async function parseJoinRequest(request: FastifyRequest) {
  if (!request.isMultipart()) {
    return { payload: parseJoinPayload(request.body), avatar: undefined };
  }

  const { fields, files } = await readMultipartForm(request, {
    fileFields: ['avatar', 'user[avatar]', 'user.avatar']
  });

  const payload = parseJoinPayload({
    name: pickField(fields, ['name', 'user[name]']),
    emailAddress: pickField(fields, ['emailAddress', 'email_address', 'user[emailAddress]', 'user[email_address]']),
    password: pickField(fields, ['password', 'user[password]']),
    avatarUrl: pickField(fields, ['avatarUrl', 'avatar_url', 'user[avatarUrl]', 'user[avatar_url]'])
  });

  const avatar = ensureImageUpload(pickFile(files, ['avatar', 'user[avatar]', 'user.avatar']));
  return { payload, avatar };
}

async function sanitizeUser(
  app: FastifyInstance,
  user: {
    _id: unknown;
    name: string;
    emailAddress: string;
    role: string;
    status: string;
    bio?: string;
    updatedAt?: Date;
  }
) {
  const avatarPath = await buildUserAvatarPath(app, user);

  return {
    id: String(user._id),
    name: user.name,
    emailAddress: user.emailAddress,
    email_address: user.emailAddress,
    role: user.role === 'admin' ? 'administrator' : user.role,
    status: user.status,
    bio: user.bio ?? '',
    avatarUrl: avatarPath,
    avatar_url: avatarPath
  };
}

const joinRoutes: FastifyPluginAsync = async (app) => {
  app.get('/join/:joinCode', async (request, reply) => {
    const auth = await app.tryAuthenticate(request);
    if (auth) {
      if (isApiPath(request)) {
        return reply.code(409).send({ error: 'Already signed in' });
      }

      return reply.redirect('/');
    }

    const { joinCode } = request.params as { joinCode: string };
    const account = await getAccount();

    if (!account || account.joinCode !== joinCode) {
      return reply.code(404).send({ error: 'Join code not found' });
    }

    return { valid: true };
  });

  app.post('/join/:joinCode', async (request, reply) => {
    const auth = await app.tryAuthenticate(request);
    if (auth) {
      if (isApiPath(request)) {
        return reply.code(409).send({ error: 'Already signed in' });
      }

      return reply.redirect('/');
    }

    const { joinCode } = request.params as { joinCode: string };
    const account = await getAccount();

    if (!account || account.joinCode !== joinCode) {
      return reply.code(404).send({ error: 'Join code not found' });
    }

    const { payload, avatar } = await parseJoinRequest(request);

    const existing = await UserModel.findOne({ emailAddress: payload.emailAddress.toLowerCase() }).lean();
    if (existing) {
      if (!isApiPath(request)) {
        return reply.redirect(`/session/new?email_address=${encodeURIComponent(payload.emailAddress.toLowerCase())}`);
      }
      return reply.code(409).send({ error: 'Email already used' });
    }

    const passwordHash = await bcrypt.hash(payload.password, 12);

    const user = await UserModel.create({
      name: payload.name,
      emailAddress: payload.emailAddress.toLowerCase(),
      passwordHash,
      role: 'member',
      status: 'active',
      avatar: avatar ?? undefined,
      avatarUrl: avatar ? '' : (payload.avatarUrl ?? '')
    });

    const openRooms = await RoomModel.find({ type: 'open' }, { _id: 1 }).lean();
    if (openRooms.length > 0) {
      await MembershipModel.insertMany(
        openRooms.map((room) => ({
          roomId: room._id,
          userId: user._id,
          involvement: 'mentions'
        })),
        { ordered: false }
      );
    }

    const session = await createSession({
      userId: String(user._id),
      userAgent: request.headers['user-agent'] ?? '',
      ipAddress: request.ip
    });

    setAuthCookie(reply, session.token);

    if (!isApiPath(request)) {
      return reply.redirect('/');
    }

    return reply.code(201).send({ user: await sanitizeUser(app, user.toObject()) });
  });
};

export default joinRoutes;
