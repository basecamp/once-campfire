import { DatePipe } from '@angular/common';
import { Component, inject } from '@angular/core';
import { FormBuilder, ReactiveFormsModule, Validators } from '@angular/forms';
import { ChatStore } from '../core/chat.store';

@Component({
  selector: 'app-search-panel',
  imports: [ReactiveFormsModule, DatePipe],
  template: `
    <form class="search-form" [formGroup]="form" (ngSubmit)="search()">
      <input type="text" formControlName="query" placeholder="Поиск по сообщениям" />
      <select formControlName="scope">
        <option value="current">Текущая комната</option>
        <option value="all">Все комнаты</option>
      </select>
      <button type="submit">Найти</button>
      @if (store.searchHistory().length > 0) {
        <button type="button" (click)="store.clearSearchHistory()">Очистить историю</button>
      }
    </form>

    @if (store.searchResults().length > 0) {
      <div class="results">
        @for (result of store.searchResults(); track result.id) {
          <article>
            <strong>{{ result.creatorName }}</strong>
            <time>{{ result.createdAt | date: 'short' }}</time>
            <p>{{ result.body }}</p>
          </article>
        }
      </div>
    }

    @if (store.searchHistory().length > 0) {
      <div class="history">
        <small>История поиска:</small>
        @for (item of store.searchHistory(); track item.id) {
          <span>{{ item.query }}</span>
        }
      </div>
    }
  `,
  styles: `
    :host {
      display: grid;
      gap: 0.5rem;
    }

    .search-form {
      display: grid;
      grid-template-columns: minmax(0, 1fr) 170px auto auto;
      gap: 0.5rem;
      align-items: center;
    }

    .results {
      max-height: 170px;
      overflow: auto;
      border: 1px solid var(--line);
      border-radius: 12px;
      padding: 0.6rem;
      display: grid;
      gap: 0.6rem;
    }

    .results article {
      border-left: 3px solid var(--accent);
      padding-left: 0.55rem;
    }

    .results p {
      margin: 0.3rem 0 0;
    }

    .history {
      display: flex;
      gap: 0.4rem;
      flex-wrap: wrap;
      align-items: center;
    }

    .history span {
      font-size: 0.78rem;
      border: 1px solid var(--line);
      border-radius: 999px;
      padding: 0.2rem 0.45rem;
    }

    @media (max-width: 1080px) {
      .search-form {
        grid-template-columns: 1fr;
      }
    }
  `
})
export class SearchPanelComponent {
  protected readonly store = inject(ChatStore);
  private readonly fb = inject(FormBuilder);

  readonly form = this.fb.nonNullable.group({
    query: ['', [Validators.required, Validators.minLength(2)]],
    scope: ['current' as 'current' | 'all']
  });

  async search(): Promise<void> {
    if (this.form.invalid) return;

    const { query, scope } = this.form.getRawValue();
    const trimmed = query.trim();
    if (!trimmed) return;

    await this.store.runSearch(trimmed, scope);
  }
}
