# Fichier  : back/Dockerfile
# Rôle     : image de l'API MicroCRM (Spring Boot) : compilée dans une
#            première étape avec le JDK, exécutée avec le seul JRE, sans
#            root. trivy : 0 faille haute ou critique le 31/10/2026.
# Utilise  : le dossier back/ (code, Gradle Wrapper, gradle.lockfile) ;
#            images officielles eclipse-temurin 17 sur Alpine 3.24
# Utilisé par : .github/workflows/ci.yml (jobs images et publish) ; chart
#               infra/helm/microcrm (image publiée sur GHCR)

# --- Étape 1 : compilation (image jetée à la fin) ---
# JDK 17 (outils de compilation), version et empreinte figées
FROM eclipse-temurin:17.0.20.1_1-jdk-alpine-3.24@sha256:5a7fe9fcd65085bbf218a4060f08f1346b8bfd13d9f9942e2db6719cc8a11e22 AS build
WORKDIR /src
# Fichiers de Gradle d'abord : tant qu'ils ne changent pas, Docker réutilise
# la couche des dépendances déjà téléchargées (construction plus rapide)
COPY gradlew settings.gradle build.gradle gradle.lockfile ./
COPY gradle ./gradle
RUN ./gradlew dependencies --no-daemon --quiet > /dev/null
# Puis le code ; les tests ont déjà tourné dans le job test-back
COPY src ./src
RUN ./gradlew bootJar --no-daemon \
    && cp build/libs/microcrm-*.jar /src/app.jar

# --- Étape 2 : exécution (l'image livrée) ---
# JRE 17 seul : aucun outil de compilation dans l'image livrée
FROM eclipse-temurin:17.0.20.1_1-jre-alpine-3.24@sha256:c4a33e6ddb738fe4be0a28a613ea0940cec42d25d7263c3e2238c43354cb19b0
# Correctifs Alpine publiés depuis la sortie de l'image (ex. brotli-libs,
# faille critique corrigée, le 31/10/2026)
RUN apk upgrade --no-cache
WORKDIR /app
# Seul le jar vient de l'étape 1 ; il appartient à root : non modifiable
COPY --from=build /src/app.jar /app/app.jar
# Compte sans droits (numéro 1001) : l'application ne tourne jamais en root
USER 1001:1001
# 8080 : API ; 8081 : port de gestion (santé, métriques), jamais publié
EXPOSE 8080 8081
# Sonde de santé hors Kubernetes (docker run, Compose) : Actuator répond-il ?
# Dans Kubernetes, ce sont les sondes du chart qui comptent
HEALTHCHECK --interval=30s --timeout=3s --start-period=60s --retries=3 \
    CMD ["wget", "-q", "-O", "/dev/null", "http://127.0.0.1:8081/actuator/health/liveness"]
ENTRYPOINT ["java", "-jar", "/app/app.jar"]
