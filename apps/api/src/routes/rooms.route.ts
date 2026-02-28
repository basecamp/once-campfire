import type { FastifyPluginAsync } from 'fastify';
import { z } from 'zod';
import { asObjectId } from '../lib/object-id.js';
import { MembershipModel } from '../models/membership.model.js';
import { MessageModel } from '../models/message.model.js';
import { RoomModel } from '../models/room.model.js';
import { UserModel } from '../models/user.model.js';
import { BoostModel } from '../models/boost.model.js';
import { publishRealtimeEvent } from '../realtime/redis-realtime.js';
import { enqueueEligibleBotWebhooks } from '../services/bot-dispatch.js';
import { handleMessageCreated } from '../services/message-events.js';

const createRoomSchema = z.object({
  name: z.string().min(2).max(80),
  type: z.enum(['open', 'closed']).default('open'),
  userIds: z.array(z.string()).default([])
});

const createDirectSchema = z.object({
  userId: z.string().min(1)
});

const createMessageSchema = z.object({
  body: z.string().min(1).max(4000)
});

function authenticateBotKey(botKey: string) {
  const [botId, botToken] = botKey.split('-');
  if (!botId || !botToken) {
    return null;
  }

  return { botId, botToken };
}

function createDirectKey(userA: string, userB: string) {
  return [userA, userB].sort().join(':');
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
    const directNameByRoomId = new Map(
      directMemberships.map((membership) => {
        const user = usersById.get(String(membership.userId));
        return [String(membership.roomId), user?.name ?? 'Direct'];
      })
    );

    const rooms = memberships
      .map((membership) => {
        const room = roomsById.get(String(membership.roomId));
        if (!room) {
          return null;
        }

        const base = serializeRoom(room);
        const directName = room.type === 'direct' ? directNameByRoomId.get(String(room._id)) : null;

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

  app.post('/directs', { preHandler: app.authenticate }, async (request, reply) => {
    const actorId = request.authUserId;
    if (!actorId) {
      return reply.code(401).send({ error: 'Unauthorized' });
    }

    const payload = createDirectSchema.parse(request.body);
    const targetUserId = payload.userId;

    if (targetUserId === actorId) {
      return reply.code(422).send({ error: 'Cannot create direct room with yourself' });
    }

    const targetUser = await UserModel.findById(targetUserId).lean();
    if (!targetUser) {
      return reply.code(404).send({ error: 'Target user not found' });
    }

    const directKey = createDirectKey(actorId, targetUserId);
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
        [actorId, targetUserId].map((memberUserId) => ({
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
            name: targetUser.name
          }
        },
        userIds: [actorId, targetUserId]
      });
    }

    return reply.code(201).send({
      room: {
        ...serializeRoom(room.toObject() as Parameters<typeof serializeRoom>[0]),
        name: targetUser.name
      }
    });
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

    const messages = await MessageModel.find({ roomId: roomObjectId }).sort({ createdAt: 1 }).limit(200).lean();
    const messageIds = messages.map((message) => message._id);

    const creatorIds = Array.from(new Set(messages.map((message) => String(message.creatorId))));
    const creators = await UserModel.find({ _id: { $in: creatorIds } }, { name: 1 }).lean();
    const creatorsById = new Map(creators.map((creator) => [String(creator._id), creator]));

    const boosts =
      messageIds.length > 0
        ? await BoostModel.find({ messageId: { $in: messageIds } }).sort({ createdAt: 1 }).lean()
        : [];

    const boostsByMessageId = new Map<string, typeof boosts>();
    for (const boost of boosts) {
      const key = String(boost.messageId);
      const prev = boostsByMessageId.get(key) ?? [];
      prev.push(boost);
      boostsByMessageId.set(key, prev);
    }

    return {
      messages: messages.map((message) => {
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
          createdAt: message.createdAt
        };
      })
    };
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

    const payloadBody =
      typeof request.body === 'string'
        ? request.body
        : createMessageSchema.parse(request.body).body;

    const normalizedBody = payloadBody.trim();
    if (!normalizedBody) {
      return reply.code(422).send({ error: 'Message body is required' });
    }

    const message = await MessageModel.create({
      roomId: roomObjectId,
      creatorId: bot._id,
      body: normalizedBody
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

    const payload = createMessageSchema.parse(request.body);

    const message = await MessageModel.create({
      roomId: roomObjectId,
      creatorId: userId,
      body: payload.body
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
