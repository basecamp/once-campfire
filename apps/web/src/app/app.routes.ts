import { type Routes } from '@angular/router';
import { authGuard, guestGuard } from './core/auth.guard';

export const routes: Routes = [
  { path: '', redirectTo: 'chat', pathMatch: 'full' },
  {
    path: 'login',
    loadComponent: () => import('./auth/login'),
    canActivate: [guestGuard]
  },
  {
    path: 'register',
    loadComponent: () => import('./auth/register'),
    canActivate: [guestGuard]
  },
  {
    path: 'chat',
    loadComponent: () => import('./chat/chat-layout'),
    canActivate: [authGuard]
  },
  { path: '**', redirectTo: 'chat' }
];
