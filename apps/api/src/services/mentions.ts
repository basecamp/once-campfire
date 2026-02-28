import { UserModel } from '../models/user.model.js';

function normalizeName(name: string) {
  return name.trim().toLowerCase();
}

export async function findMentionedUserIdsInRoom(roomUserIds: string[], body: string) {
  if (roomUserIds.length === 0 || !body.trim()) {
    return [];
  }

  const users = await UserModel.find({ _id: { $in: roomUserIds } }, { name: 1 }).lean();
  const normalizedBody = body.toLowerCase();

  return users
    .filter((user) => normalizedBody.includes(`@${normalizeName(user.name)}`))
    .map((user) => String(user._id));
}
