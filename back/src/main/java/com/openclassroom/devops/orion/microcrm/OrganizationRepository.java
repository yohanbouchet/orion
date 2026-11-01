// Fichier  : OrganizationRepository.java
// Rôle     : accès aux organisations en base ; Spring Data REST en fait
//            l'API /organizations
// Utilisé par : Spring Data REST (API générée), tests du back
package com.openclassroom.devops.orion.microcrm;

import org.springframework.data.repository.PagingAndSortingRepository;
import org.springframework.data.repository.CrudRepository;
import org.springframework.data.rest.core.annotation.RepositoryRestResource;

// Pas de @CrossOrigin : il autorisait toutes les origines (ticket #65)
@RepositoryRestResource
public interface OrganizationRepository
        extends PagingAndSortingRepository<Organization, Long>, CrudRepository<Organization, Long> {
}
