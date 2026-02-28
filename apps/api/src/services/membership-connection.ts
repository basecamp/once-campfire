import { MembershipModel } from '../models/membership.model.js';

const CONNECTION_TTL_MS = 60 * 1000;

function connectionCutoffDate() {
  return new Date(Date.now() - CONNECTION_TTL_MS);
}

function isConnectedAt(connectedAt?: Date | null) {
  if (!connectedAt) {
    return false;
  }

  return new Date(connectedAt).getTime() >= connectionCutoffDate().getTime();
}

export async function presentMembership(roomId: string, userId: string) {
  const membership = await MembershipModel.findOne({ roomId, userId });
  if (!membership) {
    return null;
  }

  const connected = isConnectedAt(membership.connectedAt);

  membership.connections = connected ? membership.connections + 1 : 1;
  membership.connectedAt = new Date();
  membership.unreadAt = undefined;
  await membership.save();

  return membership;
}

export async function absentMembership(roomId: string, userId: string) {
  const membership = await MembershipModel.findOne({ roomId, userId });
  if (!membership) {
    return null;
  }

  const connected = isConnectedAt(membership.connectedAt);
  membership.connections = connected ? Math.max(0, membership.connections - 1) : 0;

  if (membership.connections < 1) {
    membership.connectedAt = undefined;
  }

  await membership.save();

  return membership;
}

export async function refreshMembership(roomId: string, userId: string) {
  const membership = await MembershipModel.findOne({ roomId, userId });
  if (!membership) {
    return null;
  }

  if (!isConnectedAt(membership.connectedAt)) {
    membership.connections = 1;
  }

  membership.connectedAt = new Date();
  await membership.save();

  return membership;
}

export function disconnectedMembershipFilter() {
  return {
    $or: [
      { connectedAt: { $exists: false } },
      { connectedAt: null },
      { connectedAt: { $lt: connectionCutoffDate() } }
    ]
  };
}
