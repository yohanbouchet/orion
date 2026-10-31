# Fichier  : back/Dockerfile
# Rôle     : image de l'API MicroCRM (Spring Boot) : compilée dans une
#            première étape avec le JDK, exécutée avec le seul JRE, sans
#            root. trivy : 0 faille haute ou critique le 31/10/2026.
# Utilise  : le dossier back/ (code, Gradle Wrapper, gradle.lockfile) ;
#            images officielles eclipse-temurin 17 sur Alpine 3.24
# Utilisé par : .github/workflows/ci.yml (job des images) ; plus tard le
#               chart Helm (phase 5)

# --- Étape 1 : compilation (image jetée à la fin) ---
# JDK 17 (outils de compilation), version et empreinte figées
FROM eclipse-temurin:24-jdk-alpine-3.22@sha256:8fdbcb6bc6b846640cea7058e6eeb56c311fae4efaa506a213789134065c6b90 AS build
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
FROM eclipse-temurin:24-jre-alpine-3.22@sha256:4044b6c87cb088885bcd0220f7dc7a8a4aab76577605fa471945d2e98270741f
# Correctifs Alpine publiés depuis la sortie de l'image (ex. brotli-libs,
# faille critique corrigée, le 31/10/2026)
RUN apk upgrade --no-cache
WORKDIR /app
# Seul le jar vient de l'étape 1 ; il appartient à root : non modifiable
COPY --from=build /src/app.jar /app/app.jar
# Compte sans droits (numéro 1001) : l'application ne tourne jamais en root
USER 1001:1001
EXPOSE 8080
# Sonde de santé : l'API répond-elle ? (les sondes de Kubernetes prendront
# le relais en phase 5)
HEALTHCHECK --interval=30s --timeout=3s --start-period=60s --retries=3 \
    CMD ["wget", "-q", "-O", "/dev/null", "http://127.0.0.1:8080/"]
ENTRYPOINT ["java", "-jar", "/app/app.jar"]
