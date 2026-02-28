import { Component, inject } from '@angular/core';
import { ChatStore } from '../core/chat.store';
import { MessageItemComponent } from './message-item';
import { MessageComposerComponent } from './message-composer';
import { SearchPanelComponent } from './search-panel';

@Component({
  selector: 'app-room-view',
  imports: [MessageItemComponent, MessageComposerComponent, SearchPanelComponent],
  template: `
    @let room = store.selectedRoom();

    <header>
      @if (room) {
        <h3>{{ room.type === 'direct' ? 'DM' : '#' }} {{ room.name }}</h3>
      } @else {
        <h3>Выберите комнату</h3>
      }
    </header>

    <app-search-panel />

    @if (room) {
      <div class="messages">
        @for (message of store.messages(); track message.id) {
          <app-message-item [message]="message" />
        } @empty {
          <p class="empty">Сообщений пока нет. Напишите первое!</p>
        }
      </div>

      <app-message-composer />
    } @else {
      <div class="empty">Комнат пока нет. Создайте первую слева.</div>
    }

    @if (store.error()) {
      <p class="error-text">{{ store.error() }}</p>
    }
  `,
  styles: `
    :host {
      background: var(--surface);
      border: 1px solid var(--line);
      border-radius: var(--radius-lg);
      padding: 0.85rem;
      box-shadow: 0 10px 25px rgba(23, 25, 24, 0.06);
      display: grid;
      grid-template-rows: auto auto 1fr auto auto;
      gap: 0.65rem;
    }

    h3 {
      margin: 0;
      font-size: 1.2rem;
    }

    .messages {
      overflow: auto;
      padding-right: 0.45rem;
      display: grid;
      gap: 0.75rem;
      align-content: start;
    }

    .empty {
      color: var(--muted);
      border: 1px dashed var(--line);
      border-radius: 12px;
      padding: 1rem;
    }
  `
})
export class RoomViewComponent {
  protected readonly store = inject(ChatStore);
}
