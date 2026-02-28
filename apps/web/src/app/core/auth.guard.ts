import { inject } from '@angular/core';
import { type CanActivateFn, Router } from '@angular/router';
import { AuthService } from './auth.service';

export const authGuard: CanActivateFn = async () => {
  const auth = inject(AuthService);

  if (auth.user()) return true;

  const user = await auth.loadCurrentUser();
  if (user) return true;

  return inject(Router).createUrlTree(['/login']);
};

export const guestGuard: CanActivateFn = async () => {
  const auth = inject(AuthService);

  if (auth.user()) return inject(Router).createUrlTree(['/chat']);

  const user = await auth.loadCurrentUser();
  if (user) return inject(Router).createUrlTree(['/chat']);

  return true;
};
