import type { FastifyInstance } from 'fastify';
import { buildUserAvatarPath } from '../services/avatar-media.js';

export async function serializeUser(app: FastifyInstance, user: {
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
