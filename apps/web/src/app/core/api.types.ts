export interface User {
  id: string;
  name: string;
  emailAddress: string;
  role: 'member' | 'admin' | 'bot';
  status: 'active' | 'deactivated' | 'banned';
  bio: string;
}

export interface UserCandidate {
  id: string;
  name: string;
  emailAddress?: string;
  status?: string;
}

export interface Boost {
  id: string;
  messageId: string;
  boosterId: string;
  content: string;
  actorName?: string;
  createdAt: string;
}

export interface Message {
  id: string;
  clientMessageId: string;
  body: string;
  roomId: string;
  creatorId: string;
  createdAt: string;
  creator?: {
    name: string;
  };
  boosts?: Boost[];
  boostSummary?: Record<string, number>;
}

export interface Room {
  id: string;
  name: string;
  type: 'open' | 'closed' | 'direct';
  involvement: 'invisible' | 'nothing' | 'mentions' | 'everything';
  unreadAt?: string;
  createdAt: string;
  updatedAt: string;
}

export interface SearchHistoryItem {
  id: string;
  query: string;
  createdAt: string;
}

export interface SearchResult {
  id: string;
  roomId: string;
  creatorId: string;
  creatorName: string;
  body: string;
  createdAt: string;
}

export interface Webhook {
  id: string;
  url: string;
  active: boolean;
  events: Array<'message.created' | 'message.boosted'>;
  roomIds: string[];
  lastSuccessAt?: string;
  lastError?: string;
  createdAt: string;
}

export type RealtimeEventPayloadMap = {
  connected: { ok: boolean; now: string };
  heartbeat: { now: string };
  'room.created': { room: Room };
  'message.created': { message: Message };
  'message.boosted': { messageId: string; boost: Boost };
};
