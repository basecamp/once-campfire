import { UserModel } from '../models/user.model.js';

function normalizeName(name: string) {
  return name.trim().toLowerCase().replace(/\s+/g, ' ');
}

function escapeRegex(input: string) {
  return input.replace(/[.*+?^${}()|[\]\\]/g, '\\$&');
}

function stripTags(input: string) {
  return input.replace(/<[^>]+>/g, ' ');
}

function decodeBasicHtmlEntities(input: string) {
  return input
    .replace(/&nbsp;/gi, ' ')
    .replace(/&amp;/gi, '&')
    .replace(/&lt;/gi, '<')
    .replace(/&gt;/gi, '>')
    .replace(/&quot;/gi, '"')
    .replace(/&#39;/gi, "'");
}

function normalizeBodyForMentions(body: string) {
  return normalizeName(decodeBasicHtmlEntities(stripTags(body)));
}

function collectExplicitMentionedUserIds(roomUserIdSet: Set<string>, body: string) {
  const mentioned = new Set<string>();

  // Support explicit data attributes in rich text/HTML mentions.
  const dataUserIdPattern = /data-user-id=["']([a-f\d]{24})["']/gi;
  for (const match of body.matchAll(dataUserIdPattern)) {
    const userId = (match[1] || '').toLowerCase();
    if (roomUserIdSet.has(userId)) {
      mentioned.add(userId);
    }
  }

  // Support user links such as /users/:id in mention HTML fragments.
  const userHrefPattern = /href=["'][^"']*\/users\/([a-f\d]{24})(?:[/"'?&#]|$)/gi;
  for (const match of body.matchAll(userHrefPattern)) {
    const userId = (match[1] || '').toLowerCase();
    if (roomUserIdSet.has(userId)) {
      mentioned.add(userId);
    }
  }

  return mentioned;
}

export async function findMentionedUserIdsInRoom(roomUserIds: string[], body: string) {
  if (roomUserIds.length === 0 || !body.trim()) {
    return [];
  }

  const users = await UserModel.find({ _id: { $in: roomUserIds } }, { name: 1 }).lean();
  const normalizedBody = normalizeBodyForMentions(body);
  const normalizedRoomUserIds = roomUserIds.map((userId) => userId.toLowerCase());
  const roomUserIdSet = new Set(normalizedRoomUserIds);
  const mentionedByMarkup = collectExplicitMentionedUserIds(roomUserIdSet, body);

  if (!normalizedBody) {
    return Array.from(mentionedByMarkup);
  }

  for (const user of users) {
    const userId = String(user._id).toLowerCase();
    if (mentionedByMarkup.has(userId)) {
      continue;
    }

    const normalizedUserName = normalizeName(user.name);
    if (!normalizedUserName) {
      continue;
    }

    const mentionPattern = new RegExp(
      `(^|[^\\p{L}\\p{N}_])@${escapeRegex(normalizedUserName)}(?=$|[^\\p{L}\\p{N}_])`,
      'iu'
    );

    if (mentionPattern.test(normalizedBody)) {
      mentionedByMarkup.add(userId);
    }
  }

  return Array.from(mentionedByMarkup);
}
