import { Component, inject } from '@angular/core';
import { FormBuilder, ReactiveFormsModule, Validators } from '@angular/forms';
import { Router } from '@angular/router';
import { AuthService } from '../core/auth.service';
import { ChatStore } from '../core/chat.store';
import { RoomCreateComponent } from './room-create';
import { WebhookPanelComponent } from './webhook-panel';

@Component({
  selector: 'app-sidebar',
  imports: [ReactiveFormsModule, RoomCreateComponent, WebhookPanelComponent],
  template: `
    <div class="head">
      <div>
        <h2>{{ auth.user()?.name }}</h2>
        <small>{{ auth.user()?.emailAddress }}</small>
      </div>
      <button type="button" (click)="logout()">Выйти</button>
    </div>

    <app-room-create />

    <form class="direct-create" [formGroup]="directForm" (ngSubmit)="findDirect()">
      <input type="text" formControlName="query" placeholder="Direct: имя пользователя" />
      <button type="submit">Найти</button>
    </form>

    @if (store.directCandidates().length > 0) {
      <div class="user-list">
        @for (user of store.directCandidates(); track user.id) {
          <button type="button" (click)="startDirect(user.id)">
            <span>{{ user.name }}</span>
            <small>{{ user.emailAddress }}</small>
          </button>
        }
      </div>
    }

    <div class="rooms">
      @for (room of store.rooms(); track room.id) {
        <button
          type="button"
          [class.active]="room.id === store.selectedRoomId()"
          (click)="store.selectRoom(room.id)"
        >
          <span>{{ room.type === 'direct' ? 'DM' : '#' }} {{ room.name }}</span>
          <small>{{ room.type }}</small>
        </button>
      } @empty {
        <p class="empty-hint">Комнат пока нет</p>
      }
    </div>

    <app-webhook-panel />
  `,
  styles: `
    :host {
      background: var(--surface);
      border: 1px solid var(--line);
      border-radius: var(--radius-lg);
      padding: 0.85rem;
      box-shadow: 0 10px 25px rgba(23, 25, 24, 0.06);
      overflow: auto;
      display: grid;
      align-content: start;
      gap: 0.8rem;
    }

    .head {
      display: flex;
      justify-content: space-between;
      align-items: center;
      gap: 0.7rem;
    }

    .head h2 {
      margin: 0;
      font-size: 1.05rem;
    }

    .head small {
      color: var(--muted);
    }

    .direct-create {
      display: grid;
      grid-template-columns: 1fr auto;
      gap: 0.5rem;
      align-items: center;
    }

    .user-list,
    .rooms {
      display: grid;
      gap: 0.45rem;
    }

    .rooms button,
    .user-list button {
      text-align: left;
      display: flex;
      justify-content: space-between;
      align-items: center;
      gap: 0.35rem;
    }

    .user-list small,
    .rooms small {
      color: var(--muted);
    }

    .empty-hint {
      color: var(--muted);
      font-size: 0.85rem;
      margin: 0;
    }
  `
})
export class SidebarComponent {
  protected readonly auth = inject(AuthService);
  protected readonly store = inject(ChatStore);
  private readonly router = inject(Router);
  private readonly fb = inject(FormBuilder);

  readonly directForm = this.fb.nonNullable.group({
    query: ['', [Validators.required, Validators.minLength(2)]]
  });

  async findDirect(): Promise<void> {
    if (this.directForm.invalid) return;

    const query = this.directForm.controls.query.value.trim();
    if (query) {
      await this.store.findDirectCandidates(query);
    }
  }

  async startDirect(userId: string): Promise<void> {
    await this.store.createDirectRoom(userId);
    this.directForm.reset();
  }

  async logout(): Promise<void> {
    await this.auth.logout();
    this.store.reset();
    await this.router.navigateByUrl('/login');
  }
}
