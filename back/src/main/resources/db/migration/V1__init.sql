-- Fichier  : back/src/main/resources/db/migration/V1__init.sql
-- Rôle     : première version du schéma (personnes, organisations et leur
--            lien) ; Flyway l'applique une seule fois au démarrage et la
--            note dans sa table flyway_schema_history
-- Utilise  : PostgreSQL 18 (Kubernetes) ou HSQLDB (tests, poste de dev)
-- Utilisé par : Flyway (spring-boot-starter-flyway) ; ticket #66
-- Règle    : un script appliqué ne se modifie JAMAIS ; tout changement passe
--            par un nouveau script V2__…, V3__…
-- Origine  : schéma généré par Hibernate depuis Person et Organization, sur
--            PostgreSQL 18 ; noms des contraintes rendus lisibles

-- Compteurs des identifiants : Hibernate réserve les numéros par blocs de 50
create sequence organization_seq start with 1 increment by 50;
create sequence person_seq start with 1 increment by 50;

create table organization (
    created_at timestamp(6) with time zone not null,
    id bigint not null,
    updated_at timestamp(6) with time zone not null,
    name varchar(255),
    primary key (id)
);

create table person (
    created_at timestamp(6) with time zone not null,
    id bigint not null,
    updated_at timestamp(6) with time zone not null,
    bio varchar(255),
    email varchar(255),
    first_name varchar(255),
    last_name varchar(255),
    phone varchar(255),
    primary key (id)
);

-- Lien « plusieurs à plusieurs » : une personne dans plusieurs organisations
create table organization_persons (
    organizations_id bigint not null,
    persons_id bigint not null
);

alter table organization_persons
    add constraint fk_organization_persons_person
    foreign key (persons_id) references person (id);

alter table organization_persons
    add constraint fk_organization_persons_organization
    foreign key (organizations_id) references organization (id);
