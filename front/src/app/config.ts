// Fichier  : front/src/app/config.ts
// Rôle     : adresse de l'API appelée par les services : « /api », à la même
//            adresse que le front (pas de CORS) ; relayée vers le back par
//            nginx dans Kubernetes (chart Helm) ou par ng serve en local
//            (src/proxy.conf.json, préfixe /api retiré)
// Utilisé par : person.service.ts, organization.service.ts ; ticket #65
export const API_BASE_URL = "/api"
