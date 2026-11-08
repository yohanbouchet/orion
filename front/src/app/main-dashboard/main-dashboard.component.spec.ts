// Fichier  : front/src/app/main-dashboard/main-dashboard.component.spec.ts
// Rôle     : tests du tableau de bord, back simulé (HttpTestingController) :
//            les deux listes, et les liens « Create one » quand elles sont
//            vides
// Utilise  : Vitest (describe, it, expect), TestBed d'Angular
// Utilisé par : ng test (scripts/run-tests.sh front, job test-front)
import { ComponentFixture, TestBed } from '@angular/core/testing';
import { provideHttpClient } from '@angular/common/http';
import {
  HttpTestingController,
  provideHttpClientTesting,
} from '@angular/common/http/testing';
import { provideRouter } from '@angular/router';

import { MainDashboardComponent } from './main-dashboard.component';

// Laisse passer les étapes asynchrones en attente (await)
const settle = () => new Promise<void>((resolve) => setTimeout(resolve));

const JOHN = {
  id: 7, firstName: 'John', lastName: 'Doe', email: 'jdoe@example.net',
};

describe('MainDashboardComponent', () => {
  let fixture: ComponentFixture<MainDashboardComponent>;
  let http: HttpTestingController;

  beforeEach(async () => {
    TestBed.configureTestingModule({
      imports: [MainDashboardComponent],
      providers: [
        provideHttpClient(),
        provideHttpClientTesting(),
        provideRouter([]),
      ],
    });
    http = TestBed.inject(HttpTestingController);
    fixture = TestBed.createComponent(MainDashboardComponent);
    fixture.detectChanges();
    await settle();
  });

  // Aucune requête oubliée ni inattendue
  afterEach(() => http.verify());

  // Sert les deux listes, demandées en même temps
  async function serve(persons: object[], organizations: object[]) {
    http.expectOne('/api/persons').flush({ _embedded: { persons } });
    http.expectOne('/api/organizations')
      .flush({ _embedded: { organizations } });
    await settle();
    fixture.detectChanges();
  }

  it('lists the persons and the organizations', async () => {
    await serve([JOHN], [{ id: 3, name: 'Orion' }]);

    const text = fixture.nativeElement.textContent;
    expect(text).toContain('John Doe');
    expect(text).toContain('Orion');
  });

  it('links both empty lists to their creation page', async () => {
    await serve([], []);

    const links: HTMLAnchorElement[] = Array.from(
      fixture.nativeElement.querySelectorAll('td a'));
    expect(links.map((link) => link.getAttribute('href')))
      .toEqual(['/persons/new', '/organizations/new']);
  });
});
