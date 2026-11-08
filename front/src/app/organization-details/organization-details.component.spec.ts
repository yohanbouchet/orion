// Fichier  : front/src/app/organization-details/
//            organization-details.component.spec.ts
// Rôle     : tests de la fiche d'une organisation, back simulé
//            (HttpTestingController) : chargement, création, suppression
// Utilise  : Vitest (describe, it, expect, vi), TestBed d'Angular
// Utilisé par : ng test (scripts/run-tests.sh front, job test-front)
import { ComponentFixture, TestBed } from '@angular/core/testing';
import { provideHttpClient } from '@angular/common/http';
import {
  HttpTestingController,
  provideHttpClientTesting,
} from '@angular/common/http/testing';
import {
  ActivatedRoute,
  Router,
  convertToParamMap,
  provideRouter,
} from '@angular/router';

import { OrganizationDetailsComponent } from './organization-details.component';

// Laisse passer les étapes asynchrones en attente (await)
const settle = () => new Promise<void>((resolve) => setTimeout(resolve));

const ORION = { id: 3, name: 'Orion' };
const JOHN = {
  id: 7, firstName: 'John', lastName: 'Doe', email: 'jdoe@example.net',
};

describe('OrganizationDetailsComponent', () => {
  let fixture: ComponentFixture<OrganizationDetailsComponent>;
  let component: OrganizationDetailsComponent;
  let http: HttpTestingController;
  let router: Router;

  // Ouvre la fiche /organizations/<orgId>
  async function open(orgId: string) {
    TestBed.configureTestingModule({
      imports: [OrganizationDetailsComponent],
      providers: [
        provideHttpClient(),
        provideHttpClientTesting(),
        provideRouter([]),
        {
          provide: ActivatedRoute,
          useValue: { snapshot: { paramMap: convertToParamMap({ orgId }) } },
        },
      ],
    });
    http = TestBed.inject(HttpTestingController);
    router = TestBed.inject(Router);
    vi.spyOn(router, 'navigate').mockResolvedValue(true);
    fixture = TestBed.createComponent(OrganizationDetailsComponent);
    component = fixture.componentInstance;
    fixture.detectChanges();
    await settle();
  }

  // Sert l'organisation 3, puis la liste de ses membres
  async function serveOrganization() {
    http.expectOne('/api/organizations/3').flush(ORION);
    await settle();
    http.expectOne('/api/organizations/3/persons')
      .flush({ _embedded: { persons: [JOHN] } });
    await settle();
  }

  // Aucune requête oubliée ni inattendue
  afterEach(() => http.verify());

  it('loads the organization and lists its persons', async () => {
    await open('3');
    await serveOrganization();
    fixture.detectChanges();

    expect(component.isNew).toBe(false);
    expect(component.org.name).toBe('Orion');
    const rows = fixture.nativeElement.querySelectorAll('tbody tr');
    expect(rows.length).toBe(1);
    expect(rows[0].textContent).toContain('John Doe');
  });

  it('creates a new organization, then leaves the "new" mode', async () => {
    await open('new');
    expect(component.isNew).toBe(true);
    component.org.name = 'Acme';

    const saving = component.saveOrg();
    await settle();
    const post = http.expectOne('/api/organizations');
    expect(post.request.method).toBe('POST');
    post.flush({ id: 9, name: 'Acme' });
    await settle();
    http.expectOne('/api/organizations/9/persons')
      .flush({ _embedded: { persons: [] } });
    await saving;

    expect(component.isNew).toBe(false);
    expect(router.navigate).toHaveBeenCalledWith(['organizations', 9]);
  });

  it('deletes the organization, then goes back to the dashboard', async () => {
    await open('3');
    await serveOrganization();

    const deleting = component.deleteOrg();
    await settle();
    const del = http.expectOne('/api/organizations/3');
    expect(del.request.method).toBe('DELETE');
    del.flush(null);
    await deleting;

    expect(router.navigate).toHaveBeenCalledWith(['']);
  });
});
