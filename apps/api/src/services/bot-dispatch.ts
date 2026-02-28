import { MembershipModel } from '../models/membership.model.js';
import { RoomModel } from '../models/room.model.js';
import { UserModel } from '../models/user.model.js';
import { enqueueBotWebhookJob } from '../queues/bot-webhook.queue.js';
import { findMentionedUserIdsInRoom } from './mentions.js';

export async function enqueueEligibleBotWebhooks({
  roomId,
  messageId,
  creatorId,
  body
}: {
  roomId: string;
  messageId: string;
  creatorId: string;
  body: string;
}) {
  const [room, memberships] = await Promise.all([
    RoomModel.findById(roomId).lean(),
    MembershipModel.find({ roomId }, { userId: 1 }).lean()
  ]);

  if (!room || memberships.length === 0) {
    return;
  }

  const roomUserIds = memberships.map((membership) => String(membership.userId));

  let candidateUserIds: string[] = [];

  if (room.type === 'direct') {
    candidateUserIds = roomUserIds.filter((userId) => userId !== creatorId);
  } else {
    candidateUserIds = await findMentionedUserIdsInRoom(roomUserIds, body);
  }

  if (candidateUserIds.length === 0) {
    return;
  }

  const bots = await UserModel.find(
    {
      _id: { $in: candidateUserIds },
      role: 'bot',
      status: 'active',
      botWebhookUrl: { $exists: true, $ne: '' }
    },
    { _id: 1 }
  ).lean();

  await Promise.all(
    bots.map((bot) =>
      enqueueBotWebhookJob({
        botUserId: String(bot._id),
        messageId
      })
    )
  );
}
