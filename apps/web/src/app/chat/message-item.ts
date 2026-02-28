import { DatePipe, KeyValuePipe } from '@angular/common';
import { Component, inject, input } from '@angular/core';
import { type Message } from '../core/api.types';
import { ChatStore } from '../core/chat.store';

@Component({
  selector: 'app-message-item',
  imports: [DatePipe, KeyValuePipe],
  template: `
    @let msg = message();

    <div class="head">
      <strong>{{ msg.creator?.name || msg.creatorId }}</strong>
      <time>{{ msg.createdAt | date: 'short' }}</time>
    </div>

    <p>{{ msg.body }}</p>

    @if (msg.boostSummary; as summary) {
      <div class="boosts">
        @for (pair of summary | keyvalue; track pair.key) {
          <span>{{ pair.key }} {{ pair.value }}</span>
        }
      </div>
    }

    <div class="actions">
      <button type="button" (click)="boost('👍')">👍</button>
      <button type="button" (click)="boost('🔥')">🔥</button>
      <button type="button" (click)="boost('🚀')">🚀</button>
    </div>
  `,
  styles: `
    :host {
      display: block;
      border: 1px solid var(--line);
      border-left: 4px solid var(--accent-2);
      border-radius: 12px;
      padding: 0.65rem 0.8rem;
      background: #fff;
    }

    .head {
      display: flex;
      align-items: baseline;
      gap: 0.45rem;
    }

    strong {
      font-family: 'IBM Plex Mono', monospace;
      font-size: 0.84rem;
    }

    time {
      color: var(--muted);
      font-size: 0.74rem;
    }

    p {
      margin: 0.4rem 0;
    }

    .boosts {
      display: flex;
      flex-wrap: wrap;
      gap: 0.35rem;
      margin-bottom: 0.4rem;
    }

    .boosts span {
      border: 1px solid var(--line);
      border-radius: 999px;
      padding: 0.12rem 0.38rem;
      font-size: 0.8rem;
    }

    .actions {
      display: flex;
      gap: 0.4rem;
    }
  `
})
export class MessageItemComponent {
  private readonly store = inject(ChatStore);

  readonly message = input.required<Message>();

  boost(content: string): void {
    void this.store.boostMessage(this.message().id, content);
  }
}
