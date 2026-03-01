import type { FastifyReply, FastifyRequest } from 'fastify';
import { Types } from 'mongoose';
import { RoomModel } from '../../rooms/models/room.model.js';
import { MembershipModel } from '../../rooms/models/membership.model.js';
import { BanModel } from '../../moderation/models/ban.model.js';
import { SessionModel } from '../../realtime/models/session.model.js';
import { MessageModel } from '../../messages/models/message.model.js';
import { AccountModel } from '../../account/models/account.model.js';
import UserModel from '../models/user.model.js';
import { asObjectId, getAuthUserId, sendData, sendError } from '../../../shared/utils/controller.js';

type StoredRole = 'member' | 'administrator' | 'bot';
type UserStatus = 'active' | 'banned' | 'deactivated';

interface UserLean {
  _id: Types.ObjectId;
  email: string;
  password?: string;
  roles?: StoredRole[];
  status?: UserStatus;
  bio?: string | null;
  avatarSource?: string | null;
  transferId?: string | null;
  name?: {
    first?: string;
    last?: string;
  };
  createdAt?: Date;
  updatedAt?: Date;
}

interface AccountLean {
  _id: Types.ObjectId;
  joinCode: string;
  createdAt?: Date;
}

function normalizeString(value: unknown): string | null {
  if (typeof value !== 'string') {
    return null;
  }
  const trimmed = value.trim();
  return trimmed.length > 0 ? trimmed : null;
}

function parseCompanyId(request: FastifyRequest): Types.ObjectId | null {
  const company = request.session?.company;
  if (typeof company === 'string') {
    return asObjectId(company);
  }
  if (company && typeof company === 'object') {
    const withIds = company as { _id?: unknown; id?: unknown };
    const fromPrimary = normalizeString(withIds._id);
    if (fromPrimary) {
      return asObjectId(fromPrimary);
    }
    const fromAlias = normalizeString(withIds.id);
    if (fromAlias) {
      return asObjectId(fromAlias);
    }
  }
  return null;
}

function escapeRegex(input: string) {
  return input.replace(/[.*+?^${}()|[\]\\]/g, '\\$&');
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

function toRailsRole(role: StoredRole): 'member' | 'administrator' | 'bot' {
  return role;
}

function fromRoleInput(input: unknown): StoredRole {
  const value = normalizeString(input)?.toLowerCase() ?? 'member';
  if (value === 'administrator' || value === 'admin') {
    return 'administrator';
  }
  if (value === 'bot') {
    return 'bot';
  }
  return 'member';
}

async function getCurrentAccount(request: FastifyRequest): Promise<AccountLean | null> {
  const accountId = parseCompanyId(request);
  if (accountId) {
    const byId = await AccountModel.findById(accountId).lean<AccountLean>();
    if (byId) {
      return byId;
    }
  }
  return AccountModel.findOne({}).sort({ createdAt: 1 }).lean<AccountLean>();
}

async function ensureAdmin(request: FastifyRequest): Promise<boolean> {
  const roleFromSession = normalizeString(request.session?.role)?.toLowerCase();
  if (roleFromSession === 'admin' || roleFromSession === 'administrator') {
    return true;
  }

  const userId = asObjectId(getAuthUserId(request));
  if (!userId) {
    return false;
  }

  const user = await UserModel.findById(userId, { roles: 1 }).lean() as UserLean | null;
  return Boolean(user?.roles?.includes('administrator'));
}

function serializeUser(user: UserLean) {
  const name = displayName(user);
  const role = primaryRole(user);
  return {
    id: String(user._id),
    name,
    emailAddress: user.email,
    email_address: user.email,
    role: toRailsRole(role),
    status: user.status ?? 'active',
    bio: user.bio ?? '',
    avatarUrl: user.avatarSource ?? null,
    avatar_url: user.avatarSource ?? null
  };
}

function parseUserPayload(body: unknown) {
  if (!body || typeof body !== 'object') {
    return {
      name: null,
      emailAddress: null,
      password: null,
      bio: null,
      avatarSource: null
    };
  }

  const raw = body as Record<string, unknown>;
  const nested = raw.user && typeof raw.user === 'object' ? (raw.user as Record<string, unknown>) : null;

  return {
    name: normalizeString(nested?.name ?? raw.name),
    emailAddress: normalizeString(
      nested?.emailAddress ?? nested?.email_address ?? raw.emailAddress ?? raw.email_address ?? raw.email
    )?.toLowerCase() ?? null,
    password: normalizeString(nested?.password ?? raw.password),
    bio: normalizeString(nested?.bio ?? raw.bio),
    avatarSource: normalizeString(
      nested?.avatarSource ?? nested?.avatar_source ?? nested?.avatarUrl ?? nested?.avatar_url ??
      raw.avatarSource ?? raw.avatar_source ?? raw.avatarUrl ?? raw.avatar_url
    )
  };
}

export const usersController = {
  async show(request: FastifyRequest, reply: FastifyReply) {
    try {
      const userId = asObjectId((request.params as { id?: string }).id);
      if (!userId) {
        return sendError(reply, 422, 'VALIDATION_ERROR', 'Invalid user id');
      }

      const user = await UserModel.findById(userId).lean() as UserLean | null;
      if (!user) {
        return sendError(reply, 404, 'NOT_FOUND', 'User not found');
      }

      return sendData(request, reply, serializeUser(user));
    } catch {
      return sendError(reply, 500, 'INTERNAL_ERROR', 'Cannot load user');
    }
  },

  async joinNew(request: FastifyRequest, reply: FastifyReply) {
    try {
      const joinCode = normalizeString((request.params as { joinCode?: string; join_code?: string }).joinCode) ??
        normalizeString((request.params as { join_code?: string }).join_code);
      if (!joinCode) {
        return sendError(reply, 400, 'BAD_REQUEST', 'joinCode is required');
      }

      const account = await getCurrentAccount(request);
      if (!account || account.joinCode !== joinCode) {
        return sendError(reply, 404, 'NOT_FOUND', 'Join code is invalid');
      }

      return sendData(request, reply, { allowed: true, joinCode, join_code: joinCode });
    } catch {
      return sendError(reply, 500, 'INTERNAL_ERROR', 'Cannot validate join code');
    }
  },

  async joinCreate(request: FastifyRequest, reply: FastifyReply) {
    try {
      const joinCode = normalizeString((request.params as { joinCode?: string; join_code?: string }).joinCode) ??
        normalizeString((request.params as { join_code?: string }).join_code);
      if (!joinCode) {
        return sendError(reply, 400, 'BAD_REQUEST', 'joinCode is required');
      }

      const account = await getCurrentAccount(request);
      if (!account || account.joinCode !== joinCode) {
        return sendError(reply, 404, 'NOT_FOUND', 'Join code is invalid');
      }

      const payload = parseUserPayload(request.body);
      if (!payload.name || !payload.emailAddress || !payload.password) {
        return sendError(reply, 422, 'VALIDATION_ERROR', 'name, emailAddress and password are required');
      }

      const existing = await UserModel.findOne({ email: payload.emailAddress }).lean() as UserLean | null;
      if (existing) {
        return sendError(reply, 409, 'CONFLICT', 'Email already exists');
      }

      const user = new UserModel({
        name: splitName(payload.name),
        email: payload.emailAddress,
        password: payload.password,
        roles: ['member'],
        status: 'active',
        bio: payload.bio ?? '',
        avatarSource: payload.avatarSource ?? null
      });
      await user.save();

      return sendData(request, reply, serializeUser(user.toObject() as UserLean), 201);
    } catch {
      return sendError(reply, 500, 'INTERNAL_ERROR', 'Cannot create user');
    }
  },

  async profileShow(request: FastifyRequest, reply: FastifyReply) {
    try {
      const authUserId = asObjectId(getAuthUserId(request));
      if (!authUserId) {
        return sendError(reply, 401, 'UNAUTHORIZED', 'Unauthorized');
      }

      const [user, memberships, rooms] = await Promise.all([
        UserModel.findById(authUserId).lean() as Promise<UserLean | null>,
        MembershipModel.find({ userId: authUserId }).sort({ updatedAt: -1 }).lean(),
        RoomModel.find({}, { _id: 1, name: 1, type: 1, updatedAt: 1 }).lean()
      ]);

      if (!user) {
        return sendError(reply, 404, 'NOT_FOUND', 'User not found');
      }

      const roomsById = new Map(rooms.map((room) => [String(room._id), room]));
      const directMemberships = memberships
        .filter((membership) => roomsById.get(String(membership.roomId))?.type === 'direct')
        .sort((a, b) => {
          const aTime = roomsById.get(String(a.roomId))?.updatedAt?.getTime() ?? 0;
          const bTime = roomsById.get(String(b.roomId))?.updatedAt?.getTime() ?? 0;
          return bTime - aTime;
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

      return sendData(request, reply, {
        user: serializeUser(user),
        directMemberships,
        direct_memberships: directMemberships,
        sharedMemberships,
        shared_memberships: sharedMemberships
      });
    } catch {
      return sendError(reply, 500, 'INTERNAL_ERROR', 'Cannot load profile');
    }
  },

  async profileUpdate(request: FastifyRequest, reply: FastifyReply) {
    try {
      const authUserId = asObjectId(getAuthUserId(request));
      if (!authUserId) {
        return sendError(reply, 401, 'UNAUTHORIZED', 'Unauthorized');
      }

      const user = await UserModel.findOne({ _id: authUserId, status: { $in: ['active', 'banned'] } });
      if (!user) {
        return sendError(reply, 404, 'NOT_FOUND', 'User not found');
      }

      const payload = parseUserPayload(request.body);
      if (payload.name) {
        user.name = splitName(payload.name);
      }
      if (payload.emailAddress) {
        user.email = payload.emailAddress;
      }
      if (payload.bio !== null) {
        user.bio = payload.bio;
      }
      if (payload.avatarSource !== null) {
        user.avatarSource = payload.avatarSource;
      }
      if (payload.password) {
        user.password = payload.password;
      }

      await user.save();
      return sendData(request, reply, { user: serializeUser(user.toObject() as UserLean) });
    } catch {
      return sendError(reply, 500, 'INTERNAL_ERROR', 'Cannot update profile');
    }
  },

  async sidebarShow(request: FastifyRequest, reply: FastifyReply) {
    try {
      const authUserId = asObjectId(getAuthUserId(request));
      if (!authUserId) {
        return sendError(reply, 401, 'UNAUTHORIZED', 'Unauthorized');
      }

      const allMemberships = await MembershipModel.find({
        userId: authUserId,
        involvement: { $ne: 'invisible' }
      }).lean();
      const roomIds = allMemberships.map((membership) => membership.roomId);
      const rooms = await RoomModel.find({ _id: { $in: roomIds } }).lean();
      const roomsById = new Map(rooms.map((room) => [String(room._id), room]));

      const directMemberships = allMemberships
        .filter((membership) => roomsById.get(String(membership.roomId))?.type === 'direct')
        .sort((a, b) => {
          const aTime = roomsById.get(String(a.roomId))?.updatedAt?.getTime() ?? 0;
          const bTime = roomsById.get(String(b.roomId))?.updatedAt?.getTime() ?? 0;
          return bTime - aTime;
        });
      const otherMemberships = allMemberships.filter((membership) => roomsById.get(String(membership.roomId))?.type !== 'direct');

      const directRoomIds = directMemberships.map((membership) => membership.roomId);
      const membersInDirectRooms = directRoomIds.length > 0
        ? await MembershipModel.find(
          { roomId: { $in: directRoomIds }, userId: { $ne: authUserId } },
          { roomId: 1, userId: 1 }
        ).lean()
        : [];

      const usersInDirects = new Set<string>([String(authUserId)]);
      for (const membership of membersInDirectRooms) {
        usersInDirects.add(String(membership.userId));
      }

      const directPartnerIds = Array.from(usersInDirects).filter((id) => id !== String(authUserId));
      const directPartners = (directPartnerIds.length > 0
        ? await UserModel.find(
          { _id: { $in: directPartnerIds.map((id) => new Types.ObjectId(id)) } },
          { name: 1, avatarSource: 1, status: 1, roles: 1 }
        ).lean()
        : []) as UserLean[];
      const directPartnersById = new Map<string, UserLean>(directPartners.map((partner: UserLean) => [String(partner._id), partner]));

      const placeholdersLimit = Math.max(0, 20 - usersInDirects.size);
      const directPlaceholderUsers = (placeholdersLimit > 0
        ? await UserModel.find(
          {
            _id: { $nin: Array.from(usersInDirects).map((id) => new Types.ObjectId(id)) },
            status: 'active',
            roles: { $nin: ['bot'] }
          },
          { name: 1, avatarSource: 1 }
        ).sort({ createdAt: 1 }).limit(placeholdersLimit).lean()
        : []) as UserLean[];

      const directRooms = directMemberships.map((membership) => {
        const room = roomsById.get(String(membership.roomId));
        const partnerMembership = membersInDirectRooms.find((m) => String(m.roomId) === String(membership.roomId));
        const partner = partnerMembership ? directPartnersById.get(String(partnerMembership.userId)) : null;
        return {
          roomId: String(membership.roomId),
          roomName: partner ? displayName(partner) : room?.name ?? 'Direct',
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

      const placeholders = directPlaceholderUsers.map((user: UserLean) => ({
        id: String(user._id),
        name: displayName(user),
        avatarUrl: user.avatarSource ?? null,
        avatar_url: user.avatarSource ?? null
      }));

      return sendData(request, reply, {
        directRooms,
        direct_rooms: directRooms,
        sharedRooms,
        shared_rooms: sharedRooms,
        directPlaceholderUsers: placeholders,
        direct_placeholder_users: placeholders
      });
    } catch {
      return sendError(reply, 500, 'INTERNAL_ERROR', 'Cannot load sidebar');
    }
  },

  async avatarShow(request: FastifyRequest, reply: FastifyReply) {
    try {
      const userId = asObjectId((request.params as { userId?: string }).userId);
      if (!userId) {
        return sendError(reply, 404, 'NOT_FOUND', 'User not found');
      }

      const user = await UserModel.findById(userId, { name: 1, roles: 1, avatarSource: 1 }).lean() as UserLean | null;
      if (!user) {
        return sendError(reply, 404, 'NOT_FOUND', 'User not found');
      }

      const initials = displayName(user)
        .split(/\s+/)
        .filter(Boolean)
        .slice(0, 2)
        .map((token) => token[0]?.toUpperCase() ?? '')
        .join('');

      return sendData(request, reply, {
        url: user.avatarSource ?? null,
        contentType: user.avatarSource ? 'image/webp' : 'image/svg+xml',
        fallback: primaryRole(user) === 'bot' ? 'bot-default' : 'initials',
        initials: initials || 'U'
      });
    } catch {
      return sendError(reply, 500, 'INTERNAL_ERROR', 'Cannot load avatar');
    }
  },

  async avatarDestroy(request: FastifyRequest, reply: FastifyReply) {
    try {
      const authUserId = asObjectId(getAuthUserId(request));
      if (!authUserId) {
        return sendError(reply, 401, 'UNAUTHORIZED', 'Unauthorized');
      }

      await UserModel.updateOne({ _id: authUserId }, { $set: { avatarSource: null, updatedAt: new Date() } });
      return sendData(request, reply, { removed: true });
    } catch {
      return sendError(reply, 500, 'INTERNAL_ERROR', 'Cannot remove avatar');
    }
  },

  async banCreate(request: FastifyRequest, reply: FastifyReply) {
    try {
      if (!(await ensureAdmin(request))) {
        return sendError(reply, 403, 'FORBIDDEN', 'Not enough permissions');
      }

      const targetUserId = asObjectId((request.params as { userId?: string }).userId);
      if (!targetUserId) {
        return sendError(reply, 422, 'VALIDATION_ERROR', 'Invalid user id');
      }

      const sessions = await SessionModel.find({ userId: targetUserId }, { ipAddress: 1 }).lean();
      const ips = Array.from(new Set(sessions.map((session) => session.ipAddress).filter((ip): ip is string => Boolean(ip))));
      if (ips.length > 0) {
        await BanModel.insertMany(
          ips.map((ipAddress) => ({ userId: targetUserId, ipAddress })),
          { ordered: false }
        ).catch(() => undefined);
      }

      await Promise.all([
        UserModel.updateOne({ _id: targetUserId }, { $set: { status: 'banned', updatedAt: new Date() } }),
        SessionModel.deleteMany({ userId: targetUserId }),
        MessageModel.deleteMany({ creatorId: targetUserId })
      ]);

      return sendData(request, reply, { banned: true, userId: String(targetUserId), ips });
    } catch {
      return sendError(reply, 500, 'INTERNAL_ERROR', 'Cannot ban user');
    }
  },

  async banDestroy(request: FastifyRequest, reply: FastifyReply) {
    try {
      if (!(await ensureAdmin(request))) {
        return sendError(reply, 403, 'FORBIDDEN', 'Not enough permissions');
      }

      const targetUserId = asObjectId((request.params as { userId?: string }).userId);
      if (!targetUserId) {
        return sendError(reply, 422, 'VALIDATION_ERROR', 'Invalid user id');
      }

      await Promise.all([
        BanModel.deleteMany({ userId: targetUserId }),
        UserModel.updateOne({ _id: targetUserId }, { $set: { status: 'active', updatedAt: new Date() } })
      ]);

      return sendData(request, reply, { unbanned: true, userId: String(targetUserId) });
    } catch {
      return sendError(reply, 500, 'INTERNAL_ERROR', 'Cannot unban user');
    }
  },

  async autocompletableIndex(request: FastifyRequest, reply: FastifyReply) {
    try {
      const query = normalizeString((request.query as { query?: string }).query ?? '');
      const roomId = asObjectId((request.query as { roomId?: string; room_id?: string }).roomId ??
        (request.query as { room_id?: string }).room_id);

      const filter: Record<string, unknown> = {
        status: 'active',
        roles: { $nin: ['bot'] }
      };
      if (query) {
        const regex = { $regex: escapeRegex(query), $options: 'i' };
        filter.$or = [{ 'name.first': regex }, { 'name.last': regex }, { email: regex }];
      }

      let users: UserLean[];
      if (roomId) {
        const memberships = await MembershipModel.find({ roomId }, { userId: 1 }).lean();
        const userIds = memberships.map((membership) => membership.userId);
        users = userIds.length > 0
          ? await UserModel.find({ ...filter, _id: { $in: userIds } }, { name: 1, email: 1, roles: 1, status: 1 })
            .sort({ 'name.first': 1, 'name.last': 1 })
            .limit(20)
            .lean()
          : [];
      } else {
        users = await UserModel.find(filter, { name: 1, email: 1, roles: 1, status: 1 })
          .sort({ 'name.first': 1, 'name.last': 1 })
          .limit(20)
          .lean() as UserLean[];
      }

      return sendData(
        request,
        reply,
        users.map((user) => ({
          id: String(user._id),
          name: displayName(user),
          emailAddress: user.email,
          email_address: user.email,
          role: toRailsRole(primaryRole(user)),
          status: user.status ?? 'active'
        }))
      );
    } catch {
      return sendError(reply, 500, 'INTERNAL_ERROR', 'Cannot load autocompletable users');
    }
  }
};
