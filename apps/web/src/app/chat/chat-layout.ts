import { Component, inject } from '@angular/core';
import { ChatStore } from '../core/chat.store';
import { SidebarComponent } from './sidebar';
import { RoomViewComponent } from './room-view';

@Component({
  selector: 'app-chat-layout',
  imports: [SidebarComponent, RoomViewComponent],
  template: `
    <section class="layout">
      <app-sidebar />
      <app-room-view />
    </section>
  `,
  styles: `
    :host {
      display: block;
      padding: 1.25rem;
    }

    .layout {
      display: grid;
      grid-template-columns: 320px 1fr;
      gap: 0.85rem;
      min-height: calc(100dvh - 2.5rem);
    }

    @media (max-width: 1080px) {
      .layout {
        grid-template-columns: 1fr;
        min-height: auto;
      }
    }
  `
})
export default class ChatLayoutComponent {
  private readonly store = inject(ChatStore);

  constructor() {
    void this.store.init();
  }
}
