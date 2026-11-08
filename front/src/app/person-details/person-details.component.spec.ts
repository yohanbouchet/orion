// Fichier  : front/src/app/person-details/person-details.component.spec.ts
// Rôle     : tests de la fiche d'une personne, back simulé
//            (HttpTestingController) : chargement, création, suppression,
//            ajout et retrait d'une organisation
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

import { PersonDetailsComponent } from './person-details.component';

// Laisse passer les étapes asynchrones en attente (await) : le composant
// a alors envoyé sa requête suivante
const settle = () => new Promise<void>((resolve) => setTimeout(resolve));

const ORION = { id: 1, name: 'Orion' };
const ACME = { id: 2, name: 'Acme' };
const JOHN = {
  id: 7, firstName: 'John', lastName: 'Doe', email: 'jdoe@example.net',
  phone: '', bio: '',
};

describe('PersonDetailsComponent', () => {
  let fixture: ComponentFixture<PersonDetailsComponent>;
  let component: PersonDetailsComponent;
  let http: HttpTestingController;
  let router: Router;

  // Ouvre la fiche /persons/<personId> et sert la liste des organisations
  async function open(personId: string) {
    TestBed.configureTestingModule({
      imports: [PersonDetailsComponent],
      providers: [
        provideHttpClient(),
        provideHttpClientTesting(),
        provideRouter([]),
        {
          provide: ActivatedRoute,
          useValue: { snapshot: { paramMap: convertToParamMap({ personId }) } },
        },
      ],
    });
    http = TestBed.inject(HttpTestingController);
    router = TestBed.inject(Router);
    vi.spyOn(router, 'navigate').mockResolvedValue(true);
    fixture = TestBed.createComponent(PersonDetailsComponent);
    component = fixture.componentInstance;
    fixture.detectChanges();
    await settle();
    http.expectOne('/api/organizations')
      .flush({ _embedded: { organizations: [ORION, ACME] } });
    await settle();
  }

  // Sert une personne, puis la liste de ses organisations
  async function servePerson(organizations: object[]) {
    http.expectOne('/api/persons/7').flush(JOHN);
    await settle();
    http.expectOne('/api/persons/7/organizations')
      .flush({ _embedded: { organizations } });
    await settle();
  }

  // Aucune requête oubliée ni inattendue
  afterEach(() => http.verify());

  it("loads the person and lists only the person's organizations", async () => {
    await open('7');
    await servePerson([ORION]);
    fixture.detectChanges();

    expect(component.isNew).toBe(false);
    expect(component.person.firstName).toBe('John');
    const rows = fixture.nativeElement.querySelectorAll('tbody tr');
    expect(rows.length).toBe(1);
    expect(rows[0].textContent).toContain('Orion');
  });

  it('creates a new person, then leaves the "new" mode', async () => {
    await open('new');
    expect(component.isNew).toBe(true);
    component.person.firstName = 'Jane';
    component.person.lastName = 'Roe';

    const saving = component.savePerson();
    await settle();
    const post = http.expectOne('/api/persons');
    expect(post.request.method).toBe('POST');
    post.flush({ ...JOHN, id: 8, firstName: 'Jane', lastName: 'Roe' });
    await settle();
    http.expectOne('/api/persons/8/organizations')
      .flush({ _embedded: { organizations: [] } });
    await saving;

    expect(component.isNew).toBe(false);
    expect(router.navigate).toHaveBeenCalledWith(['persons', 8]);
  });

  it('adds the selected organization, then reloads the person', async () => {
    await open('7');
    await servePerson([]);
    component.selectedOrganization = {
      ...ACME, createdAt: new Date(), persons: [],
    };

    const adding = component.addSelectedOrganization();
    await settle();
    const put = http.expectOne('/api/organizations/2/persons');
    expect(put.request.method).toBe('PUT');
    expect(put.request.body).toBe('/api/persons/7');
    put.flush(null);
    await settle();
    await servePerson([ACME]);
    await adding;

    expect(component.selectedOrganization).toBeNull();
    expect(component.person.organizations).toEqual([ACME]);
  });

  it('removes an organization, then reloads the person', async () => {
    await open('7');
    await servePerson([ORION]);

    const removing = component.removeOrganization(
      component.person.organizations[0]);
    await settle();
    const del = http.expectOne('/api/persons/7/organizations/1');
    expect(del.request.method).toBe('DELETE');
    del.flush(null);
    await settle();
    await servePerson([]);
    await removing;

    expect(component.person.organizations).toEqual([]);
  });

  it('deletes the person, then goes back to the dashboard', async () => {
    await open('7');
    await servePerson([]);

    const deleting = component.deletePerson();
    await settle();
    const del = http.expectOne('/api/persons/7');
    expect(del.request.method).toBe('DELETE');
    del.flush(null);
    await deleting;

    expect(router.navigate).toHaveBeenCalledWith(['']);
  });
});
