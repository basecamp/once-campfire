import { CommonModule } from '@angular/common';
import { Component, OnDestroy, computed, inject, signal } from '@angular/core';
import { FormBuilder, ReactiveFormsModule, Validators } from '@angular/forms';
import { AuthService } from './core/auth.service';
import { ChatService } from './core/chat.service';
import {
  type Boost,
  type Message,
  type RealtimeEventPayloadMap,
  type Room,
  type SearchHistoryItem,
  type SearchResult,
  type UserCandidate,
  type Webhook
} from './core/api.types';

@Component({
  selector: 'app-root',
  imports: [CommonModule, ReactiveFormsModule],
  templateUrl: './app.html',
  styleUrl: './app.scss'
})
export class App implements OnDestroy {
  protected readonly authService = inject(AuthService);
  private readonly chatService = inject(ChatService);
  private readonly formBuilder = inject(FormBuilder);

  private streamCleanup: (() => void) | null = null;

  protected readonly authMode = signal<'login' | 'register'>('login');
  protected readonly rooms = signal<Room[]>([]);
  protected readonly messages = signal<Message[]>([]);
  protected readonly selectedRoomId = signal<string | null>(null);
  protected readonly directCandidates = signal<UserCandidate[]>([]);
  protected readonly searchResults = signal<SearchResult[]>([]);
  protected readonly searchHistory = signal<SearchHistoryItem[]>([]);
  protected readonly webhooks = signal<Webhook[]>([]);

  protected readonly authError = signal<string>('');
  protected readonly chatError = signal<string>('');
  protected readonly loading = signal<boolean>(true);

  protected readonly authForm = this.formBuilder.nonNullable.group({
    name: ['', [Validators.minLength(2)]],
    emailAddress: ['', [Validators.required, Validators.email]],
    password: ['', [Validators.required, Validators.minLength(8)]]
  });

  protected readonly roomForm = this.formBuilder.nonNullable.group({
    name: ['', [Validators.required, Validators.minLength(2), Validators.maxLength(80)]],
    type: ['open' as 'open' | 'closed']
  });

  protected readonly directForm = this.formBuilder.nonNullable.group({
    query: ['', [Validators.required, Validators.minLength(2)]]
  });

  protected readonly messageForm = this.formBuilder.nonNullable.group({
    body: ['', [Validators.required, Validators.maxLength(4000)]]
  });

  protected readonly searchForm = this.formBuilder.nonNullable.group({
    query: ['', [Validators.required, Validators.minLength(2)]],
    scope: ['current' as 'current' | 'all']
  });

  protected readonly webhookForm = this.formBuilder.nonNullable.group({
    url: ['', [Validators.required]]
  });

  protected readonly selectedRoom = computed(() => {
    const roomId = this.selectedRoomId();
    if (!roomId) {
      return null;
    }

    return this.rooms().find((room) => room.id === roomId) ?? null;
  });

  constructor() {
    void this.bootstrap();
  }

  ngOnDestroy(): void {
    this.closeStream();
  }

  protected switchMode(mode: 'login' | 'register') {
    this.authMode.set(mode);
    this.authError.set('');
  }

  protected async submitAuth(): Promise<void> {
    this.authError.set('');

    if (this.authForm.invalid) {
      this.authError.set('Заполните форму корректно');
      return;
    }

    const { name, emailAddress, password } = this.authForm.getRawValue();

    try {
      if (this.authMode() === 'register') {
        await this.authService.register(name, emailAddress, password);
      } else {
        await this.authService.login(emailAddress, password);
      }

      await this.loadWorkspaceData();
      await this.loadRooms();
    } catch {
      this.authError.set('Ошибка авторизации. Проверьте данные и попробуйте снова.');
    }
  }

  protected async createRoom(): Promise<void> {
    this.chatError.set('');

    if (this.roomForm.invalid) {
      this.chatError.set('Имя комнаты должно быть не короче 2 символов.');
      return;
    }

    try {
      const payload = this.roomForm.getRawValue();
      const room = await this.chatService.createRoom(payload.name, payload.type);

      this.rooms.set(this.mergeRooms([room, ...this.rooms()]));
      this.roomForm.controls.name.setValue('');

      await this.selectRoom(room.id);
    } catch {
      this.chatError.set('Не удалось создать комнату.');
    }
  }

  protected async findDirectCandidates(): Promise<void> {
    if (this.directForm.invalid) {
      return;
    }

    const query = this.directForm.controls.query.value.trim();
    if (!query) {
      return;
    }

    try {
      const users = await this.chatService.searchUsers(query);
      this.directCandidates.set(users);
    } catch {
      this.chatError.set('Не удалось найти пользователей.');
    }
  }

  protected async createDirectRoomWith(userId: string): Promise<void> {
    try {
      const room = await this.chatService.createDirectRoom(userId);
      this.rooms.set(this.mergeRooms([room, ...this.rooms()]));
      await this.selectRoom(room.id);
    } catch {
      this.chatError.set('Не удалось создать direct room.');
    }
  }

  protected async selectRoom(roomId: string): Promise<void> {
    this.selectedRoomId.set(roomId);
    this.chatError.set('');
    this.closeStream();

    try {
      const messages = await this.chatService.listMessages(roomId);
      this.messages.set(messages);
      this.openStream(roomId);
    } catch {
      this.chatError.set('Не удалось загрузить сообщения комнаты.');
      this.messages.set([]);
    }
  }

  protected async sendMessage(): Promise<void> {
    const roomId = this.selectedRoomId();
    if (!roomId) {
      return;
    }

    if (this.messageForm.invalid) {
      return;
    }

    const body = this.messageForm.controls.body.value.trim();
    if (!body) {
      return;
    }

    try {
      const message = await this.chatService.sendMessage(roomId, body);
      this.upsertMessage(message);
      this.messageForm.controls.body.setValue('');
    } catch {
      this.chatError.set('Не удалось отправить сообщение.');
    }
  }

  protected async boostMessage(messageId: string, content: string = '👍'): Promise<void> {
    try {
      const boost = await this.chatService.addBoost(messageId, content);
      this.applyBoost(boost.messageId, boost);
    } catch {
      this.chatError.set('Не удалось поставить boost.');
    }
  }

  protected async runSearch(): Promise<void> {
    if (this.searchForm.invalid) {
      return;
    }

    const query = this.searchForm.controls.query.value.trim();
    if (!query) {
      return;
    }

    const scope = this.searchForm.controls.scope.value;
    const roomId = scope === 'current' ? this.selectedRoomId() ?? undefined : undefined;

    try {
      const results = await this.chatService.runSearch(query, roomId);
      this.searchResults.set(results);
      await this.refreshSearchHistory();
    } catch {
      this.chatError.set('Ошибка поиска.');
    }
  }

  protected async clearSearchHistory(): Promise<void> {
    try {
      await this.chatService.clearSearchHistory();
      this.searchHistory.set([]);
    } catch {
      this.chatError.set('Не удалось очистить историю поиска.');
    }
  }

  protected async createWebhook(): Promise<void> {
    const url = this.webhookForm.controls.url.value.trim();
    if (!url) {
      return;
    }

    try {
      const webhook = await this.chatService.createWebhook(url);
      this.webhooks.set([webhook, ...this.webhooks()]);
      this.webhookForm.controls.url.setValue('');
    } catch {
      this.chatError.set('Не удалось создать webhook.');
    }
  }

  protected async testWebhook(webhookId: string): Promise<void> {
    try {
      await this.chatService.testWebhook(webhookId);
      await this.refreshWebhooks();
    } catch {
      this.chatError.set('Webhook test завершился ошибкой.');
    }
  }

  protected async deleteWebhook(webhookId: string): Promise<void> {
    try {
      await this.chatService.deleteWebhook(webhookId);
      this.webhooks.set(this.webhooks().filter((webhook) => webhook.id !== webhookId));
    } catch {
      this.chatError.set('Не удалось удалить webhook.');
    }
  }

  protected async logout(): Promise<void> {
    await this.authService.logout();
    this.closeStream();
    this.rooms.set([]);
    this.messages.set([]);
    this.directCandidates.set([]);
    this.searchResults.set([]);
    this.searchHistory.set([]);
    this.webhooks.set([]);
    this.selectedRoomId.set(null);
    this.authForm.controls.password.setValue('');
  }

  private async bootstrap(): Promise<void> {
    try {
      const user = await this.authService.loadCurrentUser();
      if (user) {
        await this.loadWorkspaceData();
        await this.loadRooms();
      }
    } finally {
      this.loading.set(false);
    }
  }

  private async loadWorkspaceData(): Promise<void> {
    await Promise.all([this.refreshSearchHistory(), this.refreshWebhooks()]);
  }

  private async refreshSearchHistory(): Promise<void> {
    const history = await this.chatService.listSearchHistory();
    this.searchHistory.set(history);
  }

  private async refreshWebhooks(): Promise<void> {
    const webhooks = await this.chatService.listWebhooks();
    this.webhooks.set(webhooks);
  }

  private async loadRooms(): Promise<void> {
    const rooms = await this.chatService.listRooms();
    this.rooms.set(this.mergeRooms(rooms));

    if (rooms.length > 0) {
      await this.selectRoom(rooms[0].id);
    } else {
      this.messages.set([]);
      this.selectedRoomId.set(null);
      this.closeStream();
    }
  }

  private openStream(roomId: string): void {
    this.streamCleanup = this.chatService.openRoomStream(roomId, {
      onEvent: (event, payload) => {
        this.handleRealtimeEvent(event, payload);
      },
      onError: () => {
        this.chatError.set('Realtime поток потерян. Обновите страницу или выберите комнату снова.');
      }
    });
  }

  private closeStream(): void {
    if (this.streamCleanup) {
      this.streamCleanup();
      this.streamCleanup = null;
    }
  }

  private handleRealtimeEvent<T extends keyof RealtimeEventPayloadMap>(
    event: T,
    payload: RealtimeEventPayloadMap[T]
  ) {
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
      this.rooms.set(this.mergeRooms([room, ...this.rooms()]));
    }
  }

  private mergeRooms(rooms: Room[]): Room[] {
    const unique = new Map<string, Room>();
    for (const room of rooms) {
      unique.set(room.id, room);
    }

    return Array.from(unique.values());
  }

  private upsertMessage(message: Message): void {
    this.messages.update((current) => {
      const existingIndex = current.findIndex((item) => item.id === message.id);
      if (existingIndex >= 0) {
        const copy = [...current];
        copy[existingIndex] = { ...copy[existingIndex], ...message };
        return copy;
      }

      return [...current, message];
    });
  }

  private applyBoost(messageId: string, boost: Boost): void {
    this.messages.update((items) =>
      items.map((item) => {
        if (item.id !== messageId) {
          return item;
        }

        const boosts = item.boosts ?? [];
        const hasBoost = boosts.some((existingBoost) => existingBoost.id === boost.id);
        const nextBoosts = hasBoost ? boosts : [...boosts, boost];
        const summary = { ...(item.boostSummary ?? {}) };
        summary[boost.content] = (summary[boost.content] ?? 0) + (hasBoost ? 0 : 1);

        return {
          ...item,
          boosts: nextBoosts,
          boostSummary: summary
        };
      })
    );
  }
}
