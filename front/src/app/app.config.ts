import { ApplicationConfig } from '@angular/core';
import { provideRouter } from '@angular/router';
import { provideHttpClient } from '@angular/common/http';

import { routes } from './app.routes';

export const appConfig: ApplicationConfig = {
  providers: [
    // Client HTTP ; depuis Angular 21, il utilise fetch par défaut
    // (withFetch, devenu inutile, est déprécié)
    provideHttpClient(),
    provideRouter(routes),
  ]
};
