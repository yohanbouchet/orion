// Fichier  : front/src/app/app.config.spec.ts
// Rôle     : vérifie que la configuration de l'application fournit le
//            client HTTP et les routes
// Utilise  : Vitest (describe, it, expect), TestBed d'Angular
// Utilisé par : ng test (scripts/run-tests.sh front, job test-front)
import { TestBed } from '@angular/core/testing';
import { HttpClient } from '@angular/common/http';
import { Router } from '@angular/router';

import { appConfig } from './app.config';
import { routes } from './app.routes';

describe('appConfig', () => {
  it('provides the HTTP client and the application routes', () => {
    TestBed.configureTestingModule({ providers: appConfig.providers });

    expect(TestBed.inject(HttpClient)).toBeTruthy();
    expect(TestBed.inject(Router).config).toEqual(routes);
  });
});
