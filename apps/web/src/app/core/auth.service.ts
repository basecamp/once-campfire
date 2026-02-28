import { HttpClient } from '@angular/common/http';
import { Injectable, computed, inject, signal } from '@angular/core';
import { firstValueFrom } from 'rxjs';
import { environment } from '../../environments/environment';
import { type User } from './api.types';

interface AuthResponse {
  user: User;
}

@Injectable({ providedIn: 'root' })
export class AuthService {
  private readonly http = inject(HttpClient);

  readonly user = signal<User | null>(null);
  readonly isAuthenticated = computed(() => this.user() !== null);
  readonly isAdmin = computed(() => this.user()?.role === 'admin');

  async loadCurrentUser(): Promise<User | null> {
    try {
      const { user } = await firstValueFrom(
        this.http.get<AuthResponse>(`${environment.apiBaseUrl}/auth/me`)
      );
      this.user.set(user);
      return user;
    } catch {
      this.user.set(null);
      return null;
    }
  }

  async login(emailAddress: string, password: string): Promise<User> {
    const { user } = await firstValueFrom(
      this.http.post<AuthResponse>(`${environment.apiBaseUrl}/auth/login`, {
        emailAddress,
        password
      })
    );
    this.user.set(user);
    return user;
  }

  async register(name: string, emailAddress: string, password: string): Promise<User> {
    const { user } = await firstValueFrom(
      this.http.post<AuthResponse>(`${environment.apiBaseUrl}/auth/register`, {
        name,
        emailAddress,
        password
      })
    );
    this.user.set(user);
    return user;
  }

  async logout(): Promise<void> {
    await firstValueFrom(
      this.http.post(`${environment.apiBaseUrl}/auth/logout`, {})
    );
    this.user.set(null);
  }
}
