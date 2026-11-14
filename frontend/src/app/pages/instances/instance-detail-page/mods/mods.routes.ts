import { Routes } from '@angular/router';

export const INSTANCE_MODS_ROUTES: Routes = [
  {
    path: '',
    loadComponent: () => import('./mods').then(m => m.InstanceModsPageComponent),
  },
  {
    path: 'add',
    loadComponent: () => import('../../../add-mods-page/add-mods-page.component').then(m => m.AddModsPageComponent),
  },
  {
    path: ':modId',
    loadComponent: () => import('./mod-detail-page/mod-detail-page.component').then(m => m.ModDetailPageComponent),
  },
];
