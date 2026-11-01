// Fichier  : SpringDataRestCustomization.java
// Rôle     : réglages de l'API REST générée par Spring Data REST
// Utilisé par : Spring Boot (classe de configuration chargée au démarrage)
package com.openclassroom.devops.orion.microcrm;

import org.springframework.context.annotation.Configuration;
import org.springframework.data.rest.core.config.RepositoryRestConfiguration;
import org.springframework.data.rest.webmvc.config.RepositoryRestConfigurer;
import org.springframework.web.servlet.config.annotation.CorsRegistry;

@Configuration
public class SpringDataRestCustomization implements RepositoryRestConfigurer {

    @Override
    public void configureRepositoryRestConfiguration(RepositoryRestConfiguration config, CorsRegistry cors) {
        // Identifiants visibles dans les réponses JSON (utilisés par le front)
        config.exposeIdsFor(Person.class, Organization.class);
        // Aucune règle CORS : le front appelle l'API à sa propre adresse
        // (/api, relayée par nginx), les autres origines sont refusées par
        // le navigateur (ticket #65 ; ancien allowedOrigins("*"), OWASP A02)
        RepositoryRestConfigurer.super.configureRepositoryRestConfiguration(config, cors);
    }
}
