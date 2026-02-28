import type { FastifyPluginAsync, FastifyRequest, RouteHandlerMethod } from 'fastify';
import { z } from 'zod';
import { asObjectId } from '../lib/object-id.js';
import { isApiPath } from '../lib/request-format.js';
import { MembershipModel } from '../models/membership.model.js';
import { MessageModel } from '../models/message.model.js';
import { RoomModel } from '../models/room.model.js';
import { UserModel } from '../models/user.model.js';
import { BoostModel } from '../models/boost.model.js';
import { disconnectUser } from '../realtime/connection-manager.js';
import { publishRealtimeEvent } from '../realtime/redis-realtime.js';
import { enqueueEligibleBotWebhooks } from '../services/bot-dispatch.js';
import { getOrCreateAccount } from '../services/account-singleton.js';
import { handleMessageCreated } from '../services/message-events.js';
import {
  buildMessageAttachmentFromBuffer,
  type StoredMessageAttachment,
  serializeMessageAttachment
} from '../services/message-attachment.js';

const MESSAGE_PAGE_SIZE = 40;
const LAST_ROOM_COOKIE = 'last_room';

const createRoomSchema = z.object({
  name: z.string().min(2).max(80),
  type: z.enum(['open', 'closed']).default('open'),
  userIds: z.array(z.string()).default([])
});

const openOrClosedSchema = z.object({
  name: z.string().trim().min(2).max(80).optional(),
  userIds: z.array(z.string().min(1)).optional(),
  user_ids: z.array(z.string().min(1)).optional(),
  room: z
    .object({
      name: z.string().trim().min(2).max(80).optional()
    })
    .optional()
});

const createDirectSchema = z
  .object({
    userId: z.string().min(1).optional(),
    userIds: z.array(z.string().min(1)).optional(),
    user_ids: z.array(z.string().min(1)).optional()
  })
  .refine(
    (value) => Boolean(value.userId || (value.userIds && value.userIds.length > 0) || (value.user_ids && value.user_ids.length > 0)),
    { message: 'userId or userIds is required' }
  );

const messagePayloadSchema = z.object({
  body: z.string().trim().max(4000).optional(),
  clientMessageId: z.string().trim().min(1).max(128).optional()
});

const updateInvolvementSchema = z.object({
  involvement: z.enum(['invisible', 'nothing', 'mentions', 'everything'])
});

function authenticateBotKey(botKey: string) {
  const [botId, botToken] = botKey.split('-');
  if (!botId || !botToken) {
    return null;
  }

  return { botId, botToken };
}

function createDirectKey(userIds: string[]) {
  return Array.from(new Set(userIds.map((id) => id.trim()).filter(Boolean))).sort().join(':');
}

function normalizeUserIds(userIds: string[]) {
  return Array.from(new Set(userIds.map((id) => id.trim()).filter(Boolean)));
}

function parseMessagePayload(input: unknown) {
  let parsed: z.infer<typeof messagePayloadSchema>;

  if (typeof input === 'string') {
    parsed = messagePayloadSchema.parse({ body: input });
  } else if (!input || typeof input !== 'object') {
    parsed = messagePayloadSchema.parse(input);
  } else {
    const payload = input as {
      body?: unknown;
      clientMessageId?: unknown;
      client_message_id?: unknown;
      message?: {
        body?: unknown;
        clientMessageId?: unknown;
        client_message_id?: unknown;
      };
    };

    const message = payload.message;

    parsed = messagePayloadSchema.parse({
      body:
        (typeof message?.body === 'string' ? message.body : undefined) ??
        (typeof payload.body === 'string' ? payload.body : undefined),
      clientMessageId:
        (typeof message?.clientMessageId === 'string' ? message.clientMessageId : undefined) ??
        (typeof message?.client_message_id === 'string' ? message.client_message_id : undefined) ??
        (typeof payload.clientMessageId === 'string' ? payload.clientMessageId : undefined) ??
        (typeof payload.client_message_id === 'string' ? payload.client_message_id : undefined)
    });
  }

  if (!parsed.body?.trim()) {
    throw new Error('body is required');
  }

  return {
    body: parsed.body.trim(),
    clientMessageId: parsed.clientMessageId
  };
}

type MessageAttachment = StoredMessageAttachment;

type ParsedMessageCreate = {
  body: string;
  clientMessageId?: string;
  attachment?: MessageAttachment;
};

function normalizeBody(value: unknown) {
  return typeof value === 'string' ? value.trim() : '';
}

function readFieldValue(part: { value: unknown }) {
  return typeof part.value === 'string' ? part.value : '';
}

async function parseMultipartMessagePayload(request: FastifyRequest): Promise<ParsedMessageCreate> {
  if (!request.isMultipart()) {
    throw new Error('Request is not multipart');
  }

  let body = '';
  let clientMessageId: string | undefined;
  let attachment: MessageAttachment | undefined;

  for await (const part of request.parts()) {
    if (part.type === 'file') {
      if (part.fieldname !== 'attachment') {
        part.file.resume();
        continue;
      }

      const buffer = await part.toBuffer();
      if (buffer.byteLength === 0) {
        continue;
      }

      attachment = await buildMessageAttachmentFromBuffer(buffer, part.mimetype, part.filename);
      continue;
    }

    if (part.fieldname === 'body' || part.fieldname === 'message[body]' || part.fieldname === 'message.body') {
      body = readFieldValue(part);
      continue;
    }

    if (
      part.fieldname === 'clientMessageId' ||
      part.fieldname === 'client_message_id' ||
      part.fieldname === 'message[client_message_id]' ||
      part.fieldname === 'message.client_message_id' ||
      part.fieldname === 'message[clientMessageId]' ||
      part.fieldname === 'message.clientMessageId'
    ) {
      const value = readFieldValue(part).trim();
      if (value) {
        clientMessageId = value;
      }
    }
  }

  const normalizedBody = normalizeBody(body);
  if (!normalizedBody && !attachment) {
    throw new Error('body or attachment is required');
  }

  return {
    body: normalizedBody,
    clientMessageId,
    attachment
  };
}

async function parseMessageCreatePayload(request: FastifyRequest): Promise<ParsedMessageCreate> {
  if (request.isMultipart()) {
    return parseMultipartMessagePayload(request);
  }

  const parsed = parseMessagePayload(request.body);
  return {
    body: parsed.body,
    clientMessageId: parsed.clientMessageId
  };
}

async function parseBotMessagePayload(request: FastifyRequest): Promise<ParsedMessageCreate> {
  if (request.isMultipart()) {
    return parseMultipartMessagePayload(request);
  }

  if (Buffer.isBuffer(request.body)) {
    if (request.body.byteLength === 0) {
      throw new Error('Empty payload');
    }

    return {
      body: '',
      attachment: await buildMessageAttachmentFromBuffer(request.body, request.headers['content-type'])
    };
  }

  if (typeof request.body === 'string') {
    const body = request.body.trim();
    if (!body) {
      throw new Error('body is required');
    }

    return { body };
  }

  return parseMessageCreatePayload(request);
}

function parseOpenOrClosedPayload(input: unknown) {
  const payload = openOrClosedSchema.parse(input);

  return {
    name: payload.room?.name ?? payload.name ?? 'New room',
    userIds: normalizeUserIds([...(payload.userIds ?? []), ...(payload.user_ids ?? [])])
  };
}

async function canAdministerRecord(actorId: string, creatorId: unknown) {
  if (String(creatorId) === actorId) {
    return true;
  }

  const actor = await UserModel.findById(actorId, { role: 1 }).lean();
  return actor?.role === 'admin';
}

async function isAdmin(actorId: string) {
  const actor = await UserModel.findById(actorId, { role: 1 }).lean();
  return actor?.role === 'admin';
}

async function grantRoomMemberships({
  roomId,
  userIds,
  involvement
}: {
  roomId: unknown;
  userIds: string[];
  involvement: 'mentions' | 'everything' | 'nothing' | 'invisible';
}) {
  if (userIds.length === 0) {
    return;
  }

  await MembershipModel.insertMany(
    userIds.map((userId) => ({
      roomId,
      userId,
      involvement
    })),
    { ordered: false }
  ).catch(() => {
    // Ignore duplicates.
  });
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

function rememberLastRoom(reply: import('fastify').FastifyReply, roomId: string) {
  reply.setCookie(LAST_ROOM_COOKIE, roomId, {
    path: '/',
    httpOnly: true,
    sameSite: 'lax',
    maxAge: 60 * 60 * 24 * 365 * 10
  });
}

async function serializeMessages(messages: Array<{
  _id: unknown;
  clientMessageId: string;
  body: string;
  attachment?: {
    contentType: string;
    filename: string;
    byteSize: number;
    width?: number | null;
    height?: number | null;
    previewable?: boolean | null;
    variable?: boolean | null;
  } | null;
  roomId: unknown;
  creatorId: unknown;
  createdAt: Date;
  updatedAt: Date;
}>) {
  const messageIds = messages.map((message) => message._id);
  const creatorIds = Array.from(new Set(messages.map((message) => String(message.creatorId))));

  const [creators, boosts] = await Promise.all([
    creatorIds.length > 0 ? UserModel.find({ _id: { $in: creatorIds } }, { name: 1 }).lean() : [],
    messageIds.length > 0 ? BoostModel.find({ messageId: { $in: messageIds } }).sort({ createdAt: 1 }).lean() : []
  ]);

  const creatorsById = new Map(creators.map((creator) => [String(creator._id), creator]));
  const boostsByMessageId = new Map<string, typeof boosts>();
  for (const boost of boosts) {
    const key = String(boost.messageId);
    const prev = boostsByMessageId.get(key) ?? [];
    prev.push(boost);
    boostsByMessageId.set(key, prev);
  }

  return messages.map((message) => {
    const messageBoosts = boostsByMessageId.get(String(message._id)) ?? [];
    const summary = messageBoosts.reduce<Record<string, number>>((acc, boost) => {
      const key = boost.content;
      acc[key] = (acc[key] ?? 0) + 1;
      return acc;
    }, {});

    return {
      id: String(message._id),
      clientMessageId: message.clientMessageId,
      body: message.body,
      roomId: String(message.roomId),
      creatorId: String(message.creatorId),
      creator: creatorsById.get(String(message.creatorId))
        ? {
            name: creatorsById.get(String(message.creatorId))?.name ?? 'Unknown'
          }
        : undefined,
      boosts: messageBoosts.map((boost) => ({
        id: String(boost._id),
        content: boost.content,
        boosterId: String(boost.boosterId),
        createdAt: boost.createdAt
      })),
      boostSummary: summary,
      attachment: message.attachment ? serializeMessageAttachment(String(message._id), message.attachment) : undefined,
      createdAt: message.createdAt,
      updatedAt: message.updatedAt
    };
  });
}

async function ensureRoomAccessForUser(userId: string, roomId: string) {
  const roomObjectId = asObjectId(roomId);
  if (!roomObjectId) {
    return { error: 'invalid_room_id' as const };
  }

  const [membership, room] = await Promise.all([
    MembershipModel.findOne({ roomId: roomObjectId, userId }).lean(),
    RoomModel.findById(roomObjectId)
  ]);

  if (!membership) {
    return { error: 'forbidden' as const };
  }

  if (!room) {
    return { error: 'not_found' as const };
  }

  return {
    roomObjectId,
    membership,
    room
  };
}

async function removeRoomForUser(userId: string, roomId: string) {
  const access = await ensureRoomAccessForUser(userId, roomId);
  if ('error' in access) {
    return access;
  }

  if (!(await canAdministerRecord(userId, access.room.creatorId))) {
    return { error: 'forbidden' as const };
  }

  const [memberUserIds, messages] = await Promise.all([
    MembershipModel.find({ roomId: access.roomObjectId }, { userId: 1 }).lean(),
    MessageModel.find({ roomId: access.roomObjectId }, { _id: 1 }).lean()
  ]);

  const messageIds = messages.map((message) => message._id);

  await Promise.all([
    MembershipModel.deleteMany({ roomId: access.roomObjectId }),
    MessageModel.deleteMany({ roomId: access.roomObjectId }),
    messageIds.length > 0 ? BoostModel.deleteMany({ messageId: { $in: messageIds } }) : Promise.resolve(),
    RoomModel.deleteOne({ _id: access.roomObjectId })
  ]);

  await publishRealtimeEvent({
    type: 'room.removed',
    roomId,
    payload: { roomId },
    userIds: memberUserIds.map((member) => String(member.userId))
  });

  return { ok: true as const };
}

const roomsRoutes: FastifyPluginAsync = async (app) => {
  app.get('/', { preHandler: app.authenticate }, async (request, reply) => {
    const userId = request.authUserId;
    if (!userId) {
      return reply.code(401).send({ error: 'Unauthorized' });
    }

    const memberships = await MembershipModel.find({ userId }).sort({ createdAt: -1 }).lean();
    const roomIds = memberships.map((membership) => membership.roomId);
    const roomDocs = await RoomModel.find({ _id: { $in: roomIds } }).lean();
    const roomsById = new Map(roomDocs.map((room) => [String(room._id), room]));

    const directRooms = roomDocs.filter((room) => room.type === 'direct');
    const directRoomIds = directRooms.map((room) => room._id);

    const directMemberships =
      directRoomIds.length > 0
        ? await MembershipModel.find({ roomId: { $in: directRoomIds }, userId: { $ne: userId } }, { roomId: 1, userId: 1 }).lean()
        : [];

    const directUserIds = directMemberships.map((membership) => String(membership.userId));
    const directUsers =
      directUserIds.length > 0
        ? await UserModel.find({ _id: { $in: directUserIds } }, { name: 1, emailAddress: 1 }).lean()
        : [];

    const usersById = new Map(directUsers.map((user) => [String(user._id), user]));
    const directNamesByRoomId = new Map<string, string[]>();

    for (const membership of directMemberships) {
      const roomId = String(membership.roomId);
      const user = usersById.get(String(membership.userId));
      const previous = directNamesByRoomId.get(roomId) ?? [];
      previous.push(user?.name ?? 'Direct');
      directNamesByRoomId.set(roomId, previous);
    }

    const rooms = memberships
      .map((membership) => {
        const room = roomsById.get(String(membership.roomId));
        if (!room) {
          return null;
        }

        const base = serializeRoom(room);
        const directName =
          room.type === 'direct'
            ? (directNamesByRoomId.get(String(room._id)) ?? []).join(', ') || 'Direct'
            : null;

        return {
          ...base,
          name: directName ?? base.name,
          involvement: membership.involvement,
          unreadAt: membership.unreadAt
        };
      })
      .filter((room): room is NonNullable<typeof room> => room !== null);

    return { rooms };
  });

  app.post('/', { preHandler: app.authenticate }, async (request, reply) => {
    const userId = request.authUserId;
    if (!userId) {
      return reply.code(401).send({ error: 'Unauthorized' });
    }

    const payload = createRoomSchema.parse(request.body);
    const account = await getOrCreateAccount();

    if (account.settings?.restrictRoomCreationToAdministrators && !(await isAdmin(userId))) {
      return reply.code(403).send({ error: 'Forbidden' });
    }

    const room = await RoomModel.create({
      name: payload.name,
      type: payload.type,
      creatorId: userId
    });

    const uniqueUserIds = new Set<string>([userId, ...payload.userIds]);
    await MembershipModel.insertMany(
      Array.from(uniqueUserIds).map((memberUserId) => ({
        roomId: room._id,
        userId: memberUserId,
        involvement: 'mentions'
      })),
      { ordered: false }
    );

    const responseRoom = serializeRoom(room);

    await publishRealtimeEvent({
      type: 'room.created',
      roomId: responseRoom.id,
      payload: { room: responseRoom },
      userIds: Array.from(uniqueUserIds)
    });

    return reply.code(201).send({ room: responseRoom });
  });

  app.delete('/:roomId', { preHandler: app.authenticate }, async (request, reply) => {
    const userId = request.authUserId;
    if (!userId) {
      return reply.code(401).send({ error: 'Unauthorized' });
    }

    const { roomId } = request.params as { roomId: string };
    const result = await removeRoomForUser(userId, roomId);
    if ('error' in result) {
      if (result.error === 'invalid_room_id') {
        return reply.code(400).send({ error: 'Invalid room id' });
      }
      if (result.error === 'not_found') {
        return reply.code(404).send({ error: 'Room not found' });
      }
      return reply.code(403).send({ error: 'Forbidden' });
    }

    return reply.code(204).send();
  });

  app.get('/opens', { preHandler: app.authenticate }, async (request, reply) => {
    const userId = request.authUserId;
    if (!userId) {
      return reply.code(401).send({ error: 'Unauthorized' });
    }

    const memberships = await MembershipModel.find({ userId }, { roomId: 1 }).lean();
    const roomIds = memberships.map((membership) => membership.roomId);
    const rooms = await RoomModel.find({ _id: { $in: roomIds }, type: 'open' }).sort({ name: 1 }).lean();

    return {
      rooms: rooms.map((room) => serializeRoom(room))
    };
  });

  app.get('/closeds', { preHandler: app.authenticate }, async (request, reply) => {
    const userId = request.authUserId;
    if (!userId) {
      return reply.code(401).send({ error: 'Unauthorized' });
    }

    const memberships = await MembershipModel.find({ userId }, { roomId: 1 }).lean();
    const roomIds = memberships.map((membership) => membership.roomId);
    const rooms = await RoomModel.find({ _id: { $in: roomIds }, type: 'closed' }).sort({ name: 1 }).lean();

    return {
      rooms: rooms.map((room) => serializeRoom(room))
    };
  });

  app.get('/directs', { preHandler: app.authenticate }, async (request, reply) => {
    const userId = request.authUserId;
    if (!userId) {
      return reply.code(401).send({ error: 'Unauthorized' });
    }

    const memberships = await MembershipModel.find({ userId }, { roomId: 1 }).lean();
    const roomIds = memberships.map((membership) => membership.roomId);
    const rooms = await RoomModel.find({ _id: { $in: roomIds }, type: 'direct' }).sort({ updatedAt: -1 }).lean();

    return {
      rooms: rooms.map((room) => serializeRoom(room))
    };
  });

  app.get('/opens/new', { preHandler: app.authenticate }, async (request, reply) => {
    const userId = request.authUserId;
    if (!userId) {
      return reply.code(401).send({ error: 'Unauthorized' });
    }

    const account = await getOrCreateAccount();
    if (account.settings?.restrictRoomCreationToAdministrators && !(await isAdmin(userId))) {
      return reply.code(403).send({ error: 'Forbidden' });
    }

    const users = await UserModel.find({ status: 'active' }, { name: 1 }).sort({ name: 1 }).lean();
    return {
      room: {
        name: 'New room',
        type: 'open'
      },
      users: users.map((user) => ({
        id: String(user._id),
        name: user.name
      }))
    };
  });

  app.get('/closeds/new', { preHandler: app.authenticate }, async (request, reply) => {
    const userId = request.authUserId;
    if (!userId) {
      return reply.code(401).send({ error: 'Unauthorized' });
    }

    const account = await getOrCreateAccount();
    if (account.settings?.restrictRoomCreationToAdministrators && !(await isAdmin(userId))) {
      return reply.code(403).send({ error: 'Forbidden' });
    }

    const users = await UserModel.find({ status: 'active' }, { name: 1 }).sort({ name: 1 }).lean();
    return {
      room: {
        name: 'New room',
        type: 'closed'
      },
      users: users.map((user) => ({
        id: String(user._id),
        name: user.name
      }))
    };
  });

  app.get('/directs/new', { preHandler: app.authenticate }, async (request, reply) => {
    const userId = request.authUserId;
    if (!userId) {
      return reply.code(401).send({ error: 'Unauthorized' });
    }

    const users = await UserModel.find({ _id: { $ne: userId }, status: 'active' }, { name: 1 }).sort({ name: 1 }).lean();
    return {
      users: users.map((user) => ({
        id: String(user._id),
        name: user.name
      }))
    };
  });

  app.get('/opens/:id', { preHandler: app.authenticate }, async (request, reply) => {
    const { id } = request.params as { id: string };
    return reply.redirect(`/rooms/${id}`);
  });

  app.get('/closeds/:id', { preHandler: app.authenticate }, async (request, reply) => {
    const { id } = request.params as { id: string };
    return reply.redirect(`/rooms/${id}`);
  });

  app.get('/directs/:id', { preHandler: app.authenticate }, async (request, reply) => {
    const { id } = request.params as { id: string };
    return reply.redirect(`/rooms/${id}`);
  });

  app.get('/opens/:id/edit', { preHandler: app.authenticate }, async (request, reply) => {
    const userId = request.authUserId;
    if (!userId) {
      return reply.code(401).send({ error: 'Unauthorized' });
    }

    const { id } = request.params as { id: string };
    const access = await ensureRoomAccessForUser(userId, id);
    if ('error' in access) {
      if (access.error === 'invalid_room_id') {
        return reply.code(400).send({ error: 'Invalid room id' });
      }
      if (access.error === 'not_found') {
        return reply.code(404).send({ error: 'Room not found' });
      }
      return reply.code(403).send({ error: 'Forbidden' });
    }

    if (!(await canAdministerRecord(userId, access.room.creatorId))) {
      return reply.code(403).send({ error: 'Forbidden' });
    }

    const users = await UserModel.find({ status: 'active' }, { name: 1 }).sort({ name: 1 }).lean();
    return {
      room: serializeRoom(access.room.toObject() as Parameters<typeof serializeRoom>[0]),
      users: users.map((user) => ({
        id: String(user._id),
        name: user.name
      }))
    };
  });

  app.get('/closeds/:id/edit', { preHandler: app.authenticate }, async (request, reply) => {
    const userId = request.authUserId;
    if (!userId) {
      return reply.code(401).send({ error: 'Unauthorized' });
    }

    const { id } = request.params as { id: string };
    const access = await ensureRoomAccessForUser(userId, id);
    if ('error' in access) {
      if (access.error === 'invalid_room_id') {
        return reply.code(400).send({ error: 'Invalid room id' });
      }
      if (access.error === 'not_found') {
        return reply.code(404).send({ error: 'Room not found' });
      }
      return reply.code(403).send({ error: 'Forbidden' });
    }

    if (!(await canAdministerRecord(userId, access.room.creatorId))) {
      return reply.code(403).send({ error: 'Forbidden' });
    }

    const memberships = await MembershipModel.find({ roomId: access.room._id }, { userId: 1 }).lean();
    const selectedIds = new Set(memberships.map((membership) => String(membership.userId)));
    const users = await UserModel.find({ status: 'active' }, { name: 1 }).sort({ name: 1 }).lean();

    return {
      room: serializeRoom(access.room.toObject() as Parameters<typeof serializeRoom>[0]),
      selectedUsers: users
        .filter((user) => selectedIds.has(String(user._id)))
        .map((user) => ({ id: String(user._id), name: user.name })),
      unselectedUsers: users
        .filter((user) => !selectedIds.has(String(user._id)))
        .map((user) => ({ id: String(user._id), name: user.name }))
    };
  });

  app.get('/directs/:id/edit', { preHandler: app.authenticate }, async (request, reply) => {
    const userId = request.authUserId;
    if (!userId) {
      return reply.code(401).send({ error: 'Unauthorized' });
    }

    const { id } = request.params as { id: string };
    const access = await ensureRoomAccessForUser(userId, id);
    if ('error' in access) {
      if (access.error === 'invalid_room_id') {
        return reply.code(400).send({ error: 'Invalid room id' });
      }
      if (access.error === 'not_found') {
        return reply.code(404).send({ error: 'Room not found' });
      }
      return reply.code(403).send({ error: 'Forbidden' });
    }

    const memberships = await MembershipModel.find({ roomId: access.room._id }, { userId: 1 }).lean();
    const userIds = memberships.map((membership) => membership.userId);
    const users = userIds.length > 0 ? await UserModel.find({ _id: { $in: userIds } }, { name: 1 }).sort({ name: 1 }).lean() : [];

    return {
      room: serializeRoom(access.room.toObject() as Parameters<typeof serializeRoom>[0]),
      users: users.map((user) => ({
        id: String(user._id),
        name: user.name
      }))
    };
  });

  app.delete('/opens/:id', { preHandler: app.authenticate }, async (request, reply) => {
    const userId = request.authUserId;
    if (!userId) {
      return reply.code(401).send({ error: 'Unauthorized' });
    }

    const { id } = request.params as { id: string };
    const result = await removeRoomForUser(userId, id);
    if ('error' in result) {
      if (result.error === 'invalid_room_id') {
        return reply.code(400).send({ error: 'Invalid room id' });
      }
      if (result.error === 'not_found') {
        return reply.code(404).send({ error: 'Room not found' });
      }
      return reply.code(403).send({ error: 'Forbidden' });
    }

    return reply.code(204).send();
  });

  app.delete('/closeds/:id', { preHandler: app.authenticate }, async (request, reply) => {
    const userId = request.authUserId;
    if (!userId) {
      return reply.code(401).send({ error: 'Unauthorized' });
    }

    const { id } = request.params as { id: string };
    const result = await removeRoomForUser(userId, id);
    if ('error' in result) {
      if (result.error === 'invalid_room_id') {
        return reply.code(400).send({ error: 'Invalid room id' });
      }
      if (result.error === 'not_found') {
        return reply.code(404).send({ error: 'Room not found' });
      }
      return reply.code(403).send({ error: 'Forbidden' });
    }

    return reply.code(204).send();
  });

  app.delete('/directs/:id', { preHandler: app.authenticate }, async (request, reply) => {
    const userId = request.authUserId;
    if (!userId) {
      return reply.code(401).send({ error: 'Unauthorized' });
    }

    const { id } = request.params as { id: string };
    const result = await removeRoomForUser(userId, id);
    if ('error' in result) {
      if (result.error === 'invalid_room_id') {
        return reply.code(400).send({ error: 'Invalid room id' });
      }
      if (result.error === 'not_found') {
        return reply.code(404).send({ error: 'Room not found' });
      }
      return reply.code(403).send({ error: 'Forbidden' });
    }

    return reply.code(204).send();
  });

  app.post('/directs', { preHandler: app.authenticate }, async (request, reply) => {
    const actorId = request.authUserId;
    if (!actorId) {
      return reply.code(401).send({ error: 'Unauthorized' });
    }

    const payload = createDirectSchema.parse(request.body);
    const requestedIds = normalizeUserIds([
      ...(payload.userIds ?? []),
      ...(payload.user_ids ?? []),
      payload.userId ?? ''
    ]);

    const memberIds = normalizeUserIds([actorId, ...requestedIds]);
    if (memberIds.length < 2) {
      return reply.code(422).send({ error: 'Cannot create direct room with yourself' });
    }

    const targetIds = memberIds.filter((id) => id !== actorId);
    const targetUsers = await UserModel.find({ _id: { $in: targetIds } }, { name: 1 }).lean();

    if (targetUsers.length !== targetIds.length) {
      return reply.code(404).send({ error: 'Target user not found' });
    }

    const directKey = createDirectKey(memberIds);
    const existingRoom = await RoomModel.findOne({ type: 'direct', directKey });

    const room =
      existingRoom ??
      (await RoomModel.create({
        type: 'direct',
        creatorId: actorId,
        name: '',
        directKey
      }));

    if (!existingRoom) {
      await MembershipModel.insertMany(
        memberIds.map((memberUserId) => ({
          roomId: room._id,
          userId: memberUserId,
          involvement: 'everything'
        })),
        { ordered: false }
      );

      await publishRealtimeEvent({
        type: 'room.created',
        roomId: String(room._id),
        payload: {
          room: {
            ...serializeRoom(room.toObject() as Parameters<typeof serializeRoom>[0]),
            name: targetUsers.map((user) => user.name).join(', ') || 'Direct'
          }
        },
        userIds: memberIds
      });
    }

    return reply.code(201).send({
      room: {
        ...serializeRoom(room.toObject() as Parameters<typeof serializeRoom>[0]),
        name: targetUsers.map((user) => user.name).join(', ') || 'Direct'
      }
    });
  });

  app.post('/opens', { preHandler: app.authenticate }, async (request, reply) => {
    const actorId = request.authUserId;
    if (!actorId) {
      return reply.code(401).send({ error: 'Unauthorized' });
    }

    const account = await getOrCreateAccount();
    if (account.settings?.restrictRoomCreationToAdministrators && !(await isAdmin(actorId))) {
      return reply.code(403).send({ error: 'Forbidden' });
    }

    const payload = parseOpenOrClosedPayload(request.body);

    const room = await RoomModel.create({
      name: payload.name,
      type: 'open',
      creatorId: actorId
    });

    const activeUsers = await UserModel.find({ status: 'active' }, { _id: 1 }).lean();
    const memberIds = normalizeUserIds(activeUsers.map((user) => String(user._id)));

    await grantRoomMemberships({
      roomId: room._id,
      userIds: memberIds,
      involvement: 'mentions'
    });

    await publishRealtimeEvent({
      type: 'room.created',
      roomId: String(room._id),
      payload: { room: serializeRoom(room.toObject() as Parameters<typeof serializeRoom>[0]) },
      userIds: memberIds
    });

    return reply.code(201).send({
      room: serializeRoom(room.toObject() as Parameters<typeof serializeRoom>[0])
    });
  });

  app.patch('/opens/:id', { preHandler: app.authenticate }, async (request, reply) => {
    const actorId = request.authUserId;
    if (!actorId) {
      return reply.code(401).send({ error: 'Unauthorized' });
    }

    const { id } = request.params as { id: string };
    const roomObjectId = asObjectId(id);
    if (!roomObjectId) {
      return reply.code(400).send({ error: 'Invalid room id' });
    }

    const [membership, room] = await Promise.all([
      MembershipModel.findOne({ roomId: roomObjectId, userId: actorId }).lean(),
      RoomModel.findById(roomObjectId)
    ]);

    if (!membership) {
      return reply.code(403).send({ error: 'You are not a room member' });
    }

    if (!room) {
      return reply.code(404).send({ error: 'Room not found' });
    }

    if (!(await canAdministerRecord(actorId, room.creatorId))) {
      return reply.code(403).send({ error: 'Forbidden' });
    }

    const payload = parseOpenOrClosedPayload(request.body);
    const previousType = room.type;

    room.name = payload.name;
    room.type = 'open';
    await room.save();

    if (previousType !== 'open') {
      const [activeUsers, existingMemberships] = await Promise.all([
        UserModel.find({ status: 'active' }, { _id: 1 }).lean(),
        MembershipModel.find({ roomId: room._id }, { userId: 1 }).lean()
      ]);

      const activeUserIds = normalizeUserIds(activeUsers.map((user) => String(user._id)));
      const existingUserIds = new Set(existingMemberships.map((item) => String(item.userId)));
      const grantedUserIds = activeUserIds.filter((id) => !existingUserIds.has(id));

      await grantRoomMemberships({
        roomId: room._id,
        userIds: grantedUserIds,
        involvement: 'mentions'
      });

      if (grantedUserIds.length > 0) {
        await publishRealtimeEvent({
          type: 'room.created',
          roomId: String(room._id),
          payload: { room: serializeRoom(room.toObject() as Parameters<typeof serializeRoom>[0]) },
          userIds: grantedUserIds
        });
      }
    }

    return {
      room: serializeRoom(room.toObject() as Parameters<typeof serializeRoom>[0])
    };
  });

  app.post('/closeds', { preHandler: app.authenticate }, async (request, reply) => {
    const actorId = request.authUserId;
    if (!actorId) {
      return reply.code(401).send({ error: 'Unauthorized' });
    }

    const account = await getOrCreateAccount();
    if (account.settings?.restrictRoomCreationToAdministrators && !(await isAdmin(actorId))) {
      return reply.code(403).send({ error: 'Forbidden' });
    }

    const payload = parseOpenOrClosedPayload(request.body);
    const room = await RoomModel.create({
      name: payload.name,
      type: 'closed',
      creatorId: actorId
    });

    const candidateIds = normalizeUserIds([actorId, ...payload.userIds]);
    const existingUsers = await UserModel.find({ _id: { $in: candidateIds }, status: 'active' }, { _id: 1 }).lean();
    const memberIds = normalizeUserIds(existingUsers.map((user) => String(user._id)));

    await grantRoomMemberships({
      roomId: room._id,
      userIds: memberIds,
      involvement: 'mentions'
    });

    await publishRealtimeEvent({
      type: 'room.created',
      roomId: String(room._id),
      payload: { room: serializeRoom(room.toObject() as Parameters<typeof serializeRoom>[0]) },
      userIds: memberIds
    });

    return reply.code(201).send({
      room: serializeRoom(room.toObject() as Parameters<typeof serializeRoom>[0])
    });
  });

  app.patch('/closeds/:id', { preHandler: app.authenticate }, async (request, reply) => {
    const actorId = request.authUserId;
    if (!actorId) {
      return reply.code(401).send({ error: 'Unauthorized' });
    }

    const { id } = request.params as { id: string };
    const roomObjectId = asObjectId(id);
    if (!roomObjectId) {
      return reply.code(400).send({ error: 'Invalid room id' });
    }

    const [membership, room] = await Promise.all([
      MembershipModel.findOne({ roomId: roomObjectId, userId: actorId }).lean(),
      RoomModel.findById(roomObjectId)
    ]);

    if (!membership) {
      return reply.code(403).send({ error: 'You are not a room member' });
    }

    if (!room) {
      return reply.code(404).send({ error: 'Room not found' });
    }

    if (!(await canAdministerRecord(actorId, room.creatorId))) {
      return reply.code(403).send({ error: 'Forbidden' });
    }

    const payload = parseOpenOrClosedPayload(request.body);
    const candidateIds = normalizeUserIds([actorId, ...payload.userIds]);
    const existingUsers = await UserModel.find({ _id: { $in: candidateIds }, status: 'active' }, { _id: 1 }).lean();
    const targetMemberIds = normalizeUserIds(existingUsers.map((user) => String(user._id)));

    const existingMemberships = await MembershipModel.find({ roomId: room._id }, { userId: 1 }).lean();
    const existingMemberIds = normalizeUserIds(existingMemberships.map((item) => String(item.userId)));

    const existingSet = new Set(existingMemberIds);
    const targetSet = new Set(targetMemberIds);

    const grantedUserIds = targetMemberIds.filter((userId) => !existingSet.has(userId));
    const revokedUserIds = existingMemberIds.filter((userId) => !targetSet.has(userId));

    room.name = payload.name;
    room.type = 'closed';
    await room.save();

    await Promise.all([
      grantRoomMemberships({
        roomId: room._id,
        userIds: grantedUserIds,
        involvement: 'mentions'
      }),
      revokedUserIds.length > 0
        ? MembershipModel.deleteMany({ roomId: room._id, userId: { $in: revokedUserIds } })
        : Promise.resolve()
    ]);

    if (grantedUserIds.length > 0) {
      await publishRealtimeEvent({
        type: 'room.created',
        roomId: String(room._id),
        payload: { room: serializeRoom(room.toObject() as Parameters<typeof serializeRoom>[0]) },
        userIds: grantedUserIds
      });
    }

    if (revokedUserIds.length > 0) {
      await publishRealtimeEvent({
        type: 'room.removed',
        roomId: String(room._id),
        payload: { roomId: String(room._id) },
        userIds: revokedUserIds
      });

      for (const revokedUserId of revokedUserIds) {
        disconnectUser(revokedUserId, {
          reason: 'membership_revoked',
          reconnect: true
        });
      }
    }

    return {
      room: serializeRoom(room.toObject() as Parameters<typeof serializeRoom>[0])
    };
  });

  app.get('/:roomId/@:messageId', { preHandler: app.authenticate }, async (request, reply) => {
    const userId = request.authUserId;
    if (!userId) {
      return reply.code(401).send({ error: 'Unauthorized' });
    }

    const { roomId, messageId } = request.params as { roomId: string; messageId: string };
    const roomObjectId = asObjectId(roomId);
    const messageObjectId = asObjectId(messageId);

    if (!roomObjectId || !messageObjectId) {
      return reply.code(400).send({ error: 'Invalid id' });
    }

    const [membership, room, anchor] = await Promise.all([
      MembershipModel.findOne({ roomId: roomObjectId, userId }).lean(),
      RoomModel.findById(roomObjectId).lean(),
      MessageModel.findOne({ _id: messageObjectId, roomId: roomObjectId }).lean()
    ]);

    if (!membership) {
      return reply.code(403).send({ error: 'You are not a room member' });
    }

    if (!room) {
      return reply.code(404).send({ error: 'Room not found' });
    }

    if (!anchor) {
      return reply.code(404).send({ error: 'Message not found' });
    }

    const [beforeMessages, afterMessages] = await Promise.all([
      MessageModel.find({
        roomId: roomObjectId,
        createdAt: { $lt: anchor.createdAt }
      })
        .sort({ createdAt: -1 })
        .limit(MESSAGE_PAGE_SIZE)
        .lean(),
      MessageModel.find({
        roomId: roomObjectId,
        createdAt: { $gt: anchor.createdAt }
      })
        .sort({ createdAt: 1 })
        .limit(MESSAGE_PAGE_SIZE)
        .lean()
    ]);

    const messages = [...beforeMessages.reverse(), anchor, ...afterMessages];
    rememberLastRoom(reply, roomId);

    return {
      room: serializeRoom(room),
      messages: await serializeMessages(messages)
    };
  });

  app.get('/:roomId', { preHandler: app.authenticate }, async (request, reply) => {
    const userId = request.authUserId;
    if (!userId) {
      return reply.code(401).send({ error: 'Unauthorized' });
    }

    const { roomId } = request.params as { roomId: string };
    const roomObjectId = asObjectId(roomId);
    if (!roomObjectId) {
      return reply.code(400).send({ error: 'Invalid room id' });
    }

    const [membership, room] = await Promise.all([
      MembershipModel.findOne({ roomId: roomObjectId, userId }).lean(),
      RoomModel.findById(roomObjectId).lean()
    ]);

    if (!membership) {
      return reply.code(403).send({ error: 'You are not a room member' });
    }

    if (!room) {
      return reply.code(404).send({ error: 'Room not found' });
    }

    const messages = (
      await MessageModel.find({ roomId: roomObjectId })
        .sort({ createdAt: -1 })
        .limit(MESSAGE_PAGE_SIZE)
        .lean()
    ).reverse();
    rememberLastRoom(reply, roomId);

    return {
      room: serializeRoom(room),
      messages: await serializeMessages(messages)
    };
  });

  app.get('/:roomId/settings', { preHandler: app.authenticate }, async (request, reply) => {
    const userId = request.authUserId;
    if (!userId) {
      return reply.code(401).send({ error: 'Unauthorized' });
    }

    const { roomId } = request.params as { roomId: string };
    const roomObjectId = asObjectId(roomId);
    if (!roomObjectId) {
      return reply.code(400).send({ error: 'Invalid room id' });
    }

    const [membership, room] = await Promise.all([
      MembershipModel.findOne({ roomId: roomObjectId, userId }).lean(),
      RoomModel.findById(roomObjectId).lean()
    ]);

    if (!membership) {
      return reply.code(403).send({ error: 'You are not a room member' });
    }

    if (!room) {
      return reply.code(404).send({ error: 'Room not found' });
    }

    return {
      room: serializeRoom(room),
      involvement: membership.involvement,
      canAdminister: await canAdministerRecord(userId, room.creatorId)
    };
  });

  app.get('/:roomId/involvement', { preHandler: app.authenticate }, async (request, reply) => {
    const userId = request.authUserId;
    if (!userId) {
      return reply.code(401).send({ error: 'Unauthorized' });
    }

    const { roomId } = request.params as { roomId: string };
    const roomObjectId = asObjectId(roomId);
    if (!roomObjectId) {
      return reply.code(400).send({ error: 'Invalid room id' });
    }

    const membership = await MembershipModel.findOne({ roomId: roomObjectId, userId }).lean();
    if (!membership) {
      return reply.code(403).send({ error: 'You are not a room member' });
    }

    return { involvement: membership.involvement };
  });

  const updateInvolvementHandler: RouteHandlerMethod = async (request, reply) => {
    const userId = request.authUserId;
    if (!userId) {
      return reply.code(401).send({ error: 'Unauthorized' });
    }

    const { roomId } = request.params as { roomId: string };
    const roomObjectId = asObjectId(roomId);
    if (!roomObjectId) {
      return reply.code(400).send({ error: 'Invalid room id' });
    }

    const raw = {
      involvement:
        (request.body as { involvement?: string } | undefined)?.involvement ??
        (request.query as { involvement?: string } | undefined)?.involvement
    };
    const payload = updateInvolvementSchema.parse(raw);

    const membership = await MembershipModel.findOne({ roomId: roomObjectId, userId });
    if (!membership) {
      return reply.code(403).send({ error: 'You are not a room member' });
    }

    const previous = membership.involvement;
    membership.involvement = payload.involvement;
    await membership.save();

    const room = await RoomModel.findById(roomObjectId).lean();

    if (room && room.type !== 'direct') {
      if (membership.involvement === 'invisible' && previous !== 'invisible') {
        await publishRealtimeEvent({
          type: 'room.removed',
          roomId,
          payload: { roomId },
          userIds: [userId]
        });
      } else if (previous === 'invisible' && membership.involvement !== 'invisible') {
        await publishRealtimeEvent({
          type: 'room.created',
          roomId,
          payload: { room: serializeRoom(room) },
          userIds: [userId]
        });
      }
    }

    return { involvement: membership.involvement };
  };

  app.patch('/:roomId/involvement', { preHandler: app.authenticate }, updateInvolvementHandler);
  app.post('/:roomId/involvement', { preHandler: app.authenticate }, updateInvolvementHandler);

  app.get('/:roomId/refresh', { preHandler: app.authenticate }, async (request, reply) => {
    const userId = request.authUserId;
    if (!userId) {
      return reply.code(401).send({ error: 'Unauthorized' });
    }

    const { roomId } = request.params as { roomId: string };
    const roomObjectId = asObjectId(roomId);
    if (!roomObjectId) {
      return reply.code(400).send({ error: 'Invalid room id' });
    }

    const membership = await MembershipModel.findOne({ roomId: roomObjectId, userId }).lean();
    if (!membership) {
      return reply.code(403).send({ error: 'You are not a room member' });
    }

    const sinceMs = Number((request.query as { since?: string | number } | undefined)?.since ?? 0);
    const since = Number.isFinite(sinceMs) ? new Date(Math.max(0, sinceMs)) : new Date(0);

    const newMessages = await MessageModel.find({
      roomId: roomObjectId,
      createdAt: { $gt: since }
    })
      .sort({ createdAt: 1 })
      .limit(MESSAGE_PAGE_SIZE)
      .lean();

    const newMessageIds = newMessages.map((message) => message._id);
    const updatedMessages = (
      await MessageModel.find({
        roomId: roomObjectId,
        updatedAt: { $gt: since },
        _id: { $nin: newMessageIds }
      })
        .sort({ createdAt: -1 })
        .limit(MESSAGE_PAGE_SIZE)
        .lean()
    ).reverse();

    return {
      new_messages: await serializeMessages(newMessages),
      updated_messages: await serializeMessages(updatedMessages)
    };
  });

  app.get('/:roomId/messages', { preHandler: app.authenticate }, async (request, reply) => {
    const userId = request.authUserId;
    if (!userId) {
      return reply.code(401).send({ error: 'Unauthorized' });
    }

    const { roomId } = request.params as { roomId: string };
    const roomObjectId = asObjectId(roomId);
    if (!roomObjectId) {
      return reply.code(400).send({ error: 'Invalid room id' });
    }

    const membership = await MembershipModel.findOne({ roomId: roomObjectId, userId }).lean();
    if (!membership) {
      return reply.code(403).send({ error: 'You are not a room member' });
    }

    const { before, after } = request.query as { before?: string; after?: string };

    let messages;

    if (before) {
      const beforeObjectId = asObjectId(before);
      if (!beforeObjectId) {
        return reply.code(400).send({ error: 'Invalid before message id' });
      }

      const beforeMessage = await MessageModel.findOne({ _id: beforeObjectId, roomId: roomObjectId }, { createdAt: 1 }).lean();
      if (!beforeMessage) {
        return reply.code(404).send({ error: 'Reference message not found' });
      }

      messages = (
        await MessageModel.find({
          roomId: roomObjectId,
          createdAt: { $lt: beforeMessage.createdAt }
        })
          .sort({ createdAt: -1 })
          .limit(MESSAGE_PAGE_SIZE)
          .lean()
      ).reverse();
    } else if (after) {
      const afterObjectId = asObjectId(after);
      if (!afterObjectId) {
        return reply.code(400).send({ error: 'Invalid after message id' });
      }

      const afterMessage = await MessageModel.findOne({ _id: afterObjectId, roomId: roomObjectId }, { createdAt: 1 }).lean();
      if (!afterMessage) {
        return reply.code(404).send({ error: 'Reference message not found' });
      }

      messages = await MessageModel.find({
        roomId: roomObjectId,
        createdAt: { $gt: afterMessage.createdAt }
      })
        .sort({ createdAt: 1 })
        .limit(MESSAGE_PAGE_SIZE)
        .lean();
    } else {
      messages = (
        await MessageModel.find({ roomId: roomObjectId })
          .sort({ createdAt: -1 })
          .limit(MESSAGE_PAGE_SIZE)
          .lean()
      ).reverse();
    }

    const serializedMessages = await serializeMessages(messages);

    if (serializedMessages.length === 0 && !isApiPath(request)) {
      return reply.code(204).send();
    }

    return {
      messages: serializedMessages
    };
  });

  app.get('/:roomId/messages/:messageId', { preHandler: app.authenticate }, async (request, reply) => {
    const userId = request.authUserId;
    if (!userId) {
      return reply.code(401).send({ error: 'Unauthorized' });
    }

    const { roomId, messageId } = request.params as { roomId: string; messageId: string };
    const roomObjectId = asObjectId(roomId);
    const messageObjectId = asObjectId(messageId);

    if (!roomObjectId || !messageObjectId) {
      return reply.code(400).send({ error: 'Invalid id' });
    }

    const membership = await MembershipModel.findOne({ roomId: roomObjectId, userId }).lean();
    if (!membership) {
      return reply.code(403).send({ error: 'You are not a room member' });
    }

    const message = await MessageModel.findOne({ _id: messageObjectId, roomId: roomObjectId }).lean();
    if (!message) {
      return reply.code(404).send({ error: 'Message not found' });
    }

    const [serialized] = await serializeMessages([message]);
    return { message: serialized };
  });

  app.patch('/:roomId/messages/:messageId', { preHandler: app.authenticate }, async (request, reply) => {
    const userId = request.authUserId;
    if (!userId) {
      return reply.code(401).send({ error: 'Unauthorized' });
    }

    const { roomId, messageId } = request.params as { roomId: string; messageId: string };
    const roomObjectId = asObjectId(roomId);
    const messageObjectId = asObjectId(messageId);

    if (!roomObjectId || !messageObjectId) {
      return reply.code(400).send({ error: 'Invalid id' });
    }

    const membership = await MembershipModel.findOne({ roomId: roomObjectId, userId }).lean();
    if (!membership) {
      return reply.code(403).send({ error: 'You are not a room member' });
    }

    const message = await MessageModel.findOne({ _id: messageObjectId, roomId: roomObjectId });
    if (!message) {
      return reply.code(404).send({ error: 'Message not found' });
    }

    if (!(await canAdministerRecord(userId, message.creatorId))) {
      return reply.code(403).send({ error: 'Forbidden' });
    }

    const payload = parseMessagePayload(request.body);

    message.body = payload.body;
    if (payload.clientMessageId) {
      message.clientMessageId = payload.clientMessageId;
    }

    await message.save();

    const [responseMessage] = await serializeMessages([
      message.toObject() as Parameters<typeof serializeMessages>[0][number]
    ]);

    await publishRealtimeEvent({
      type: 'message.updated',
      roomId,
      payload: {
        message: responseMessage
      }
    });

    return { message: responseMessage };
  });

  app.put('/:roomId/messages/:messageId', { preHandler: app.authenticate }, async (request, reply) => {
    const userId = request.authUserId;
    if (!userId) {
      return reply.code(401).send({ error: 'Unauthorized' });
    }

    const { roomId, messageId } = request.params as { roomId: string; messageId: string };
    const roomObjectId = asObjectId(roomId);
    const messageObjectId = asObjectId(messageId);

    if (!roomObjectId || !messageObjectId) {
      return reply.code(400).send({ error: 'Invalid id' });
    }

    const membership = await MembershipModel.findOne({ roomId: roomObjectId, userId }).lean();
    if (!membership) {
      return reply.code(403).send({ error: 'You are not a room member' });
    }

    const message = await MessageModel.findOne({ _id: messageObjectId, roomId: roomObjectId });
    if (!message) {
      return reply.code(404).send({ error: 'Message not found' });
    }

    if (!(await canAdministerRecord(userId, message.creatorId))) {
      return reply.code(403).send({ error: 'Forbidden' });
    }

    const payload = parseMessagePayload(request.body);

    message.body = payload.body;
    if (payload.clientMessageId) {
      message.clientMessageId = payload.clientMessageId;
    }

    await message.save();

    const [responseMessage] = await serializeMessages([
      message.toObject() as Parameters<typeof serializeMessages>[0][number]
    ]);

    await publishRealtimeEvent({
      type: 'message.updated',
      roomId,
      payload: {
        message: responseMessage
      }
    });

    return { message: responseMessage };
  });

  app.delete('/:roomId/messages/:messageId', { preHandler: app.authenticate }, async (request, reply) => {
    const userId = request.authUserId;
    if (!userId) {
      return reply.code(401).send({ error: 'Unauthorized' });
    }

    const { roomId, messageId } = request.params as { roomId: string; messageId: string };
    const roomObjectId = asObjectId(roomId);
    const messageObjectId = asObjectId(messageId);

    if (!roomObjectId || !messageObjectId) {
      return reply.code(400).send({ error: 'Invalid id' });
    }

    const membership = await MembershipModel.findOne({ roomId: roomObjectId, userId }).lean();
    if (!membership) {
      return reply.code(403).send({ error: 'You are not a room member' });
    }

    const message = await MessageModel.findOne({ _id: messageObjectId, roomId: roomObjectId }).lean();
    if (!message) {
      return reply.code(404).send({ error: 'Message not found' });
    }

    if (!(await canAdministerRecord(userId, message.creatorId))) {
      return reply.code(403).send({ error: 'Forbidden' });
    }

    await Promise.all([
      BoostModel.deleteMany({ messageId: messageObjectId }),
      MessageModel.deleteOne({ _id: messageObjectId })
    ]);

    await publishRealtimeEvent({
      type: 'message.removed',
      roomId,
      payload: {
        messageId,
        clientMessageId: message.clientMessageId
      }
    });

    return reply.code(204).send();
  });

  app.post('/:roomId/:botKey/messages', async (request, reply) => {
    const { roomId, botKey } = request.params as { roomId: string; botKey: string };
    const roomObjectId = asObjectId(roomId);

    if (!roomObjectId) {
      return reply.code(400).send({ error: 'Invalid room id' });
    }

    const auth = authenticateBotKey(botKey.trim());
    if (!auth) {
      return reply.code(401).send({ error: 'Invalid bot key' });
    }

    const bot = await UserModel.findOne({
      _id: auth.botId,
      botToken: auth.botToken,
      role: 'bot',
      status: 'active'
    }).lean();

    if (!bot) {
      return reply.code(401).send({ error: 'Invalid bot key' });
    }

    const membership = await MembershipModel.findOne({ roomId: roomObjectId, userId: bot._id }).lean();
    if (!membership) {
      return reply.code(403).send({ error: 'Bot is not a room member' });
    }

    let payload: ParsedMessageCreate;
    try {
      payload = await parseBotMessagePayload(request);
    } catch {
      return reply.code(422).send({ error: 'body or attachment is required' });
    }

    const message = await MessageModel.create({
      roomId: roomObjectId,
      creatorId: bot._id,
      body: payload.body,
      ...(payload.attachment ? { attachment: payload.attachment } : {}),
      ...(payload.clientMessageId ? { clientMessageId: payload.clientMessageId } : {})
    });

    const responseMessage = await handleMessageCreated({
      roomId: String(roomObjectId),
      messageId: String(message._id),
      creatorId: String(bot._id),
      enqueuePush: true,
      enqueueWebhook: true,
      publishUnread: true
    });

    if (!responseMessage) {
      return reply.code(500).send({ error: 'Unable to process bot message' });
    }

    await enqueueEligibleBotWebhooks({
      roomId: String(roomObjectId),
      messageId: String(message._id),
      creatorId: String(bot._id),
      body: message.body
    });

    return reply.code(201).send({ message: responseMessage });
  });

  app.post('/:roomId/messages', { preHandler: app.authenticate }, async (request, reply) => {
    const userId = request.authUserId;
    if (!userId) {
      return reply.code(401).send({ error: 'Unauthorized' });
    }

    const { roomId } = request.params as { roomId: string };
    const roomObjectId = asObjectId(roomId);
    if (!roomObjectId) {
      return reply.code(400).send({ error: 'Invalid room id' });
    }

    const membership = await MembershipModel.findOne({ roomId: roomObjectId, userId }).lean();
    if (!membership) {
      return reply.code(403).send({ error: 'You are not a room member' });
    }

    let payload: ParsedMessageCreate;
    try {
      payload = await parseMessageCreatePayload(request);
    } catch {
      return reply.code(422).send({ error: 'body or attachment is required' });
    }

    const message = await MessageModel.create({
      roomId: roomObjectId,
      creatorId: userId,
      body: payload.body,
      ...(payload.attachment ? { attachment: payload.attachment } : {}),
      ...(payload.clientMessageId ? { clientMessageId: payload.clientMessageId } : {})
    });

    const responseMessage = await handleMessageCreated({
      roomId: String(message.roomId),
      messageId: String(message._id),
      creatorId: userId,
      enqueuePush: true,
      enqueueWebhook: true,
      publishUnread: true
    });

    if (!responseMessage) {
      return reply.code(500).send({ error: 'Unable to process created message' });
    }

    await enqueueEligibleBotWebhooks({
      roomId: String(message.roomId),
      messageId: String(message._id),
      creatorId: userId,
      body: message.body
    });

    return reply.code(201).send({ message: responseMessage });
  });
};

export default roomsRoutes;
