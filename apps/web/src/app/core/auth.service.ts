import { Injectable, signal } from '@angular/core';
import { HttpClient } from '@angular/common/http';
import { firstValueFrom } from 'rxjs';
import { environment } from '../../environments/environment';
import { type User } from './api.types';

interface AuthResponse {
  user: User;
}

@Injectable({ providedIn: 'root' })
export class AuthService {
  readonly user = signal<User | null>(null);

  constructor(private readonly http: HttpClient) {}

  async loadCurrentUser(): Promise<User | null> {
    try {
      const response = await firstValueFrom(
        this.http.get<AuthResponse>(`${environment.apiBaseUrl}/auth/me`, {
          withCredentials: true
        })
      );
      this.user.set(response.user);
      return response.user;
    } catch {
      this.user.set(null);
      return null;
    }
  }

  async login(emailAddress: string, password: string): Promise<User> {
    const response = await firstValueFrom(
      this.http.post<AuthResponse>(
        `${environment.apiBaseUrl}/auth/login`,
        {
          emailAddress,
          password
        },
        {
          withCredentials: true
        }
      )
    );

    this.user.set(response.user);
    return response.user;
  }

  async register(name: string, emailAddress: string, password: string): Promise<User> {
    const response = await firstValueFrom(
      this.http.post<AuthResponse>(
        `${environment.apiBaseUrl}/auth/register`,
        {
          name,
          emailAddress,
          password
        },
        {
          withCredentials: true
        }
      )
    );

    this.user.set(response.user);
    return response.user;
  }

  async logout(): Promise<void> {
    await firstValueFrom(
      this.http.post(`${environment.apiBaseUrl}/auth/logout`, {}, { withCredentials: true })
    );
    this.user.set(null);
  }
}
