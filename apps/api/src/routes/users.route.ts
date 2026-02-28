import bcrypt from 'bcryptjs';
import { readFile } from 'node:fs/promises';
import { resolve } from 'node:path';
import type { FastifyInstance, FastifyPluginAsync, FastifyRequest } from 'fastify';
import { z } from 'zod';
import { asObjectId } from '../lib/object-id.js';
import { MembershipModel } from '../models/membership.model.js';
import { RoomModel } from '../models/room.model.js';
import { UserModel } from '../models/user.model.js';
import { buildUserAvatarPath, renderInitialsAvatarSvg } from '../services/avatar-media.js';
import { verifyAvatarId } from '../services/avatar-token.js';
import { buildWebpSquareVariant } from '../services/image-variants.js';
import { ensureImageUpload, pickField, readMultipartForm } from '../services/multipart-form.js';
import { signTransferId } from '../services/transfer-token.js';

const DIRECT_PLACEHOLDERS = 20;

const updateProfileSchema = z.object({
  name: z.string().trim().min(2).max(64).optional(),
  emailAddress: z.string().email().max(320).optional(),
  password: z.string().min(8).max(128).optional(),
  bio: z.string().max(2000).optional(),
  avatarUrl: z.string().url().optional()
});

function escapeRegex(input: string) {
  return input.replace(/[.*+?^${}()|[\]\\]/g, '\\$&');
}

function parseProfilePayload(input: unknown) {
  if (!input || typeof input !== 'object') {
    return updateProfileSchema.parse(input);
  }

  const payload = input as {
    name?: unknown;
    emailAddress?: unknown;
    email_address?: unknown;
    password?: unknown;
    bio?: unknown;
    avatarUrl?: unknown;
    avatar_url?: unknown;
    user?: {
      name?: unknown;
      emailAddress?: unknown;
      email_address?: unknown;
      password?: unknown;
      bio?: unknown;
      avatarUrl?: unknown;
      avatar_url?: unknown;
    };
  };

  const user = payload.user;

  return updateProfileSchema.parse({
    name: (typeof user?.name === 'string' ? user.name : undefined) ?? (typeof payload.name === 'string' ? payload.name : undefined),
    emailAddress:
      (typeof user?.emailAddress === 'string' ? user.emailAddress : undefined) ??
      (typeof user?.email_address === 'string' ? user.email_address : undefined) ??
      (typeof payload.emailAddress === 'string' ? payload.emailAddress : undefined) ??
      (typeof payload.email_address === 'string' ? payload.email_address : undefined),
    password:
      (typeof user?.password === 'string' ? user.password : undefined) ??
      (typeof payload.password === 'string' ? payload.password : undefined),
    bio: (typeof user?.bio === 'string' ? user.bio : undefined) ?? (typeof payload.bio === 'string' ? payload.bio : undefined),
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

async function parseProfileUpdateRequest(request: FastifyRequest) {
  if (!request.isMultipart()) {
    return { payload: parseProfilePayload(request.body), avatar: undefined };
  }

  const { fields, files } = await readMultipartForm(request, {
    fileFields: ['avatar', 'user[avatar]', 'user.avatar']
  });

  const payload = parseProfilePayload({
    name: pickField(fields, ['name', 'user[name]']),
    emailAddress: pickField(fields, ['emailAddress', 'email_address', 'user[emailAddress]', 'user[email_address]']),
    password: pickField(fields, ['password', 'user[password]']),
    bio: pickField(fields, ['bio', 'user[bio]']),
    avatarUrl: pickField(fields, ['avatarUrl', 'avatar_url', 'user[avatarUrl]', 'user[avatar_url]'])
  });

  const avatar = ensureImageUpload(pickFile(files, ['avatar', 'user[avatar]', 'user.avatar']));
  return { payload, avatar };
}

async function sanitizeUser(app: FastifyInstance, user: {
  _id: unknown;
  name: string;
  emailAddress: string;
  role: string;
  status: string;
  bio?: string;
  avatar?: {
    contentType: string;
    filename: string;
    byteSize: number;
  } | null;
  avatarUrl?: string;
  updatedAt?: Date;
}) {
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

const usersRoutes: FastifyPluginAsync = async (app) => {
  app.get('/', { preHandler: app.authenticate }, async (request, reply) => {
    const userId = request.authUserId;
    if (!userId) {
      return reply.code(401).send({ error: 'Unauthorized' });
    }

    const { query } = request.query as { query?: string };
    const normalized = query?.trim();

    const filter = normalized
      ? {
          name: { $regex: escapeRegex(normalized), $options: 'i' },
          _id: { $ne: userId }
        }
      : {
          _id: { $ne: userId }
        };

    const finalUsers = await UserModel.find(
      filter,
      { name: 1, emailAddress: 1, status: 1, role: 1, bio: 1, avatarUrl: 1, avatar: 1, updatedAt: 1 }
    )
      .sort({ name: 1 })
      .limit(25)
      .lean();

    return {
      users: await Promise.all(finalUsers.map((user) => sanitizeUser(app, user)))
    };
  });

  app.get('/me/profile', { preHandler: app.authenticate }, async (request, reply) => {
    const userId = request.authUserId;
    if (!userId) {
      return reply.code(401).send({ error: 'Unauthorized' });
    }

    const [user, memberships, rooms] = await Promise.all([
      UserModel.findById(
        userId,
        { name: 1, emailAddress: 1, role: 1, status: 1, bio: 1, avatarUrl: 1, avatar: 1, updatedAt: 1 }
      ).lean(),
      MembershipModel.find({ userId }).sort({ createdAt: -1 }).lean(),
      RoomModel.find({}, { name: 1, type: 1, updatedAt: 1 }).lean()
    ]);

    if (!user) {
      return reply.code(404).send({ error: 'User not found' });
    }

    const roomsById = new Map(rooms.map((room) => [String(room._id), room]));

    const directMemberships = memberships
      .filter((membership) => roomsById.get(String(membership.roomId))?.type === 'direct')
      .sort((a, b) => {
        const aRoom = roomsById.get(String(a.roomId));
        const bRoom = roomsById.get(String(b.roomId));
        return (bRoom?.updatedAt?.getTime() ?? 0) - (aRoom?.updatedAt?.getTime() ?? 0);
      })
      .map((membership) => ({
        roomId: String(membership.roomId),
        involvement: membership.involvement,
        unreadAt: membership.unreadAt
      }));

    const sharedMemberships = memberships
      .filter((membership) => roomsById.get(String(membership.roomId))?.type !== 'direct')
      .sort((a, b) => {
        const aName = roomsById.get(String(a.roomId))?.name?.toLowerCase() ?? '';
        const bName = roomsById.get(String(b.roomId))?.name?.toLowerCase() ?? '';
        return aName.localeCompare(bName);
      })
      .map((membership) => ({
        roomId: String(membership.roomId),
        roomName: roomsById.get(String(membership.roomId))?.name ?? '',
        involvement: membership.involvement,
        unreadAt: membership.unreadAt
      }));

    return {
      user: await sanitizeUser(app, user),
      directMemberships: directMemberships,
      direct_memberships: directMemberships,
      sharedMemberships: sharedMemberships,
      shared_memberships: sharedMemberships
    };
  });

  app.patch('/me/profile', { preHandler: app.authenticate }, async (request, reply) => {
    const userId = request.authUserId;
    if (!userId) {
      return reply.code(401).send({ error: 'Unauthorized' });
    }

    const user = await UserModel.findById(userId);
    if (!user) {
      return reply.code(404).send({ error: 'User not found' });
    }

    const { payload, avatar } = await parseProfileUpdateRequest(request);

    if (payload.name !== undefined) {
      user.name = payload.name;
    }

    if (payload.emailAddress !== undefined) {
      user.emailAddress = payload.emailAddress.toLowerCase();
    }

    if (payload.password) {
      user.passwordHash = await bcrypt.hash(payload.password, 12);
    }

    if (payload.bio !== undefined) {
      user.bio = payload.bio;
    }

    if (avatar) {
      user.avatar = avatar;
      user.avatarUrl = '';
    } else if (payload.avatarUrl !== undefined) {
      user.avatar = undefined;
      user.avatarUrl = payload.avatarUrl;
    }

    await user.save();

    return { user: await sanitizeUser(app, user.toObject()) };
  });

  app.get('/me/sidebar', { preHandler: app.authenticate }, async (request, reply) => {
    const userId = request.authUserId;
    if (!userId) {
      return reply.code(401).send({ error: 'Unauthorized' });
    }

    const allMemberships = await MembershipModel.find({ userId, involvement: { $ne: 'invisible' } }).lean();
    const roomIds = allMemberships.map((membership) => membership.roomId);
    const rooms = await RoomModel.find({ _id: { $in: roomIds } }).lean();
    const roomsById = new Map(rooms.map((room) => [String(room._id), room]));

    const directMemberships = allMemberships
      .filter((membership) => roomsById.get(String(membership.roomId))?.type === 'direct')
      .sort((a, b) => {
        const aRoom = roomsById.get(String(a.roomId));
        const bRoom = roomsById.get(String(b.roomId));
        return (bRoom?.updatedAt?.getTime() ?? 0) - (aRoom?.updatedAt?.getTime() ?? 0);
      });

    const otherMemberships = allMemberships
      .filter((membership) => roomsById.get(String(membership.roomId))?.type !== 'direct')
      .sort((a, b) => {
        const aName = roomsById.get(String(a.roomId))?.name?.toLowerCase() ?? '';
        const bName = roomsById.get(String(b.roomId))?.name?.toLowerCase() ?? '';
        return aName.localeCompare(bName);
      });

    const directRoomIds = directMemberships.map((membership) => membership.roomId);
    const directMembers =
      directRoomIds.length > 0
        ? await MembershipModel.find({ roomId: { $in: directRoomIds }, userId: { $ne: userId } }, { roomId: 1, userId: 1 }).lean()
        : [];

    const directPartnerIds = Array.from(new Set(directMembers.map((membership) => String(membership.userId))));
    const directPartnerUsers =
      directPartnerIds.length > 0
        ? await UserModel.find({ _id: { $in: directPartnerIds } }, { name: 1, avatarUrl: 1, avatar: 1, status: 1, updatedAt: 1 }).lean()
        : [];
    const directPartnersById = new Map(directPartnerUsers.map((user) => [String(user._id), user]));

    const usersInDirectRoom = new Set<string>([userId, ...directPartnerIds]);
    const placeholdersLimit = Math.max(0, DIRECT_PLACEHOLDERS - usersInDirectRoom.size);

    const directPlaceholderUsers =
      placeholdersLimit > 0
        ? await UserModel.find(
            {
              _id: { $nin: Array.from(usersInDirectRoom) },
              status: 'active'
            },
            { name: 1, avatarUrl: 1, avatar: 1, updatedAt: 1 }
          )
            .sort({ createdAt: 1 })
            .limit(placeholdersLimit)
            .lean()
        : [];

    const directRooms = directMemberships.map((membership) => {
      const room = roomsById.get(String(membership.roomId));
      const partnerMembership = directMembers.find((member) => String(member.roomId) === String(membership.roomId));
      const partner = partnerMembership ? directPartnersById.get(String(partnerMembership.userId)) : undefined;

      return {
        roomId: String(membership.roomId),
        roomName: partner?.name ?? room?.name ?? 'Direct',
        involvement: membership.involvement,
        unreadAt: membership.unreadAt
      };
    });

    const sharedRooms = otherMemberships.map((membership) => {
      const room = roomsById.get(String(membership.roomId));
      return {
        roomId: String(membership.roomId),
        roomName: room?.name ?? '',
        roomType: room?.type ?? 'open',
        involvement: membership.involvement,
        unreadAt: membership.unreadAt
      };
    });

    const serializedPlaceholders = await Promise.all(
      directPlaceholderUsers.map(async (user) => {
        const avatarPath = await buildUserAvatarPath(app, user);
        return {
          id: String(user._id),
          name: user.name,
          avatarUrl: avatarPath,
          avatar_url: avatarPath
        };
      })
    );

    return {
      directRooms,
      direct_rooms: directRooms,
      sharedRooms,
      shared_rooms: sharedRooms,
      directPlaceholderUsers: serializedPlaceholders,
      direct_placeholder_users: serializedPlaceholders
    };
  });

  app.get('/:userId/avatar', async (request, reply) => {
    const { userId: requestedUserId } = request.params as { userId: string };

    const verifiedUserId = verifyAvatarId(app, requestedUserId);
    if (!verifiedUserId) {
      return reply.code(404).send({ error: 'User not found' });
    }

    const user = await UserModel.findById(verifiedUserId, {
      name: 1,
      role: 1,
      avatar: 1,
      avatarUrl: 1,
      updatedAt: 1
    });
    if (!user) {
      return reply.code(404).send({ error: 'User not found' });
    }

    reply.header('cache-control', 'public, max-age=1800, stale-while-revalidate=604800');

    if (user.avatar?.data) {
      try {
        const variant = await buildWebpSquareVariant(user.avatar.data, 512);
        const safeName = user.avatar.filename.replace(/"/g, '').replace(/\.[^.]+$/, '') || 'avatar';
        reply.header('content-type', 'image/webp');
        reply.header('content-disposition', `inline; filename="${safeName}.webp"`);
        return reply.send(variant);
      } catch {
        reply.header('content-type', user.avatar.contentType || 'application/octet-stream');
        reply.header('content-disposition', `inline; filename="${user.avatar.filename.replace(/"/g, '')}"`);
        return reply.send(user.avatar.data);
      }
    }

    if (user.avatarUrl) {
      return reply.redirect(user.avatarUrl);
    }

    if (user.role === 'bot') {
      const defaultBotAvatarPath = resolve(process.cwd(), '../../app/assets/images/default-bot-avatar.svg');
      try {
        const content = await readFile(defaultBotAvatarPath);
        reply.header('content-type', 'image/svg+xml');
        return reply.send(content);
      } catch {
        reply.header('content-type', 'image/svg+xml');
        return reply.send(
          '<svg xmlns="http://www.w3.org/2000/svg" width="128" height="128" viewBox="0 0 128 128"><rect width="128" height="128" fill="#1f2937"/><circle cx="44" cy="52" r="10" fill="#fff"/><circle cx="84" cy="52" r="10" fill="#fff"/><rect x="32" y="80" width="64" height="12" rx="6" fill="#fff"/></svg>'
        );
      }
    }

    reply.header('content-type', 'image/svg+xml');
    return reply.send(renderInitialsAvatarSvg(user.name, String(user._id)));
  });

  app.delete('/:userId/avatar', { preHandler: app.authenticate }, async (request, reply) => {
    const authUserId = request.authUserId;
    if (!authUserId) {
      return reply.code(401).send({ error: 'Unauthorized' });
    }

    const { userId } = request.params as { userId: string };
    const tokenUserId = verifyAvatarId(app, userId);
    if (userId !== authUserId && userId !== 'me' && tokenUserId !== authUserId) {
      return reply.code(403).send({ error: 'Forbidden' });
    }

    const user = await UserModel.findById(authUserId);
    if (!user) {
      return reply.code(404).send({ error: 'User not found' });
    }

    user.avatar = undefined;
    user.avatarUrl = '';
    await user.save();

    return reply.code(204).send();
  });

  app.get('/:id', { preHandler: app.authenticate }, async (request, reply) => {
    const authUserId = request.authUserId;
    if (!authUserId) {
      return reply.code(401).send({ error: 'Unauthorized' });
    }

    const { id } = request.params as { id: string };
    const targetId = id === 'me' ? authUserId : id;

    const [actor, user] = await Promise.all([
      UserModel.findById(authUserId, { role: 1 }).lean(),
      UserModel.findById(
        targetId,
        { name: 1, emailAddress: 1, role: 1, status: 1, bio: 1, avatarUrl: 1, avatar: 1, updatedAt: 1 }
      ).lean()
    ]);

    if (!user) {
      return reply.code(404).send({ error: 'User not found' });
    }

    const responseUser = await sanitizeUser(app, user);

    if (actor?.role === 'admin' && user.role !== 'bot' && user.status === 'active') {
      const transferId = await signTransferId(app, String(user._id));
      return {
        user: {
          ...responseUser,
          transferId,
          transfer_id: transferId
        }
      };
    }

    return { user: responseUser };
  });
};

export default usersRoutes;
