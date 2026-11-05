// Fichier  : infra/k6/microcrm.js
// Rôle     : tests de charge de MicroCRM avec k6 : parcours d'un
//            utilisateur (accueil, listes, fiche, création + suppression)
//            sous 6 profils de charge (types de tests de la doc k6)
// Utilise  : k6 2.3.0 ; variables BASE_URL (adresse du front) et
//            TEST_TYPE (smoke, average, stress, spike, breakpoint, soak)
// Utilisé par : scripts/load-test.sh (Job k6 dans staging) ; workflow
//            load-test.yml ; contrôle depuis un autre poste
import http from 'k6/http';
import { check, group, sleep } from 'k6';

const BASE_URL = __ENV.BASE_URL || 'http://127.0.0.1:18090';
const TEST_TYPE = __ENV.TEST_TYPE || 'smoke';

// Profils de charge : nombre d'utilisateurs simulés (VUs) dans le temps
const PROFILES = {
  // Fumée : 1 utilisateur, le script et l'appli fonctionnent
  smoke: { executor: 'constant-vus', vus: 1, duration: '30s' },
  // Charge moyenne : la fréquentation normale attendue
  average: { executor: 'ramping-vus', stages: [
    { duration: '1m', target: 20 },
    { duration: '3m', target: 20 },
    { duration: '1m', target: 0 },
  ] },
  // Stress : 3 fois la charge moyenne
  stress: { executor: 'ramping-vus', stages: [
    { duration: '1m', target: 60 },
    { duration: '3m', target: 60 },
    { duration: '1m', target: 0 },
  ] },
  // Pic : arrivée brutale, puis retour au calme
  spike: { executor: 'ramping-vus', stages: [
    { duration: '10s', target: 100 },
    { duration: '40s', target: 100 },
    { duration: '10s', target: 0 },
  ] },
  // Point de rupture : débit croissant jusqu'à l'échec des seuils
  breakpoint: {
    executor: 'ramping-arrival-rate',
    startRate: 10, timeUnit: '1s',
    preAllocatedVUs: 50, maxVUs: 300,
    stages: [{ duration: '10m', target: 200 }],
  },
  // Endurance : charge moyenne pendant 30 min (fuite de mémoire ?)
  soak: { executor: 'ramping-vus', stages: [
    { duration: '2m', target: 20 },
    { duration: '26m', target: 20 },
    { duration: '2m', target: 0 },
  ] },
};

if (!PROFILES[TEST_TYPE]) {
  throw new Error(`Unknown TEST_TYPE: ${TEST_TYPE}`);
}

export const options = {
  scenarios: { [TEST_TYPE]: PROFILES[TEST_TYPE] },
  // Seuils de réussite : un seuil dépassé fait échouer le test
  thresholds: {
    http_req_failed: ['rate<0.01'],
    http_req_duration: ['p(95)<500', 'p(99)<1500'],
    checks: ['rate>0.99'],
    // Point de rupture : on arrête dès que les erreurs passent 5 %
    ...(TEST_TYPE === 'breakpoint' && {
      'http_req_failed{scenario:breakpoint}': [
        { threshold: 'rate<0.05', abortOnFail: true, delayAbortEval: '30s' },
      ],
    }),
  },
  // Étiquette commune à toutes les mesures : retrouver ce test dans Grafana
  tags: { testid: `${TEST_TYPE}-${Date.now()}` },
};

// Accept : sans lui, l'API répond 201 sans corps (donc sans identifiant)
const JSON_HEADERS = {
  headers: { 'Content-Type': 'application/json', Accept: 'application/json' },
};

// Pause d'un humain qui lit l'écran : 1 à 3 s ; aucune pour le point de
// rupture, qui règle lui-même le nombre de parcours par seconde
function think() {
  if (TEST_TYPE !== 'breakpoint') {
    sleep(1 + Math.random() * 2);
  }
}

export default function () {
  group('home page', () => {
    const res = http.get(`${BASE_URL}/`);
    check(res, { 'home 200': (r) => r.status === 200 });
  });
  think();

  let persons = [];
  group('lists', () => {
    const res = http.get(`${BASE_URL}/api/persons`);
    check(res, { 'persons 200': (r) => r.status === 200 });
    persons = res.json('_embedded.persons') || [];
    const orgs = http.get(`${BASE_URL}/api/organizations`);
    check(orgs, { 'organizations 200': (r) => r.status === 200 });
  });
  think();

  if (persons.length > 0) {
    group('person details', () => {
      const one = persons[Math.floor(Math.random() * persons.length)];
      const res = http.get(`${BASE_URL}/api/persons/${one.id}`,
        { tags: { name: 'person by id' } });
      check(res, { 'person 200': (r) => r.status === 200 });
    });
    think();
  }

  // 1 fois sur 10 : création puis suppression (aucune donnée laissée)
  if (Math.random() < 0.1) {
    group('create and delete', () => {
      const body = JSON.stringify({
        firstName: 'Load', lastName: `Test${__VU}`,
        email: `load.test.${__VU}.${__ITER}@example.com`,
      });
      const created = http.post(`${BASE_URL}/api/persons`, body,
        JSON_HEADERS);
      check(created, { 'create 201': (r) => r.status === 201 });
      if (created.status === 201) {
        const id = created.json('id');
        const removed = http.del(`${BASE_URL}/api/persons/${id}`, null,
          { tags: { name: 'delete person' } });
        check(removed, { 'delete 204': (r) => r.status === 204 });
      }
    });
    think();
  }
}
