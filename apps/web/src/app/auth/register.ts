import { Component, inject, signal } from '@angular/core';
import { FormBuilder, ReactiveFormsModule, Validators } from '@angular/forms';
import { Router, RouterLink } from '@angular/router';
import { AuthService } from '../core/auth.service';
import { ChatStore } from '../core/chat.store';

@Component({
  selector: 'app-register',
  imports: [ReactiveFormsModule, RouterLink],
  template: `
    <section class="panel">
      <header>
        <h1>Campfire</h1>
        <p>Создайте аккаунт</p>
      </header>

      <form [formGroup]="form" (ngSubmit)="submit()">
        <label>
          Имя
          <input type="text" formControlName="name" placeholder="Ваше имя" />
        </label>

        <label>
          Email
          <input type="email" formControlName="emailAddress" placeholder="you@example.com" />
        </label>

        <label>
          Пароль
          <input type="password" formControlName="password" placeholder="Минимум 8 символов" />
        </label>

        <button class="primary" type="submit">Создать аккаунт</button>
      </form>

      @if (error()) {
        <p class="error-text">{{ error() }}</p>
      }

      <p class="switch">
        Уже есть аккаунт? <a routerLink="/login">Войти</a>
      </p>
    </section>
  `,
  styles: `
    :host {
      display: grid;
      place-items: center;
      min-height: 100dvh;
      padding: 1.25rem;
    }

    .panel {
      width: 100%;
      max-width: 420px;
      background: var(--surface);
      border: 1px solid var(--line);
      border-radius: 20px;
      padding: 2rem 1.5rem;
      box-shadow: 0 12px 30px rgba(23, 25, 24, 0.08);
    }

    header {
      margin-bottom: 1.5rem;
    }

    h1 {
      margin: 0;
      font-size: 2rem;
      letter-spacing: -0.03em;
    }

    header p {
      margin: 0.5rem 0 0;
      color: var(--muted);
    }

    form {
      display: grid;
      gap: 0.65rem;
    }

    label {
      display: grid;
      gap: 0.4rem;
      font-size: 0.9rem;
    }

    .switch {
      margin-top: 1rem;
      font-size: 0.88rem;
      color: var(--muted);
    }

    .switch a {
      color: var(--accent);
    }
  `
})
export default class RegisterComponent {
  private readonly auth = inject(AuthService);
  private readonly store = inject(ChatStore);
  private readonly router = inject(Router);
  private readonly fb = inject(FormBuilder);

  readonly error = signal('');

  readonly form = this.fb.nonNullable.group({
    name: ['', [Validators.required, Validators.minLength(2)]],
    emailAddress: ['', [Validators.required, Validators.email]],
    password: ['', [Validators.required, Validators.minLength(8)]]
  });

  async submit(): Promise<void> {
    this.error.set('');

    if (this.form.invalid) {
      this.error.set('Заполните форму корректно.');
      return;
    }

    const { name, emailAddress, password } = this.form.getRawValue();

    try {
      await this.auth.register(name, emailAddress, password);
      await this.store.init();
      await this.router.navigateByUrl('/chat');
    } catch {
      this.error.set('Ошибка регистрации. Проверьте данные и попробуйте снова.');
    }
  }
}
