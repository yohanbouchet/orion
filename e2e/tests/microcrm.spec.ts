// Fichier  : e2e/tests/microcrm.spec.ts
// Rôle     : parcours d'un utilisateur dans MicroCRM, dans un vrai
//            navigateur : page d'accueil, création d'une organisation,
//            création d'une personne rattachée à cette organisation ;
//            chaque élément est trouvé par son rôle et son nom lisible
//            (comme un lecteur d'écran), jamais par une classe CSS
// Utilise  : @playwright/test ; front + back + base (compose.yaml)
// Utilisé par : playwright.config.ts
import { expect, test } from "@playwright/test"

// Noms uniques : un nouvel essai ne retrouve pas les données du 1er
const unique = () => `${Date.now()}-${Math.floor(Math.random() * 1000)}`

// Crée une organisation par l'interface et renvoie son nom
async function createOrganization(page: import("@playwright/test").Page) {
  const name = `E2E Org ${unique()}`
  await page.goto("/")
  await page.getByRole("link", { name: "New organization" }).click()
  await page.getByLabel("Name *").fill(name)
  await page.getByRole("button", { name: "Save" }).click()
  // Après l'enregistrement, l'adresse contient le numéro attribué
  await expect(page).toHaveURL(/\/organizations\/\d+$/)
  return name
}

test("home page lists persons and organizations", async ({ page }) => {
  await page.goto("/")
  await expect(page.getByRole("heading", { name: "Persons" })).toBeVisible()
  await expect(
    page.getByRole("heading", { name: "Organizations" }),
  ).toBeVisible()
})

test("an organization can be created", async ({ page }) => {
  const name = await createOrganization(page)
  await page.goto("/")
  await expect(page.getByRole("link", { name })).toBeVisible()
})

test("a person can be created and linked to an organization", async ({
  page,
}) => {
  const organization = await createOrganization(page)
  const lastName = `Doe-${unique()}`

  await page.goto("/")
  await page.getByRole("link", { name: "New person" }).click()
  await page.getByLabel("First name *").fill("Jane")
  await page.getByLabel("Last name *").fill(lastName)
  await page.getByLabel("Email").fill("jane.doe@example.test")
  await page.getByRole("button", { name: "Save" }).click()
  await expect(page).toHaveURL(/\/persons\/\d+$/)

  // Rattachement : choisir l'organisation, puis le bouton « + »
  await page
    .getByLabel("Organization to add")
    .selectOption({ label: organization })
  await page
    .getByRole("button", { name: "Add the selected organization" })
    .click()
  // exact : la cellule du bouton « Remove <nom> » contient aussi le nom
  await expect(
    page.getByRole("cell", { name: organization, exact: true }),
  ).toBeVisible()

  // La personne apparaît sur la page d'accueil
  await page.goto("/")
  await expect(
    page.getByRole("link", { name: `Jane ${lastName}` }),
  ).toBeVisible()
})
