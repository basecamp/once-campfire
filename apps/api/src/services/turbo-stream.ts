import type { RealtimeEvent } from '../realtime/event-bus.js';
import { decodeRailsMessageUnsafe, verifyRailsMessage } from './rails-signed-message.js';

function escapeHtml(value: string) {
  return value
    .replace(/&/g, '&amp;')
    .replace(/</g, '&lt;')
    .replace(/>/g, '&gt;')
    .replace(/"/g, '&quot;')
    .replace(/'/g, '&#39;');
}

function buildTurboStream(action: 'append' | 'prepend' | 'replace' | 'remove', target: string, html = '') {
  if (action === 'remove') {
    return `<turbo-stream action="remove" target="${escapeHtml(target)}"></turbo-stream>`;
  }

  return `<turbo-stream action="${action}" target="${escapeHtml(target)}"><template>${html}</template></turbo-stream>`;
}

function asRecord(input: unknown) {
  return input && typeof input === 'object' ? (input as Record<string, unknown>) : null;
}

function stringField(record: Record<string, unknown> | null, key: string) {
  const value = record?.[key];
  return typeof value === 'string' ? value : '';
}

function normalizeStreamName(raw: unknown) {
  if (typeof raw !== 'string') {
    return null;
  }

  const value = raw.trim();
  return value || null;
}

function extractStreamMessageValue(payload: unknown) {
  const normalized = normalizeStreamName(payload);
  if (normalized) {
    return normalized;
  }

  if (!payload || typeof payload !== 'object') {
    return null;
  }

  const data = payload as Record<string, unknown>;
  return normalizeStreamName(data.stream_name) ?? normalizeStreamName(data.name);
}

export function resolveTurboStreamName(signedStreamName?: string, streamName?: string) {
  if (streamName) {
    return streamName;
  }

  if (!signedStreamName) {
    return null;
  }

  const verified = verifyRailsMessage<unknown>(signedStreamName, { purpose: 'turbo-stream' });
  const verifiedStreamName = extractStreamMessageValue(verified);
  if (verifiedStreamName) {
    return verifiedStreamName;
  }

  const unsafe = decodeRailsMessageUnsafe<unknown>(signedStreamName, { purpose: 'turbo-stream' });
  const unsafeStreamName = extractStreamMessageValue(unsafe);
  if (unsafeStreamName) {
    return unsafeStreamName;
  }

  return null;
}

export function extractRoomIdFromTurboStreamName(streamName: string) {
  const modelMatch = streamName.match(/\/Room\/([a-f\d]{24})(?::|$)/i);
  if (modelMatch?.[1]) {
    return modelMatch[1];
  }

  const genericMatch = streamName.match(/([a-f\d]{24})/i);
  return genericMatch?.[1] ?? null;
}

function streamMatchesRooms(streamName: string, userId: string) {
  if (streamName === 'rooms') {
    return true;
  }

  if (streamName.includes(':rooms') || streamName.endsWith('/rooms')) {
    if (streamName.includes('/User/')) {
      return streamName.includes(`/User/${userId}`);
    }

    return streamName.includes(userId) || streamName.includes('user_') || streamName.startsWith('users:');
  }

  return false;
}

function streamMatchesRoomMessages(streamName: string, roomId: string) {
  if (!streamName.includes('messages')) {
    return false;
  }

  return streamName.includes(roomId) || streamName.includes(`/Room/${roomId}`);
}

function roomListItemHtml(room: { id: string; name?: string; type?: string }) {
  const roomName = room.name?.trim() || 'Room';
  return `<a id="list_room_${escapeHtml(room.id)}" href="/rooms/${escapeHtml(room.id)}">${escapeHtml(roomName)}</a>`;
}

function messageListItemHtml(message: { id: string; clientMessageId?: string; body?: string; bodyPlain?: string }) {
  const key = message.clientMessageId || message.id;
  const bodyText = message.bodyPlain?.trim() || message.body?.trim() || '';

  return `<article id="message_${escapeHtml(key)}" class="message"><div id="presentation_message_${escapeHtml(key)}">${escapeHtml(bodyText)}</div></article>`;
}

function messagePresentationHtml(message: { id: string; clientMessageId?: string; body?: string; bodyPlain?: string }) {
  const key = message.clientMessageId || message.id;
  const bodyText = message.bodyPlain?.trim() || message.body?.trim() || '';
  return `<div id="presentation_message_${escapeHtml(key)}">${escapeHtml(bodyText)}</div>`;
}

function boostHtml(boost: { id: string; content?: string }) {
  return `<span id="boost_${escapeHtml(boost.id)}">${escapeHtml(boost.content?.trim() || '')}</span>`;
}

export function turboStreamMessageForEvent(event: RealtimeEvent, streamName: string, userId: string) {
  if (event.userIds && !event.userIds.includes(userId)) {
    return null;
  }

  if (event.type === 'room.created' || event.type === 'room.updated' || event.type === 'room.removed') {
    if (!streamMatchesRooms(streamName, userId)) {
      return null;
    }

    if (event.type === 'room.removed') {
      const roomId = stringField(asRecord(event.payload), 'roomId') || event.roomId;
      return buildTurboStream('remove', `list_room_${roomId}`);
    }

    const room = asRecord(asRecord(event.payload)?.room);
    if (!room) {
      return null;
    }

    const serializedRoom = {
      id: stringField(room, 'id'),
      name: stringField(room, 'name'),
      type: stringField(room, 'type')
    };
    if (!serializedRoom.id) {
      return null;
    }

    if (event.type === 'room.updated') {
      return buildTurboStream('replace', `list_room_${serializedRoom.id}`, roomListItemHtml(serializedRoom));
    }

    const target = serializedRoom.type === 'direct' ? 'direct_rooms' : 'shared_rooms';
    return buildTurboStream('prepend', target, roomListItemHtml(serializedRoom));
  }

  if (
    event.type === 'message.created' ||
    event.type === 'message.updated' ||
    event.type === 'message.removed' ||
    event.type === 'message.boosted' ||
    event.type === 'message.boost_removed'
  ) {
    if (!streamMatchesRoomMessages(streamName, event.roomId)) {
      return null;
    }

    if (event.type === 'message.removed') {
      const payload = asRecord(event.payload);
      const key = stringField(payload, 'clientMessageId') || stringField(payload, 'messageId');
      if (!key) {
        return null;
      }

      return buildTurboStream('remove', `message_${key}`);
    }

    if (event.type === 'message.boost_removed') {
      const payload = asRecord(event.payload);
      const boostId = stringField(payload, 'boostId');
      if (!boostId) {
        return null;
      }

      return buildTurboStream('remove', `boost_${boostId}`);
    }

    if (event.type === 'message.boosted') {
      const payload = asRecord(event.payload);
      const messageId = stringField(payload, 'messageId');
      const clientMessageId = stringField(payload, 'clientMessageId');
      const boost = asRecord(payload?.boost);
      if (!messageId || !boost) {
        return null;
      }

      const serializedBoost = {
        id: stringField(boost, 'id'),
        content: stringField(boost, 'content')
      };
      if (!serializedBoost.id) {
        return null;
      }

      return buildTurboStream(
        'append',
        `boosts_message_${clientMessageId || messageId}`,
        boostHtml(serializedBoost)
      );
    }

    const payload = asRecord(event.payload);
    const message = asRecord(payload?.message);
    if (!message) {
      return null;
    }

    const serializedMessage = {
      id: stringField(message, 'id'),
      clientMessageId: stringField(message, 'clientMessageId'),
      body: stringField(message, 'body'),
      bodyPlain: stringField(message, 'bodyPlain') || stringField(message, 'body_plain')
    };
    if (!serializedMessage.id) {
      return null;
    }

    if (event.type === 'message.updated') {
      return buildTurboStream(
        'replace',
        `presentation_message_${serializedMessage.clientMessageId || serializedMessage.id}`,
        messagePresentationHtml(serializedMessage)
      );
    }

    return buildTurboStream('append', `messages_room_${event.roomId}`, messageListItemHtml(serializedMessage));
  }

  return null;
}
