import { Component, inject } from '@angular/core';
import { FormBuilder, ReactiveFormsModule, Validators } from '@angular/forms';
import { ChatStore } from '../core/chat.store';

@Component({
  selector: 'app-webhook-panel',
  imports: [ReactiveFormsModule],
  template: `
    <h4>Webhooks</h4>

    <form [formGroup]="form" (ngSubmit)="create()">
      <input type="text" formControlName="url" placeholder="https://example.com/hook" />
      <button type="submit">Добавить</button>
    </form>

    @if (store.webhooks().length > 0) {
      <div class="list">
        @for (webhook of store.webhooks(); track webhook.id) {
          <article>
            <p>{{ webhook.url }}</p>
            <div class="actions">
              <button type="button" (click)="store.testWebhook(webhook.id)">Test</button>
              <button type="button" (click)="store.deleteWebhook(webhook.id)">Delete</button>
            </div>
          </article>
        }
      </div>
    }
  `,
  styles: `
    :host {
      display: grid;
      gap: 0.5rem;
    }

    h4 {
      margin: 0;
    }

    form {
      display: grid;
      grid-template-columns: 1fr auto;
      gap: 0.5rem;
      align-items: center;
    }

    .list {
      display: grid;
      gap: 0.45rem;
    }

    .list article {
      border: 1px solid var(--line);
      border-radius: var(--radius);
      padding: 0.5rem;
    }

    .list p {
      margin: 0 0 0.35rem;
      word-break: break-all;
      font-size: 0.82rem;
    }

    .actions {
      display: flex;
      gap: 0.45rem;
    }
  `
})
export class WebhookPanelComponent {
  protected readonly store = inject(ChatStore);
  private readonly fb = inject(FormBuilder);

  readonly form = this.fb.nonNullable.group({
    url: ['', [Validators.required]]
  });

  async create(): Promise<void> {
    const url = this.form.controls.url.value.trim();
    if (!url) return;

    await this.store.createWebhook(url);
    this.form.controls.url.reset();
  }
}
