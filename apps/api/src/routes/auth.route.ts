import bcrypt from 'bcryptjs';
import type { FastifyPluginAsync } from 'fastify';
import { z } from 'zod';
import { COOKIE_NAME } from '../plugins/auth.js';
import { UserModel } from '../models/user.model.js';
import { MembershipModel } from '../models/membership.model.js';
import { RoomModel } from '../models/room.model.js';
import { SessionModel } from '../models/session.model.js';
import { createSession } from '../services/session-auth.js';

const registerSchema = z.object({
  name: z.string().min(2).max(64),
  emailAddress: z.string().email().max(320),
  password: z.string().min(8).max(128)
});

const loginSchema = z.object({
  emailAddress: z.string().email(),
  password: z.string().min(8).max(128)
});

function sanitizeUser(user: {
  _id: unknown;
  name: string;
  emailAddress: string;
  role: string;
  status: string;
  bio?: string;
}) {
  return {
    id: String(user._id),
    name: user.name,
    emailAddress: user.emailAddress,
    role: user.role,
    status: user.status,
    bio: user.bio ?? ''
  };
}

const authRoutes: FastifyPluginAsync = async (app) => {
  app.post('/register', async (request, reply) => {
    const payload = registerSchema.parse(request.body);

    const existing = await UserModel.findOne({ emailAddress: payload.emailAddress.toLowerCase() }).lean();
    if (existing) {
      return reply.code(409).send({ error: 'Email already used' });
    }

    const usersCount = await UserModel.countDocuments();
    const passwordHash = await bcrypt.hash(payload.password, 12);

    const user = await UserModel.create({
      name: payload.name,
      emailAddress: payload.emailAddress.toLowerCase(),
      passwordHash,
      role: usersCount === 0 ? 'admin' : 'member'
    });

    // Mirror Rails behavior: every new user is added to all open rooms.
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

    const token = await reply.jwtSign({ sub: String(user._id), sid: String(session._id) }, { expiresIn: '7d' });
    reply.setCookie(COOKIE_NAME, token, {
      path: '/',
      httpOnly: true,
      sameSite: 'lax',
      secure: false,
      maxAge: 60 * 60 * 24 * 7
    });

    return reply.code(201).send({ user: sanitizeUser(user.toObject()) });
  });

  app.post('/login', async (request, reply) => {
    const payload = loginSchema.parse(request.body);

    const user = await UserModel.findOne({ emailAddress: payload.emailAddress.toLowerCase() });
    if (!user) {
      return reply.code(401).send({ error: 'Invalid credentials' });
    }

    if (user.status !== 'active') {
      return reply.code(403).send({ error: 'User is not active' });
    }

    const valid = await bcrypt.compare(payload.password, user.passwordHash);
    if (!valid) {
      return reply.code(401).send({ error: 'Invalid credentials' });
    }

    const session = await createSession({
      userId: String(user._id),
      userAgent: request.headers['user-agent'] ?? '',
      ipAddress: request.ip
    });

    const token = await reply.jwtSign({ sub: String(user._id), sid: String(session._id) }, { expiresIn: '7d' });

    reply.setCookie(COOKIE_NAME, token, {
      path: '/',
      httpOnly: true,
      sameSite: 'lax',
      secure: false,
      maxAge: 60 * 60 * 24 * 7
    });

    return { user: sanitizeUser(user.toObject()) };
  });

  app.post('/logout', { preHandler: app.authenticate }, async (request, reply) => {
    if (request.authSessionId) {
      await SessionModel.deleteOne({ _id: request.authSessionId });
    }

    reply.clearCookie(COOKIE_NAME, { path: '/' });
    return reply.code(204).send();
  });

  app.get('/me', { preHandler: app.authenticate }, async (request, reply) => {
    const userId = request.authUserId;
    if (!userId) {
      return reply.code(401).send({ error: 'Unauthorized' });
    }

    const user = await UserModel.findById(userId).lean();
    if (!user) {
      return reply.code(404).send({ error: 'User not found' });
    }

    return { user: sanitizeUser(user) };
  });
};

export default authRoutes;
