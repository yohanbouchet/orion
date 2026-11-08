import { DatePipe } from '@angular/common';
import { Component, OnInit, ChangeDetectionStrategy } from '@angular/core';
import { ActivatedRoute, Router, RouterLink } from '@angular/router';
import { FormsModule } from '@angular/forms';
import { Person } from '../person.service';
import { Organization, OrganizationService } from '../organization.service';

@Component({
  selector: 'app-organization-details',
  imports: [FormsModule, RouterLink, DatePipe],
  templateUrl: './organization-details.component.html',
  changeDetection: ChangeDetectionStrategy.Eager,
  styleUrl: './organization-details.component.css'
})
export class OrganizationDetailsComponent implements OnInit {
  org: Organization = {
    id: undefined as (number | undefined),
    name: '',
    createdAt: new Date(),
    updatedAt: undefined as (Date | undefined),
    persons: [] as Person[]
  };

  isNew: boolean = false;

  constructor(
    private readonly route: ActivatedRoute,
    private readonly organizationService: OrganizationService,
    private readonly router: Router
  ) { }

  // « void » : le résultat n'est pas attendu ici, une erreur remonte au
  // gestionnaire d'erreurs d'Angular (SonarQube typescript:S9383)
  ngOnInit(): void {
    void this.load()
  }

  private async load() {
    const orgIdParam = this.route.snapshot.paramMap.get('orgId')

    if (orgIdParam === 'new') {
      this.isNew = true
    } else if (orgIdParam !== null) {
      this.org = await this.organizationService.fetchById(
        Number.parseInt(orgIdParam, 10))
      this.isNew = false
    }
  }

  // Chaque appel au back est attendu (await) avant l'étape suivante
  async saveOrg() {
    const saved = await this.organizationService.save({ ...this.org })
    this.org = saved
    // Angular garde le même composant en changeant d'adresse : la fiche
    // n'est plus « nouvelle » une fois enregistrée
    if (this.isNew) {
      this.isNew = false
      await this.router.navigate(["organizations", saved.id])
    }
  }

  async deleteOrg() {
    if (this.org.id === undefined) return
    await this.organizationService.deleteById(this.org.id)
    await this.router.navigate([""])
  }
}
