import { Routes } from '@angular/router';
import { pendingChangesGuard } from './guards/pending-changes.guard';
import { authGuard } from './guards/auth.guard';

export const routes: Routes = [
  { path: 'login', loadComponent: () => import('./pages/auth/login-page').then(m => m.LoginPage) },
  { path: 'setup', loadComponent: () => import('./pages/auth/setup-page').then(m => m.SetupPage) },
  
  { path: '', redirectTo: 'home', pathMatch: 'full' },
  { 
    path: 'home', 
    loadComponent: () => import('./pages/main-page/main-page').then(m => m.MainPage),
    canActivate: [authGuard] 
  },
  {
    path: 'settings',
    loadComponent: () => import('./pages/settings/settings-page/settings-page').then(m => m.SettingsPage),
    canActivate: [authGuard],
    children: [
      { path: '', redirectTo: 'general', pathMatch: 'full' },
      {
        path: 'general',
        loadComponent: () => import('./pages/settings/general-settings/general-settings').then(m => m.GeneralSettingsComponent),
        canDeactivate: [pendingChangesGuard]
      },
      {
        path: 'themes',
        loadComponent: () => import('./pages/settings/theme-settings/theme-settings').then(m => m.ThemeSettingsComponent),
        canDeactivate: [pendingChangesGuard]
      },
    ]
  },
  {
    path: 'new-instance',
    loadComponent: () => import('./pages/instances/new-instance/new-instance').then(m => m.NewInstance),
    canActivate: [authGuard]
  },
  { path: 'instance/:id',
    loadComponent: () => import('./pages/instances/instance-detail-page/instance-detail-page').then(m => m.InstanceDetailPage),
    canActivate: [authGuard],
    children: [
      { path: '', redirectTo: 'console', pathMatch: 'full' },
      {
        path: 'console',
        loadComponent: () => import('./pages/instances/instance-detail-page/console/console.component').then(m => m.ConsoleComponent)
      },
      {
        path: 'files',
        loadComponent: () => import('./pages/instances/instance-detail-page/files/files.component').then(m => m.FilesComponent)
      },
      {
        path: 'backups',
        loadComponent: () => import('./pages/instances/instance-detail-page/backups/backups.component').then(m => m.BackupsComponent)
      },
      {
        path: 'mods',
        loadChildren: () => import('./pages/instances/instance-detail-page/mods/mods.routes').then(m => m.INSTANCE_MODS_ROUTES)
      },
      {
        path: 'instance-settings',
        loadComponent: () => import('./pages/instances/instance-detail-page/general/general').then(m => m.NewInstanceGeneralComponent)
      },
      {
        path: 'server-settings',
        loadComponent: () => import('./pages/instances/instance-detail-page/advanced/advanced').then(m => m.NewInstanceAdvancedComponent)
      },
    ]
   },
  { path: '**', loadComponent: () => import('./pages/error/error').then(m => m.default) }
];
