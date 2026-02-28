import { Injectable } from '@angular/core';
import { HttpClient } from '@angular/common/http';
import { firstValueFrom } from 'rxjs';
import { environment } from '../../environments/environment';
import {
  type Boost,
  type Message,
  type RealtimeEventPayloadMap,
  type Room,
  type SearchHistoryItem,
  type SearchResult,
  type UserCandidate,
  type Webhook
} from './api.types';

interface RoomsResponse {
  rooms: Room[];
}

interface MessagesResponse {
  messages: Message[];
}

interface RoomResponse {
  room: Room;
}

interface MessageResponse {
  message: Message;
}

interface BoostResponse {
  boost: Boost;
}

interface SearchHistoryResponse {
  searches: SearchHistoryItem[];
}

interface SearchRunResponse {
  query: string;
  results: SearchResult[];
}

interface UsersResponse {
  users: UserCandidate[];
}

interface WebhooksResponse {
  webhooks: Webhook[];
}

interface WebhookResponse {
  webhook: Webhook;
}

type RealtimeEventName = keyof RealtimeEventPayloadMap;

@Injectable({ providedIn: 'root' })
export class ChatService {
  constructor(private readonly http: HttpClient) {}

  async listRooms(): Promise<Room[]> {
    const response = await firstValueFrom(
      this.http.get<RoomsResponse>(`${environment.apiBaseUrl}/rooms`, {
        withCredentials: true
      })
    );

    return response.rooms;
  }

  async createRoom(name: string, type: 'open' | 'closed' = 'open'): Promise<Room> {
    const response = await firstValueFrom(
      this.http.post<RoomResponse>(
        `${environment.apiBaseUrl}/rooms`,
        {
          name,
          type,
          userIds: []
        },
        {
          withCredentials: true
        }
      )
    );

    return response.room;
  }

  async createDirectRoom(userId: string): Promise<Room> {
    const response = await firstValueFrom(
      this.http.post<RoomResponse>(
        `${environment.apiBaseUrl}/rooms/directs`,
        { userId },
        {
          withCredentials: true
        }
      )
    );

    return response.room;
  }

  async listMessages(roomId: string): Promise<Message[]> {
    const response = await firstValueFrom(
      this.http.get<MessagesResponse>(`${environment.apiBaseUrl}/rooms/${roomId}/messages`, {
        withCredentials: true
      })
    );

    return response.messages;
  }

  async sendMessage(roomId: string, body: string): Promise<Message> {
    const response = await firstValueFrom(
      this.http.post<MessageResponse>(
        `${environment.apiBaseUrl}/rooms/${roomId}/messages`,
        {
          body
        },
        {
          withCredentials: true
        }
      )
    );

    return response.message;
  }

  async addBoost(messageId: string, content: string): Promise<Boost> {
    const response = await firstValueFrom(
      this.http.post<BoostResponse>(
        `${environment.apiBaseUrl}/messages/${messageId}/boosts`,
        { content },
        { withCredentials: true }
      )
    );

    return response.boost;
  }

  async removeBoost(messageId: string, boostId: string): Promise<void> {
    await firstValueFrom(
      this.http.delete(`${environment.apiBaseUrl}/messages/${messageId}/boosts/${boostId}`, {
        withCredentials: true
      })
    );
  }

  async searchUsers(query: string): Promise<UserCandidate[]> {
    const response = await firstValueFrom(
      this.http.get<UsersResponse>(`${environment.apiBaseUrl}/users`, {
        withCredentials: true,
        params: {
          query
        }
      })
    );

    return response.users;
  }

  async runSearch(query: string, roomId?: string): Promise<SearchResult[]> {
    const response = await firstValueFrom(
      this.http.post<SearchRunResponse>(
        `${environment.apiBaseUrl}/searches`,
        {
          query,
          ...(roomId ? { roomId } : {})
        },
        {
          withCredentials: true
        }
      )
    );

    return response.results;
  }

  async listSearchHistory(): Promise<SearchHistoryItem[]> {
    const response = await firstValueFrom(
      this.http.get<SearchHistoryResponse>(`${environment.apiBaseUrl}/searches`, {
        withCredentials: true
      })
    );

    return response.searches;
  }

  async clearSearchHistory(): Promise<void> {
    await firstValueFrom(
      this.http.delete(`${environment.apiBaseUrl}/searches/clear`, {
        withCredentials: true
      })
    );
  }

  async listWebhooks(): Promise<Webhook[]> {
    const response = await firstValueFrom(
      this.http.get<WebhooksResponse>(`${environment.apiBaseUrl}/webhooks`, {
        withCredentials: true
      })
    );

    return response.webhooks;
  }

  async createWebhook(url: string): Promise<Webhook> {
    const response = await firstValueFrom(
      this.http.post<WebhookResponse>(
        `${environment.apiBaseUrl}/webhooks`,
        {
          url,
          events: ['message.created', 'message.boosted'],
          roomIds: []
        },
        {
          withCredentials: true
        }
      )
    );

    return response.webhook;
  }

  async deleteWebhook(webhookId: string): Promise<void> {
    await firstValueFrom(
      this.http.delete(`${environment.apiBaseUrl}/webhooks/${webhookId}`, {
        withCredentials: true
      })
    );
  }

  async testWebhook(webhookId: string): Promise<void> {
    await firstValueFrom(
      this.http.post(
        `${environment.apiBaseUrl}/webhooks/${webhookId}/test`,
        {},
        {
          withCredentials: true
        }
      )
    );
  }

  openRoomStream(
    roomId: string,
    handlers: {
      onEvent: <T extends RealtimeEventName>(event: T, payload: RealtimeEventPayloadMap[T]) => void;
      onError?: () => void;
    }
  ): () => void {
    const streamUrl = `${environment.apiBaseUrl}/realtime/stream?roomId=${encodeURIComponent(roomId)}`;
    const source = new EventSource(streamUrl, { withCredentials: true });

    const listen = <T extends RealtimeEventName>(event: T) => {
      source.addEventListener(event, (rawEvent) => {
        const payload = JSON.parse((rawEvent as MessageEvent<string>).data) as RealtimeEventPayloadMap[T];
        handlers.onEvent(event, payload);
      });
    };

    listen('connected');
    listen('heartbeat');
    listen('room.created');
    listen('message.created');
    listen('message.boosted');

    source.onerror = () => {
      handlers.onError?.();
    };

    return () => {
      source.close();
    };
  }
}
