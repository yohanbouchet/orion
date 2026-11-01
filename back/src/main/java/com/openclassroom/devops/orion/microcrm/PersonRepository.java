// Fichier  : PersonRepository.java
// Rôle     : accès aux personnes en base ; Spring Data REST en fait
//            l'API /persons
// Utilisé par : Spring Data REST (API générée), tests du back
package com.openclassroom.devops.orion.microcrm;

import org.springframework.data.repository.PagingAndSortingRepository;
import org.springframework.data.repository.query.Param;

import java.util.Optional;

import org.springframework.data.repository.CrudRepository;
import org.springframework.data.rest.core.annotation.RepositoryRestResource;

// Pas de @CrossOrigin : il autorisait toutes les origines (ticket #65)
@RepositoryRestResource
public interface PersonRepository extends PagingAndSortingRepository<Person, Long>, CrudRepository<Person, Long> {
    Optional<Person> findByEmail(@Param("email") String email);
}
