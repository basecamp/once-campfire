import { BoostModel } from '../models/boost.model.js';
import { UserModel } from '../models/user.model.js';
import { serializeMessageAttachment } from '../services/message-attachment.js';
import { plainTextForMessage, htmlTextForMessage } from '../services/rich-text.js';

export async function serializeMessages(messages: Array<{
  _id: unknown;
  clientMessageId: string;
  body: string;
  bodyHtml?: string;
  bodyPlain?: string;
  mentioneeIds?: unknown[];
  attachment?: {
    contentType: string;
    filename: string;
    byteSize: number;
    width?: number | null;
    height?: number | null;
    previewable?: boolean | null;
    variable?: boolean | null;
  } | null;
  roomId: unknown;
  creatorId: unknown;
  createdAt: Date;
  updatedAt: Date;
}>) {
  const messageIds = messages.map((message) => message._id);
  const creatorIds = Array.from(new Set(messages.map((message) => String(message.creatorId))));

  const [creators, boosts] = await Promise.all([
    creatorIds.length > 0 ? UserModel.find({ _id: { $in: creatorIds } }, { name: 1 }).lean() : [],
    messageIds.length > 0 ? BoostModel.find({ messageId: { $in: messageIds } }).sort({ createdAt: 1 }).lean() : []
  ]);

  const creatorsById = new Map(creators.map((creator) => [String(creator._id), creator]));
  const boostsByMessageId = new Map<string, typeof boosts>();
  for (const boost of boosts) {
    const key = String(boost.messageId);
    const prev = boostsByMessageId.get(key) ?? [];
    prev.push(boost);
    boostsByMessageId.set(key, prev);
  }

  return messages.map((message) => {
    const messageBoosts = boostsByMessageId.get(String(message._id)) ?? [];
    const summary = messageBoosts.reduce<Record<string, number>>((acc, boost) => {
      const key = boost.content;
      acc[key] = (acc[key] ?? 0) + 1;
      return acc;
    }, {});

    const plainBody = plainTextForMessage(message);
    const richBodyHtml = htmlTextForMessage(message);

    return {
      id: String(message._id),
      clientMessageId: message.clientMessageId,
      body: plainBody,
      bodyHtml: richBodyHtml,
      body_html: richBodyHtml,
      bodyPlain: plainBody,
      body_plain: plainBody,
      roomId: String(message.roomId),
      creatorId: String(message.creatorId),
      creator: creatorsById.get(String(message.creatorId))
        ? {
            name: creatorsById.get(String(message.creatorId))?.name ?? 'Unknown'
          }
        : undefined,
      boosts: messageBoosts.map((boost) => ({
        id: String(boost._id),
        content: boost.content,
        boosterId: String(boost.boosterId),
        createdAt: boost.createdAt
      })),
      boostSummary: summary,
      attachment: message.attachment ? serializeMessageAttachment(String(message._id), message.attachment) : undefined,
      createdAt: message.createdAt,
      updatedAt: message.updatedAt
    };
  });
}
