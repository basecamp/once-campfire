import { Component, inject } from '@angular/core';
import { FormBuilder, ReactiveFormsModule, Validators } from '@angular/forms';
import { ChatStore } from '../core/chat.store';

@Component({
  selector: 'app-room-create',
  imports: [ReactiveFormsModule],
  template: `
    <form [formGroup]="form" (ngSubmit)="create()">
      <input type="text" formControlName="name" placeholder="Новая комната" />
      <select formControlName="type">
        <option value="open">Открытая</option>
        <option value="closed">Закрытая</option>
      </select>
      <button class="primary" type="submit">Создать</button>
    </form>
  `,
  styles: `
    form {
      display: grid;
      grid-template-columns: 1fr auto auto;
      gap: 0.5rem;
      align-items: center;
    }
  `
})
export class RoomCreateComponent {
  private readonly store = inject(ChatStore);
  private readonly fb = inject(FormBuilder);

  readonly form = this.fb.nonNullable.group({
    name: ['', [Validators.required, Validators.minLength(2), Validators.maxLength(80)]],
    type: ['open' as 'open' | 'closed']
  });

  async create(): Promise<void> {
    if (this.form.invalid) return;

    const { name, type } = this.form.getRawValue();
    await this.store.createRoom(name, type);
    this.form.controls.name.reset();
  }
}
