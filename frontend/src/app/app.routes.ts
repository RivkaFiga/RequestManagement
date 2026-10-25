import { Routes } from '@angular/router';

export const routes: Routes = [
  {
    path: '',
    title: 'Requests',
    loadComponent: () => import('./requests/requests-list.page').then((m) => m.RequestsListPage),
  },
];
