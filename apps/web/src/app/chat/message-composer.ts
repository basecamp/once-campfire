import { Component, inject } from '@angular/core';
import { FormBuilder, ReactiveFormsModule, Validators } from '@angular/forms';
import { ChatStore } from '../core/chat.store';

@Component({
  selector: 'app-message-composer',
  imports: [ReactiveFormsModule],
  template: `
    <form [formGroup]="form" (ngSubmit)="send()">
      <input
        type="text"
        formControlName="body"
        placeholder="Напишите сообщение"
        (keydown.meta.Enter)="send()"
        (keydown.control.Enter)="send()"
      />
      <button class="primary" type="submit">Отправить</button>
    </form>
  `,
  styles: `
    form {
      display: grid;
      grid-template-columns: 1fr auto;
      gap: 0.55rem;
    }

    @media (max-width: 1080px) {
      form {
        grid-template-columns: 1fr;
      }
    }
  `
})
export class MessageComposerComponent {
  private readonly store = inject(ChatStore);
  private readonly fb = inject(FormBuilder);

  readonly form = this.fb.nonNullable.group({
    body: ['', [Validators.required, Validators.maxLength(4000)]]
  });

  async send(): Promise<void> {
    if (this.form.invalid) return;

    const body = this.form.controls.body.value.trim();
    if (!body) return;

    await this.store.sendMessage(body);
    this.form.controls.body.reset();
  }
}
