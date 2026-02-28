import { DestroyRef, Injectable, inject } from '@angular/core';
import { environment } from '../../environments/environment';
import { type RealtimeEventPayloadMap } from './api.types';

type RealtimeEventName = keyof RealtimeEventPayloadMap;

@Injectable({ providedIn: 'root' })
export class RealtimeService {
  private source: EventSource | null = null;
  private readonly destroyRef = inject(DestroyRef);

  constructor() {
    this.destroyRef.onDestroy(() => this.disconnect());
  }

  connect(
    roomId: string,
    handlers: {
      onEvent: <T extends RealtimeEventName>(event: T, payload: RealtimeEventPayloadMap[T]) => void;
      onError?: () => void;
    }
  ): void {
    this.disconnect();

    const url = `${environment.apiBaseUrl}/realtime/stream?roomId=${encodeURIComponent(roomId)}`;
    this.source = new EventSource(url, { withCredentials: true });

    const listen = <T extends RealtimeEventName>(event: T) => {
      this.source!.addEventListener(event, (raw) => {
        const payload = JSON.parse((raw as MessageEvent<string>).data) as RealtimeEventPayloadMap[T];
        handlers.onEvent(event, payload);
      });
    };

    listen('connected');
    listen('heartbeat');
    listen('room.created');
    listen('message.created');
    listen('message.boosted');

    this.source.onerror = () => handlers.onError?.();
  }

  disconnect(): void {
    this.source?.close();
    this.source = null;
  }
}
