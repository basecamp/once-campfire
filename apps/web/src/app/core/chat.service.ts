import { HttpClient } from '@angular/common/http';
import { Injectable, inject } from '@angular/core';
import { firstValueFrom } from 'rxjs';
import { environment } from '../../environments/environment';
import {
  type Boost,
  type Message,
  type Room,
  type SearchHistoryItem,
  type SearchResult,
  type UserCandidate,
  type Webhook
} from './api.types';

interface RoomsResponse { rooms: Room[] }
interface RoomResponse { room: Room }
interface MessagesResponse { messages: Message[] }
interface MessageResponse { message: Message }
interface BoostResponse { boost: Boost }
interface SearchRunResponse { query: string; results: SearchResult[] }
interface SearchHistoryResponse { searches: SearchHistoryItem[] }
interface UsersResponse { users: UserCandidate[] }
interface WebhooksResponse { webhooks: Webhook[] }
interface WebhookResponse { webhook: Webhook }

@Injectable({ providedIn: 'root' })
export class ChatService {
  private readonly http = inject(HttpClient);
  private readonly base = environment.apiBaseUrl;

  async listRooms(): Promise<Room[]> {
    const { rooms } = await firstValueFrom(
      this.http.get<RoomsResponse>(`${this.base}/rooms`)
    );
    return rooms;
  }

  async createRoom(name: string, type: 'open' | 'closed' = 'open'): Promise<Room> {
    const { room } = await firstValueFrom(
      this.http.post<RoomResponse>(`${this.base}/rooms`, { name, type, userIds: [] })
    );
    return room;
  }

  async createDirectRoom(userId: string): Promise<Room> {
    const { room } = await firstValueFrom(
      this.http.post<RoomResponse>(`${this.base}/rooms/directs`, { userId })
    );
    return room;
  }

  async listMessages(roomId: string): Promise<Message[]> {
    const { messages } = await firstValueFrom(
      this.http.get<MessagesResponse>(`${this.base}/rooms/${roomId}/messages`)
    );
    return messages;
  }

  async sendMessage(roomId: string, body: string): Promise<Message> {
    const { message } = await firstValueFrom(
      this.http.post<MessageResponse>(`${this.base}/rooms/${roomId}/messages`, { body })
    );
    return message;
  }

  async addBoost(messageId: string, content: string): Promise<Boost> {
    const { boost } = await firstValueFrom(
      this.http.post<BoostResponse>(`${this.base}/messages/${messageId}/boosts`, { content })
    );
    return boost;
  }

  async removeBoost(messageId: string, boostId: string): Promise<void> {
    await firstValueFrom(
      this.http.delete(`${this.base}/messages/${messageId}/boosts/${boostId}`)
    );
  }

  async searchUsers(query: string): Promise<UserCandidate[]> {
    const { users } = await firstValueFrom(
      this.http.get<UsersResponse>(`${this.base}/users`, { params: { query } })
    );
    return users;
  }

  async runSearch(query: string, roomId?: string): Promise<SearchResult[]> {
    const { results } = await firstValueFrom(
      this.http.post<SearchRunResponse>(`${this.base}/searches`, {
        query,
        ...(roomId ? { roomId } : {})
      })
    );
    return results;
  }

  async listSearchHistory(): Promise<SearchHistoryItem[]> {
    const { searches } = await firstValueFrom(
      this.http.get<SearchHistoryResponse>(`${this.base}/searches`)
    );
    return searches;
  }

  async clearSearchHistory(): Promise<void> {
    await firstValueFrom(this.http.delete(`${this.base}/searches/clear`));
  }

  async listWebhooks(): Promise<Webhook[]> {
    const { webhooks } = await firstValueFrom(
      this.http.get<WebhooksResponse>(`${this.base}/webhooks`)
    );
    return webhooks;
  }

  async createWebhook(url: string): Promise<Webhook> {
    const { webhook } = await firstValueFrom(
      this.http.post<WebhookResponse>(`${this.base}/webhooks`, {
        url,
        events: ['message.created', 'message.boosted'],
        roomIds: []
      })
    );
    return webhook;
  }

  async deleteWebhook(webhookId: string): Promise<void> {
    await firstValueFrom(this.http.delete(`${this.base}/webhooks/${webhookId}`));
  }

  async testWebhook(webhookId: string): Promise<void> {
    await firstValueFrom(
      this.http.post(`${this.base}/webhooks/${webhookId}/test`, {})
    );
  }
}
