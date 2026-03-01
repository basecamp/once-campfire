import type { FastifyInstance } from 'fastify';
import { UserModel } from '../models/user.model.js';
import { verifyMentionSgid } from './mention-token.js';

const ACTION_TEXT_ATTACHMENT_TAG = /<action-text-attachment\b[^>]*?(?:\/>|>[\s\S]*?<\/action-text-attachment>)/gi;
const SGID_ATTRIBUTE = /\bsgid=(["'])(.*?)\1/i;

type MentionReplacement = {
  userId: string;
  name: string;
};

export type NormalizedRichTextBody = {
  html: string;
  plain: string;
  mentioneeIds: string[];
};

function decodeHtmlEntities(input: string) {
  return input
    .replace(/&nbsp;/gi, ' ')
    .replace(/&amp;/gi, '&')
    .replace(/&lt;/gi, '<')
    .replace(/&gt;/gi, '>')
    .replace(/&quot;/gi, '"')
    .replace(/&#39;/gi, "'");
}

function normalizeWhitespace(input: string) {
  return input
    .replace(/\r\n/g, '\n')
    .replace(/[ \t]+\n/g, '\n')
    .replace(/\n{3,}/g, '\n\n')
    .replace(/[ \t]{2,}/g, ' ')
    .trim();
}

function stripTags(input: string) {
  return input
    .replace(/<br\s*\/?>/gi, '\n')
    .replace(/<\/(p|div|li|h[1-6])>/gi, '\n')
    .replace(/<[^>]+>/g, ' ');
}

function sanitizeHtml(input: string) {
  return input
    .replace(/<script[\s\S]*?>[\s\S]*?<\/script>/gi, '')
    .replace(/\son[a-z]+=(\"[^\"]*\"|'[^']*')/gi, '');
}

function escapeHtml(input: string) {
  return input
    .replace(/&/g, '&amp;')
    .replace(/</g, '&lt;')
    .replace(/>/g, '&gt;')
    .replace(/"/g, '&quot;')
    .replace(/'/g, '&#39;');
}

function looksLikeHtml(input: string) {
  return /<[^>]+>/.test(input);
}

async function buildMentionReplacementMap(app: FastifyInstance | undefined, html: string) {
  if (!app) {
    return new Map<string, MentionReplacement>();
  }

  const sgids = Array.from(html.matchAll(ACTION_TEXT_ATTACHMENT_TAG))
    .map((match) => {
      const tokenMatch = SGID_ATTRIBUTE.exec(match[0]);
      SGID_ATTRIBUTE.lastIndex = 0;
      return tokenMatch?.[2] ?? '';
    })
    .filter(Boolean);

  if (sgids.length === 0) {
    return new Map<string, MentionReplacement>();
  }

  const mentionIds = Array.from(
    new Set(
      sgids
        .map((sgid) => verifyMentionSgid(app, sgid))
        .filter((id): id is string => typeof id === 'string' && id.length > 0)
    )
  );

  if (mentionIds.length === 0) {
    return new Map<string, MentionReplacement>();
  }

  const users = await UserModel.find({ _id: { $in: mentionIds } }, { name: 1 }).lean();
  const usersById = new Map(users.map((user) => [String(user._id), user]));

  const replacements = new Map<string, MentionReplacement>();
  for (const sgid of sgids) {
    const userId = verifyMentionSgid(app, sgid);
    if (!userId) {
      continue;
    }

    const user = usersById.get(userId);
    if (!user) {
      continue;
    }

    replacements.set(sgid, {
      userId,
      name: user.name
    });
  }

  return replacements;
}

function attachmentReplacement(tag: string, replacements: Map<string, MentionReplacement>) {
  const tokenMatch = SGID_ATTRIBUTE.exec(tag);
  SGID_ATTRIBUTE.lastIndex = 0;
  const sgid = tokenMatch?.[2] ?? '';
  const replacement = sgid ? replacements.get(sgid) : null;
  return replacement ? `@${replacement.name}` : '';
}

export async function normalizeRichTextBody(rawBody: string, app?: FastifyInstance): Promise<NormalizedRichTextBody> {
  const trimmedBody = typeof rawBody === 'string' ? rawBody.trim() : '';
  if (!trimmedBody) {
    return {
      html: '',
      plain: '',
      mentioneeIds: []
    };
  }

  const normalizedHtml = sanitizeHtml(looksLikeHtml(trimmedBody) ? trimmedBody : `<div>${escapeHtml(trimmedBody)}</div>`);
  const replacements = await buildMentionReplacementMap(app, normalizedHtml);

  const plainWithMentions = normalizedHtml.replace(ACTION_TEXT_ATTACHMENT_TAG, (tag) => attachmentReplacement(tag, replacements));
  const plain = normalizeWhitespace(decodeHtmlEntities(stripTags(plainWithMentions)));
  const mentioneeIds = Array.from(new Set(Array.from(replacements.values()).map((item) => item.userId)));

  return {
    html: normalizedHtml,
    plain,
    mentioneeIds
  };
}

export function plainTextForMessage(message: {
  bodyPlain?: string | null;
  body?: string | null;
  attachment?: {
    filename?: string | null;
  } | null;
}) {
  const primary = message.bodyPlain?.trim() || message.body?.trim();
  if (primary) {
    return primary;
  }

  return message.attachment?.filename?.trim() || '';
}

export function htmlTextForMessage(message: {
  bodyHtml?: string | null;
  bodyPlain?: string | null;
  body?: string | null;
}) {
  const html = message.bodyHtml?.trim();
  if (html) {
    return html;
  }

  const fallback = message.bodyPlain?.trim() || message.body?.trim();
  if (!fallback) {
    return '';
  }

  return `<div>${escapeHtml(fallback)}</div>`;
}
