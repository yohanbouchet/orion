import { DatePipe } from '@angular/common';
import { Component, OnInit, ChangeDetectionStrategy } from '@angular/core';
import { RouterLink } from '@angular/router';
import { Person, PersonService } from '../person.service';
import { Organization, OrganizationService } from '../organization.service';

@Component({
  selector: 'app-main-dashboard',
  imports: [RouterLink, DatePipe],
  templateUrl: './main-dashboard.component.html',
  changeDetection: ChangeDetectionStrategy.Eager,
  styleUrl: './main-dashboard.component.css'
})
export class MainDashboardComponent implements OnInit {
  organizations: Organization[] = [];
  persons: Person[] = [];

  constructor(
    private readonly personService: PersonService,
    private readonly organizationService: OrganizationService
  ) { }

  // « void » : le résultat n'est pas attendu ici, une erreur remonte au
  // gestionnaire d'erreurs d'Angular (SonarQube typescript:S9383)
  ngOnInit(): void {
    void this.load()
  }

  // Les deux listes sont demandées en même temps au back
  private async load() {
    [this.persons, this.organizations] = await Promise.all([
      this.personService.fetchAll(),
      this.organizationService.fetchAll(),
    ])
  }
}
