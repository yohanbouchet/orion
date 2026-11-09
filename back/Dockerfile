# Fichier  : back/Dockerfile
# Rôle     : image de l'API MicroCRM (Spring Boot) : emballe le jar déjà
#            compilé et testé, exécuté avec le seul JRE, sans root.
#            trivy : 0 faille haute ou critique le 31/10/2026.
# Utilise  : le jar build/libs/microcrm-*.jar, produit par
#            `./gradlew bootJar` (job test-back de la CI, ou le poste) ;
#            image officielle eclipse-temurin 17 (JRE) sur Alpine 3.24
# Utilisé par : .github/workflows/ci.yml (jobs images et publish) ; chart
#               infra/helm/microcrm (image publiée sur GHCR)
#
# Pourquoi aucune compilation ici : le jar livré est celui que les tests
# ont validé (construit une seule fois), et la construction de l'image ne
# télécharge ni Gradle ni bibliothèque (pannes de services.gradle.org des
# 08 et 09/11/2026). Sur le poste : `./gradlew bootJar` puis docker build.

# JRE 17 seul : aucun outil de compilation dans l'image livrée
FROM eclipse-temurin:17-jre-alpine-3.24@sha256:e2ba4e947bd5e236a9866fbdda03e4936036cb9e9d16ea0d84d103d6634a5c21
# Correctifs Alpine publiés depuis la sortie de l'image (ex. brotli-libs,
# faille critique corrigée, le 31/10/2026)
RUN apk upgrade --no-cache
WORKDIR /app
# Le jar de Spring Boot (un seul fichier attendu) ; il appartient à root
# et n'est qu'en lecture (444) : l'application ne peut pas le modifier
COPY --chmod=444 build/libs/microcrm-*.jar /app/app.jar
# Compte sans droits (numéro 1001) : l'application ne tourne jamais en root
USER 1001:1001
# 8080 : API ; 8081 : port de gestion (santé, métriques), jamais publié
EXPOSE 8080 8081
# Sonde de santé hors Kubernetes (docker run, Compose) : Actuator répond-il ?
# Dans Kubernetes, ce sont les sondes du chart qui comptent
HEALTHCHECK --interval=30s --timeout=3s --start-period=60s --retries=3 \
    CMD ["wget", "-q", "-O", "/dev/null", "http://127.0.0.1:8081/actuator/health/liveness"]
ENTRYPOINT ["java", "-jar", "/app/app.jar"]
