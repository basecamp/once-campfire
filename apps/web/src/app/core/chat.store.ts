import { Injectable, computed, inject, signal } from '@angular/core';
import { ChatService } from './chat.service';
import { RealtimeService } from './realtime.service';
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

@Injectable({ providedIn: 'root' })
export class ChatStore {
  private readonly chatService = inject(ChatService);
  private readonly realtime = inject(RealtimeService);

  readonly rooms = signal<Room[]>([]);
  readonly messages = signal<Message[]>([]);
  readonly selectedRoomId = signal<string | null>(null);
  readonly directCandidates = signal<UserCandidate[]>([]);
  readonly searchResults = signal<SearchResult[]>([]);
  readonly searchHistory = signal<SearchHistoryItem[]>([]);
  readonly webhooks = signal<Webhook[]>([]);
  readonly error = signal('');

  readonly selectedRoom = computed(() => {
    const id = this.selectedRoomId();
    return id ? this.rooms().find((r) => r.id === id) ?? null : null;
  });

  async init(): Promise<void> {
    await Promise.all([this.loadRooms(), this.refreshSearchHistory(), this.refreshWebhooks()]);
  }

  reset(): void {
    this.realtime.disconnect();
    this.rooms.set([]);
    this.messages.set([]);
    this.selectedRoomId.set(null);
    this.directCandidates.set([]);
    this.searchResults.set([]);
    this.searchHistory.set([]);
    this.webhooks.set([]);
    this.error.set('');
  }

  // ── Rooms ──

  async loadRooms(): Promise<void> {
    const rooms = await this.chatService.listRooms();
    this.rooms.set(this.dedup(rooms));

    if (rooms.length > 0 && !this.selectedRoomId()) {
      await this.selectRoom(rooms[0].id);
    } else if (rooms.length === 0) {
      this.messages.set([]);
      this.selectedRoomId.set(null);
      this.realtime.disconnect();
    }
  }

  async selectRoom(roomId: string): Promise<void> {
    this.selectedRoomId.set(roomId);
    this.error.set('');
    this.realtime.disconnect();

    try {
      const messages = await this.chatService.listMessages(roomId);
      this.messages.set(messages);
      this.connectStream(roomId);
    } catch {
      this.error.set('Не удалось загрузить сообщения комнаты.');
      this.messages.set([]);
    }
  }

  async createRoom(name: string, type: 'open' | 'closed'): Promise<void> {
    this.error.set('');
    try {
      const room = await this.chatService.createRoom(name, type);
      this.rooms.set(this.dedup([room, ...this.rooms()]));
      await this.selectRoom(room.id);
    } catch {
      this.error.set('Не удалось создать комнату.');
    }
  }

  // ── Direct Messages ──

  async findDirectCandidates(query: string): Promise<void> {
    try {
      const users = await this.chatService.searchUsers(query);
      this.directCandidates.set(users);
    } catch {
      this.error.set('Не удалось найти пользователей.');
    }
  }

  async createDirectRoom(userId: string): Promise<void> {
    try {
      const room = await this.chatService.createDirectRoom(userId);
      this.rooms.set(this.dedup([room, ...this.rooms()]));
      this.directCandidates.set([]);
      await this.selectRoom(room.id);
    } catch {
      this.error.set('Не удалось создать direct room.');
    }
  }

  // ── Messages ──

  async sendMessage(body: string): Promise<void> {
    const roomId = this.selectedRoomId();
    if (!roomId) return;

    try {
      const message = await this.chatService.sendMessage(roomId, body);
      this.upsertMessage(message);
    } catch {
      this.error.set('Не удалось отправить сообщение.');
    }
  }

  async boostMessage(messageId: string, content: string): Promise<void> {
    try {
      const boost = await this.chatService.addBoost(messageId, content);
      this.applyBoost(boost.messageId, boost);
    } catch {
      this.error.set('Не удалось поставить boost.');
    }
  }

  // ── Search ──

  async runSearch(query: string, scope: 'current' | 'all'): Promise<void> {
    const roomId = scope === 'current' ? this.selectedRoomId() ?? undefined : undefined;
    try {
      const results = await this.chatService.runSearch(query, roomId);
      this.searchResults.set(results);
      await this.refreshSearchHistory();
    } catch {
      this.error.set('Ошибка поиска.');
    }
  }

  async clearSearchHistory(): Promise<void> {
    try {
      await this.chatService.clearSearchHistory();
      this.searchHistory.set([]);
    } catch {
      this.error.set('Не удалось очистить историю поиска.');
    }
  }

  // ── Webhooks ──

  async createWebhook(url: string): Promise<void> {
    try {
      const webhook = await this.chatService.createWebhook(url);
      this.webhooks.set([webhook, ...this.webhooks()]);
    } catch {
      this.error.set('Не удалось создать webhook.');
    }
  }

  async testWebhook(id: string): Promise<void> {
    try {
      await this.chatService.testWebhook(id);
      await this.refreshWebhooks();
    } catch {
      this.error.set('Webhook test завершился ошибкой.');
    }
  }

  async deleteWebhook(id: string): Promise<void> {
    try {
      await this.chatService.deleteWebhook(id);
      this.webhooks.set(this.webhooks().filter((w) => w.id !== id));
    } catch {
      this.error.set('Не удалось удалить webhook.');
    }
  }

  // ── Private ──

  private async refreshSearchHistory(): Promise<void> {
    this.searchHistory.set(await this.chatService.listSearchHistory());
  }

  private async refreshWebhooks(): Promise<void> {
    this.webhooks.set(await this.chatService.listWebhooks());
  }

  private connectStream(roomId: string): void {
    this.realtime.connect(roomId, {
      onEvent: (event, payload) => this.handleRealtimeEvent(event, payload),
      onError: () =>
        this.error.set('Realtime поток потерян. Обновите страницу или выберите комнату снова.')
    });
  }

  private handleRealtimeEvent<T extends keyof RealtimeEventPayloadMap>(
    event: T,
    payload: RealtimeEventPayloadMap[T]
  ): void {
    if (event === 'message.created') {
      this.upsertMessage((payload as RealtimeEventPayloadMap['message.created']).message);
      return;
    }

    if (event === 'message.boosted') {
      const data = payload as RealtimeEventPayloadMap['message.boosted'];
      this.applyBoost(data.messageId, data.boost);
      return;
    }

    if (event === 'room.created') {
      const room = (payload as RealtimeEventPayloadMap['room.created']).room;
      this.rooms.set(this.dedup([room, ...this.rooms()]));
    }
  }

  private upsertMessage(message: Message): void {
    this.messages.update((current) => {
      const idx = current.findIndex((m) => m.id === message.id);
      if (idx >= 0) {
        const copy = [...current];
        copy[idx] = { ...copy[idx], ...message };
        return copy;
      }
      return [...current, message];
    });
  }

  private applyBoost(messageId: string, boost: Boost): void {
    this.messages.update((items) =>
      items.map((item) => {
        if (item.id !== messageId) return item;

        const boosts = item.boosts ?? [];
        const exists = boosts.some((b) => b.id === boost.id);
        const nextBoosts = exists ? boosts : [...boosts, boost];
        const summary = { ...(item.boostSummary ?? {}) };
        summary[boost.content] = (summary[boost.content] ?? 0) + (exists ? 0 : 1);

        return { ...item, boosts: nextBoosts, boostSummary: summary };
      })
    );
  }

  private dedup(rooms: Room[]): Room[] {
    const map = new Map<string, Room>();
    for (const room of rooms) {
      map.set(room.id, room);
    }
    return Array.from(map.values());
  }
}
