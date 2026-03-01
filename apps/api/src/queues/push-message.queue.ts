import { Queue, Worker, type Job } from 'bullmq';
import { env } from '../config/env.js';
import { MembershipModel } from '../models/membership.model.js';
import { MessageModel } from '../models/message.model.js';
import { RoomModel } from '../models/room.model.js';
import { UserModel } from '../models/user.model.js';
import { deliverPushNotifications } from '../services/push-notifications.js';
import { disconnectedMembershipFilter } from '../services/membership-connection.js';
import { findMentionedUserIdsInRoom } from '../services/mentions.js';
import { plainTextForMessage } from '../services/rich-text.js';

type PushMessageJobData = {
  roomId: string;
  messageId: string;
};

const QUEUE_NAME = `${env.REDIS_PREFIX}:push-message-events`;

let queue: Queue | null = null;
let worker: Worker | null = null;

function ensureQueue() {
  if (queue) {
    return queue;
  }

  queue = new Queue(QUEUE_NAME, {
    connection: {
      url: env.REDIS_URL,
      maxRetriesPerRequest: null
    },
    defaultJobOptions: {
      attempts: 2,
      removeOnComplete: true,
      removeOnFail: 100
    }
  });

  return queue;
}

export async function enqueuePushMessageJob(data: PushMessageJobData) {
  await ensureQueue().add('push-message', data);
}

function plainTextBody(message: {
  body?: string;
  bodyPlain?: string;
  attachment?: {
    filename?: string;
  } | null;
}) {
  return plainTextForMessage(message);
}

async function processPushMessage(job: Job) {
  const data = job.data as PushMessageJobData;

  const [message, room] = await Promise.all([
    MessageModel.findById(data.messageId).lean(),
    RoomModel.findById(data.roomId).lean()
  ]);

  if (!message || !room) {
    return;
  }

  const creator = await UserModel.findById(message.creatorId, { name: 1 }).lean();
  if (!creator) {
    return;
  }

  const disconnectedMembers = await MembershipModel.find({
    roomId: room._id,
    userId: { $ne: message.creatorId },
    involvement: { $ne: 'invisible' },
    ...disconnectedMembershipFilter()
  }).lean();

  if (disconnectedMembers.length === 0) {
    return;
  }

  const allRoomMemberships = await MembershipModel.find({ roomId: room._id }, { userId: 1 }).lean();
  const roomUserIds = allRoomMemberships.map((membership) => String(membership.userId));

  const involvedInEverything = disconnectedMembers
    .filter((membership) => membership.involvement === 'everything')
    .map((membership) => String(membership.userId));

  const involvedInMentions = disconnectedMembers
    .filter((membership) => membership.involvement === 'mentions')
    .map((membership) => String(membership.userId));

  const mentioneeIds =
    involvedInMentions.length > 0
      ? Array.isArray(message.mentioneeIds) && message.mentioneeIds.length > 0
        ? message.mentioneeIds.map((id) => String(id))
        : await findMentionedUserIdsInRoom(roomUserIds, message.body)
      : [];
  const mentioneeSet = new Set(mentioneeIds.map((id) => id.toLowerCase()));

  const recipients = new Set<string>();
  for (const userId of involvedInEverything) {
    recipients.add(userId);
  }

  for (const userId of involvedInMentions) {
    if (mentioneeSet.has(userId.toLowerCase())) {
      recipients.add(userId);
    }
  }

  if (recipients.size === 0) {
    return;
  }

  const payload =
    room.type === 'direct'
      ? {
          title: creator.name,
          body: plainTextBody(message),
          path: `/rooms/${String(room._id)}`
        }
      : {
          title: room.name || 'Room',
          body: `${creator.name}: ${plainTextBody(message)}`,
          path: `/rooms/${String(room._id)}`
        };

  await deliverPushNotifications(Array.from(recipients), payload);
}

export function startPushMessageWorker() {
  if (worker) {
    return worker;
  }

  worker = new Worker(QUEUE_NAME, processPushMessage, {
    connection: {
      url: env.REDIS_URL,
      maxRetriesPerRequest: null
    },
    concurrency: 20
  });

  return worker;
}

export async function stopPushMessageWorker() {
  await Promise.allSettled([
    worker?.close() ?? Promise.resolve(),
    queue?.close() ?? Promise.resolve()
  ]);

  worker = null;
  queue = null;
}
