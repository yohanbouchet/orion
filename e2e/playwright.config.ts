// Fichier  : e2e/playwright.config.ts
// Rôle     : réglages des tests de bout en bout : un vrai navigateur
//            (Chromium) joue les parcours de tests/ contre MicroCRM
//            démarré par compose.yaml (base, back, front)
// Utilise  : @playwright/test (Apache 2.0) ; variable BASE_URL
// Utilisé par : scripts/e2e.sh (job e2e de la CI, et en local)
import { defineConfig, devices } from "@playwright/test"

export default defineConfig({
  testDir: "./tests",
  // Un parcours ne doit pas dépendre d'un autre : ordre libre
  fullyParallel: true,
  // test.only oublié dans le code : refusé dans la CI
  forbidOnly: !!process.env.CI,
  // 1 nouvel essai dans la CI : un échec isolé (lenteur) est distingué
  // d'une vraie panne ; la trace du 1er essai est gardée
  retries: process.env.CI ? 1 : 0,
  timeout: 30_000,
  reporter: [
    ["list"],
    ["html", { outputFolder: "playwright-report", open: "never" }],
  ],
  use: {
    // Adresse du front (nginx), qui relaie /api vers le back
    baseURL: process.env.BASE_URL ?? "http://localhost:8080",
    // Preuves en cas d'échec : trace (pas à pas), capture, vidéo
    trace: "on-first-retry",
    screenshot: "only-on-failure",
    video: "retain-on-failure",
  },
  projects: [{ name: "chromium", use: { ...devices["Desktop Chrome"] } }],
})
