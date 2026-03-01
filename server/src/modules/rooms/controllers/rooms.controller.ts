import type { FastifyReply, FastifyRequest } from 'fastify';
import { Types } from 'mongoose';
import { MembershipModel } from '../models/membership.model.js';
import { RoomModel } from '../models/room.model.js';
import { MessageModel } from '../../messages/models/message.model.js';
import { asObjectId, ensureArrayString, getAuthUserId, parseLimit, sendData, sendError } from '../../../shared/utils/controller.js';

type RoomType = 'open' | 'closed' | 'direct';

function canAdminRoom(room: { creatorId: Types.ObjectId }, userId: string) {
  return String(room.creatorId) === userId;
}

async function ensureMembership(roomId: string, userId: string) {
  return MembershipModel.findOne({ roomId, userId }).lean();
}

export const roomsController = {
  async index(request: FastifyRequest, reply: FastifyReply) {
    try {
      const userId = getAuthUserId(request);
      const memberships = await MembershipModel.find({ userId, involvement: { $ne: 'invisible' } }, { roomId: 1, involvement: 1, unreadAt: 1 })
        .sort({ updatedAt: -1 })
        .lean();
      const roomIds = memberships.map((m) => m.roomId);
      const rooms = await RoomModel.find({ _id: { $in: roomIds } }).sort({ updatedAt: -1 }).lean();

      return sendData(request, reply, {
        rooms,
        memberships
      });
    } catch {
      return sendError(reply, 401, 'UNAUTHORIZED', 'Unauthorized');
    }
  },

  async show(request: FastifyRequest, reply: FastifyReply) {
    try {
      const userId = getAuthUserId(request);
      const roomId = (request.params as { roomId?: string; id?: string }).roomId ?? (request.params as { id?: string }).id;
      if (!roomId) {
        return sendError(reply, 400, 'BAD_REQUEST', 'roomId is required');
      }

      const membership = await ensureMembership(roomId, userId);
      if (!membership) {
        return sendError(reply, 404, 'NOT_FOUND', 'Room not found or inaccessible');
      }

      const room = await RoomModel.findById(roomId).lean();
      if (!room) {
        return sendError(reply, 404, 'NOT_FOUND', 'Room not found');
      }

      const messages = await MessageModel.find({ roomId }).sort({ createdAt: -1 }).limit(40).lean();
      messages.reverse();

      return sendData(request, reply, {
        room,
        membership,
        messages
      });
    } catch {
      return sendError(reply, 401, 'UNAUTHORIZED', 'Unauthorized');
    }
  },

  async destroy(request: FastifyRequest, reply: FastifyReply) {
    try {
      const userId = getAuthUserId(request);
      const roomId = (request.params as { roomId?: string; id?: string }).roomId ?? (request.params as { id?: string }).id;
      if (!roomId) {
        return sendError(reply, 400, 'BAD_REQUEST', 'roomId is required');
      }

      const room = await RoomModel.findById(roomId);
      if (!room) {
        return sendError(reply, 404, 'NOT_FOUND', 'Room not found');
      }

      if (!canAdminRoom(room, userId) && room.type !== 'direct') {
        return sendError(reply, 403, 'FORBIDDEN', 'Not enough permissions');
      }

      await MembershipModel.deleteMany({ roomId });
      await MessageModel.deleteMany({ roomId });
      await room.deleteOne();

      return sendData(request, reply, { removed: true });
    } catch {
      return sendError(reply, 401, 'UNAUTHORIZED', 'Unauthorized');
    }
  },

  async openCreate(request: FastifyRequest, reply: FastifyReply) {
    try {
      const userId = getAuthUserId(request);
      const payload = request.body as { name?: string };
      const name = (payload?.name ?? '').trim() || 'New room';

      const room = await RoomModel.create({
        name,
        type: 'open' as RoomType,
        creatorId: new Types.ObjectId(userId)
      });

      await MembershipModel.create({
        roomId: room._id,
        userId: new Types.ObjectId(userId),
        involvement: 'mentions'
      });

      if (!room) {
        return sendError(reply, 500, 'INTERNAL_ERROR', 'Failed to create direct room');
      }

      return sendData(request, reply, room.toObject(), 201);
    } catch {
      return sendError(reply, 401, 'UNAUTHORIZED', 'Unauthorized');
    }
  },

  async openUpdate(request: FastifyRequest, reply: FastifyReply) {
    try {
      const userId = getAuthUserId(request);
      const roomId = (request.params as { id?: string; roomId?: string }).id ?? (request.params as { roomId?: string }).roomId;
      if (!roomId) {
        return sendError(reply, 400, 'BAD_REQUEST', 'roomId is required');
      }

      const payload = request.body as { name?: string };
      const room = await RoomModel.findById(roomId);
      if (!room) {
        return sendError(reply, 404, 'NOT_FOUND', 'Room not found');
      }

      if (!canAdminRoom(room, userId)) {
        return sendError(reply, 403, 'FORBIDDEN', 'Not enough permissions');
      }

      room.name = (payload?.name ?? room.name ?? 'New room').trim();
      room.type = 'open';
      await room.save();

      return sendData(request, reply, room.toObject());
    } catch {
      return sendError(reply, 401, 'UNAUTHORIZED', 'Unauthorized');
    }
  },

  async closedCreate(request: FastifyRequest, reply: FastifyReply) {
    try {
      const userId = getAuthUserId(request);
      const payload = request.body as { name?: string; userIds?: string[]; user_ids?: string[] };
      const name = (payload?.name ?? '').trim() || 'New room';
      const selectedUserIds = ensureArrayString(payload?.userIds ?? payload?.user_ids ?? []);
      const allUserIds = Array.from(new Set([userId, ...selectedUserIds]));

      const room = await RoomModel.create({
        name,
        type: 'closed' as RoomType,
        creatorId: new Types.ObjectId(userId)
      });

      await MembershipModel.insertMany(
        allUserIds
          .map((id) => asObjectId(id))
          .filter((id): id is Types.ObjectId => id !== null)
          .map((id) => ({
            roomId: room._id,
            userId: id,
            involvement: 'mentions'
          })),
        { ordered: false }
      );

      return sendData(request, reply, room.toObject(), 201);
    } catch {
      return sendError(reply, 401, 'UNAUTHORIZED', 'Unauthorized');
    }
  },

  async closedUpdate(request: FastifyRequest, reply: FastifyReply) {
    try {
      const userId = getAuthUserId(request);
      const roomId = (request.params as { id?: string; roomId?: string }).id ?? (request.params as { roomId?: string }).roomId;
      if (!roomId) {
        return sendError(reply, 400, 'BAD_REQUEST', 'roomId is required');
      }

      const payload = request.body as { name?: string; userIds?: string[]; user_ids?: string[] };
      const selectedUserIds = Array.from(new Set([userId, ...ensureArrayString(payload?.userIds ?? payload?.user_ids ?? [])]));

      const room = await RoomModel.findById(roomId);
      if (!room) {
        return sendError(reply, 404, 'NOT_FOUND', 'Room not found');
      }
      if (!canAdminRoom(room, userId)) {
        return sendError(reply, 403, 'FORBIDDEN', 'Not enough permissions');
      }

      room.name = (payload?.name ?? room.name ?? 'New room').trim();
      room.type = 'closed';
      await room.save();

      await MembershipModel.deleteMany({ roomId, userId: { $nin: selectedUserIds.map((id) => new Types.ObjectId(id)) } });

      const existing = await MembershipModel.find({ roomId }, { userId: 1 }).lean();
      const existingIds = new Set(existing.map((m) => String(m.userId)));

      const toInsert = selectedUserIds
        .filter((id) => !existingIds.has(id))
        .map((id) => ({ roomId: new Types.ObjectId(roomId), userId: new Types.ObjectId(id), involvement: 'mentions' as const }));

      if (toInsert.length > 0) {
        await MembershipModel.insertMany(toInsert, { ordered: false });
      }

      return sendData(request, reply, room.toObject());
    } catch {
      return sendError(reply, 401, 'UNAUTHORIZED', 'Unauthorized');
    }
  },

  async directCreate(request: FastifyRequest, reply: FastifyReply) {
    try {
      const userId = getAuthUserId(request);
      const payload = request.body as { userIds?: string[]; user_ids?: string[]; userId?: string };
      const fromArray = ensureArrayString(payload?.userIds ?? payload?.user_ids ?? []);
      const ids = Array.from(new Set([userId, ...(payload?.userId ? [payload.userId] : []), ...fromArray]));
      const oidIds = ids.map((id) => asObjectId(id)).filter((id): id is Types.ObjectId => id !== null);
      const directKey = oidIds.map((id) => id.toHexString()).sort().join(':');

      let room = await RoomModel.findOne({ type: 'direct', directKey });
      if (!room) {
        room = await RoomModel.create({
          name: null,
          type: 'direct' as RoomType,
          creatorId: new Types.ObjectId(userId),
          directKey
        });
        const createdRoomId = room._id;

        await MembershipModel.insertMany(
          oidIds.map((id) => ({ roomId: createdRoomId, userId: id, involvement: 'everything' as const })),
          { ordered: false }
        );
      }

      if (!room) {
        return sendError(reply, 500, 'INTERNAL_ERROR', 'Failed to create direct room');
      }

      return sendData(request, reply, room.toObject(), 201);
    } catch {
      return sendError(reply, 401, 'UNAUTHORIZED', 'Unauthorized');
    }
  },

  async involvementShow(request: FastifyRequest, reply: FastifyReply) {
    try {
      const userId = getAuthUserId(request);
      const roomId = (request.params as { roomId?: string }).roomId;
      if (!roomId) {
        return sendError(reply, 400, 'BAD_REQUEST', 'roomId is required');
      }

      const membership = await MembershipModel.findOne({ roomId, userId }).lean();
      if (!membership) {
        return sendError(reply, 404, 'NOT_FOUND', 'Membership not found');
      }

      return sendData(request, reply, { involvement: membership.involvement });
    } catch {
      return sendError(reply, 401, 'UNAUTHORIZED', 'Unauthorized');
    }
  },

  async involvementUpdate(request: FastifyRequest, reply: FastifyReply) {
    try {
      const userId = getAuthUserId(request);
      const roomId = (request.params as { roomId?: string }).roomId;
      const involvement = (request.body as { involvement?: string })?.involvement;

      if (!roomId || !involvement) {
        return sendError(reply, 400, 'BAD_REQUEST', 'roomId and involvement are required');
      }

      if (!['invisible', 'nothing', 'mentions', 'everything'].includes(involvement)) {
        return sendError(reply, 422, 'VALIDATION_ERROR', 'Invalid involvement value');
      }

      const membership = await MembershipModel.findOneAndUpdate(
        { roomId, userId },
        { involvement },
        { new: true }
      ).lean();

      if (!membership) {
        return sendError(reply, 404, 'NOT_FOUND', 'Membership not found');
      }

      return sendData(request, reply, membership);
    } catch {
      return sendError(reply, 401, 'UNAUTHORIZED', 'Unauthorized');
    }
  },

  async refresh(request: FastifyRequest, reply: FastifyReply) {
    try {
      const userId = getAuthUserId(request);
      const roomId = (request.params as { roomId?: string }).roomId;
      const since = Number((request.query as { since?: string }).since ?? 0);

      if (!roomId) {
        return sendError(reply, 400, 'BAD_REQUEST', 'roomId is required');
      }

      const membership = await ensureMembership(roomId, userId);
      if (!membership) {
        return sendError(reply, 404, 'NOT_FOUND', 'Room not found or inaccessible');
      }

      const ts = Number.isFinite(since) && since > 0 ? new Date(since) : new Date(0);
      const newMessages = await MessageModel.find({ roomId, createdAt: { $gt: ts } }).sort({ createdAt: 1 }).limit(40).lean();
      const updatedMessages = await MessageModel.find({ roomId, updatedAt: { $gt: ts }, createdAt: { $lte: ts } }).sort({ updatedAt: -1 }).limit(40).lean();

      return sendData(request, reply, { newMessages, updatedMessages });
    } catch {
      return sendError(reply, 401, 'UNAUTHORIZED', 'Unauthorized');
    }
  },

  async settingsShow(request: FastifyRequest, reply: FastifyReply) {
    try {
      const userId = getAuthUserId(request);
      const roomId = (request.params as { roomId?: string }).roomId;
      if (!roomId) {
        return sendError(reply, 400, 'BAD_REQUEST', 'roomId is required');
      }

      const membership = await ensureMembership(roomId, userId);
      if (!membership) {
        return sendError(reply, 404, 'NOT_FOUND', 'Room not found or inaccessible');
      }

      const room = await RoomModel.findById(roomId).lean();
      if (!room) {
        return sendError(reply, 404, 'NOT_FOUND', 'Room not found');
      }

      const membersCount = await MembershipModel.countDocuments({ roomId });
      return sendData(request, reply, { room, membersCount });
    } catch {
      return sendError(reply, 401, 'UNAUTHORIZED', 'Unauthorized');
    }
  }
};
