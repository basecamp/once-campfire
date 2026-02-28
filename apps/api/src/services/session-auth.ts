import { SessionModel } from '../models/session.model.js';

const ACTIVITY_REFRESH_MS = 60 * 60 * 1000;

type SessionCreateArgs = {
  userId: string;
  userAgent: string;
  ipAddress: string;
};

export async function createSession({ userId, userAgent, ipAddress }: SessionCreateArgs) {
  return SessionModel.create({
    userId,
    userAgent,
    ipAddress,
    lastActiveAt: new Date()
  });
}

export async function refreshSessionIfNeeded(sessionId: string, userAgent: string, ipAddress: string) {
  const session = await SessionModel.findById(sessionId).lean();
  if (!session) {
    return null;
  }

  const lastActiveAt = new Date(session.lastActiveAt).getTime();
  const shouldRefresh = Date.now() - lastActiveAt > ACTIVITY_REFRESH_MS;

  if (shouldRefresh) {
    await SessionModel.updateOne(
      { _id: session._id },
      {
        $set: {
          userAgent,
          ipAddress,
          lastActiveAt: new Date()
        }
      }
    );
  }

  return session;
}
