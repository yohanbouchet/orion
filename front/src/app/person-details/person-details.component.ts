import { Component, OnInit, ChangeDetectionStrategy } from '@angular/core';
import { ActivatedRoute, Router, RouterLink } from '@angular/router';
import { FormsModule } from '@angular/forms';
import { Person, PersonService } from '../person.service';
import { Organization, OrganizationService } from '../organization.service';

@Component({
  selector: 'app-person-details',
  imports: [FormsModule, RouterLink],
  templateUrl: './person-details.component.html',
  changeDetection: ChangeDetectionStrategy.Eager,
  styleUrl: './person-details.component.css'
})
export class PersonDetailsComponent implements OnInit {
  person: Person = {
    id: undefined as (number | undefined),
    firstName: '',
    lastName: '',
    phone: '',
    email: '',
    bio: '',
    createdAt: new Date(),
    updatedAt: undefined as (Date | undefined),
    organizations: [] as (Organization[])
  };

  organizations: Organization[] = []
  selectedOrganization: Organization | null = null;
  isNew: boolean = false;

  constructor(
    private readonly route: ActivatedRoute,
    private readonly personService: PersonService,
    private readonly organizationService: OrganizationService,
    private readonly router: Router
  ) { }

  // Chargement au démarrage du composant, et non plus dans le constructeur
  // (SonarQube typescript:S7059) ; « void » : le résultat n'est pas attendu
  // ici, une erreur remonte au gestionnaire d'erreurs d'Angular
  ngOnInit(): void {
    void this.load()
  }

  private async load() {
    this.organizations = await this.organizationService.fetchAll()
    const personIdParam = this.route.snapshot.paramMap.get('personId')

    if (personIdParam === 'new') {
      this.isNew = true
    } else if (personIdParam !== null) {
      this.person = await this.personService.fetchById(
        Number.parseInt(personIdParam, 10))
      this.isNew = false
    }
  }

  // Chaque appel au back est attendu (await) avant l'étape suivante
  // (SonarQube typescript:S9383 : aucune promesse laissée sans suite)
  async savePerson() {
    const saved = await this.personService.save({ ...this.person })
    this.person = saved
    // Angular garde le même composant en changeant d'adresse : la fiche
    // n'est plus « nouvelle » une fois enregistrée
    if (this.isNew) {
      this.isNew = false
      await this.router.navigate(["persons", saved.id])
    }
  }

  async deletePerson() {
    if (this.person.id === undefined) return
    await this.personService.deleteById(this.person.id)
    await this.router.navigate([""])
  }

  // Attendre l'ajout ou le retrait AVANT de relire la personne : sans
  // cela, la liste pouvait être relue avant l'enregistrement
  async addSelectedOrganization() {
    if (this.selectedOrganization?.id === undefined
      || this.person.id === undefined) return
    await this.organizationService.addPerson(
      this.selectedOrganization.id, this.person.id)
    this.selectedOrganization = null
    await this.refresh()
  }

  async removeOrganization(org: Organization) {
    if (org?.id === undefined || this.person.id === undefined) return
    await this.organizationService.removePerson(org.id, this.person.id)
    await this.refresh()
  }

  async refresh() {
    if (this.person.id === undefined) return
    this.person = await this.personService.fetchById(this.person.id)
    this.isNew = false
  }
}
