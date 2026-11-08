import { AsyncPipe, DatePipe } from '@angular/common';
import { Component, OnInit, ChangeDetectionStrategy } from '@angular/core';
import { RouterLink } from '@angular/router';
import { Person, PersonService } from '../person.service';
import { Organization, OrganizationService } from '../organization.service';

@Component({
    selector: 'app-main-dashboard',
    imports: [RouterLink, AsyncPipe, DatePipe],
    templateUrl: './main-dashboard.component.html',
    changeDetection: ChangeDetectionStrategy.Eager,
    styleUrl: './main-dashboard.component.css'
})
export class MainDashboardComponent implements OnInit {
  organizations: Organization[] = [];
  persons: Person[] = [];

  constructor(private personService: PersonService, private organizationService: OrganizationService) { }


  ngOnInit(): void {
    this.personService.fetchAll().then(persons => this.persons = persons);
    this.organizationService.fetchAll().then(orgs => this.organizations = orgs);
  }
}

