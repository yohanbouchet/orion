#!/usr/bin/env python3
# Fichier  : scripts/dora.py
# Rôle     : calcule les 5 indicateurs DORA de la prod sur une période
#            (30 jours par défaut) à partir de l'API de GitHub :
#            déploiements de l'environnement production, commits livrés,
#            tickets étiquetés « incident » ; affiche un tableau Markdown
#            et, sur demande, écrit les mêmes valeurs au format texte de
#            Prometheus (importé dans VictoriaMetrics pour Grafana)
# Utilise  : bibliothèque standard de Python seulement ; API REST de GitHub
#            (lecture seule ; jeton facultatif pour un dépôt public)
# Utilisé par : workflow dora.yml (chaque jour ouvré) ; l'Ops en local ;
#            tests : scripts/tests/test_dora.py
# Paramètres (variables d'environnement) : DORA_DAYS (durée de la période,
#            en jours), GITHUB_REPOSITORY, GITHUB_API_URL, GITHUB_TOKEN,
#            GITHUB_STEP_SUMMARY (fournis par GitHub Actions) ;
#            DORA_METRICS_FILE (facultatif : fichier des métriques)
# Codes    : 0 réussi ; 1 appel à l'API GitHub en échec ; 2 paramètre
#            invalide
"""Calcule les indicateurs DORA de la prod à partir de l'API de GitHub."""

import json
import os
import statistics
import sys
import urllib.error
import urllib.request
from datetime import UTC, datetime, timedelta

# Environnement GitHub surveillé et étiquette des tickets d'incident
ENVIRONMENT = "production"
INCIDENT_LABEL = "incident"
# Derniers états d'un déploiement terminé (« waiting » : approbation)
FINISHED_STATES = ("success", "failure", "error")


def parse_time(text):
    """Date de l'API (« 2026-11-05T10:43:35Z ») → datetime en UTC."""
    return datetime.fromisoformat(text.replace("Z", "+00:00"))


def hours(delta):
    """Durée en heures (nombre à virgule)."""
    return delta.total_seconds() / 3600


def median_or_none(values):
    """Médiane (moins sensible qu'une moyenne à un cas extrême), ou None."""
    return statistics.median(values) if values else None


def ratio(part, total):
    """Part entre 0 et 1, ou None s'il n'y a rien à compter."""
    return part / total if total else None


def is_rework(commits):
    """Déploiement de reprise : il ne livre que des correctifs (fix)."""
    types = {c["message"].split(":")[0].split("(")[0] for c in commits}
    return types == {"fix"}


def caused_incident(deployment, incidents):
    """Un incident a été ouvert pendant que ce déploiement était actif."""
    end = deployment["next_time"] or datetime.max.replace(tzinfo=UTC)
    return any(deployment["time"] <= i["opened"] < end for i in incidents)


def compute(deployments, incidents, now, days):
    """Les 5 indicateurs DORA sur les `days` derniers jours."""
    start = now - timedelta(days=days)
    recent = [d for d in deployments if d["time"] >= start]
    successes = [d for d in recent if d["state"] == "success"]
    lead_times = [hours(d["time"] - c["time"])
                  for d in successes for c in d["commits"]]
    failed = [d for d in recent
              if d["state"] != "success" or caused_incident(d, incidents)]
    reworked = [d for d in successes if is_rework(d["commits"])]
    recovery = [hours(i["closed"] - i["opened"]) for i in incidents
                if i["closed"] and i["opened"] >= start]
    return {
        "deployments": len(recent),
        "first_deployment": recent[0]["time"] if recent else None,
        "deployments_per_week": len(successes) / (days / 7),
        "lead_time_hours": median_or_none(lead_times),
        "change_fail_rate": ratio(len(failed), len(recent)),
        "recovery_time_hours": median_or_none(recovery),
        "rework_rate": ratio(len(reworked), len(successes)),
    }


def format_report(metrics, days):
    """Tableau Markdown ; « n/a » quand il n'y a pas de donnée."""
    def show(value, unit):
        if value is None:
            return "n/a"
        if unit == "%":
            return f"{value:.0%}"
        return f"{value:.1f} {unit}"

    first = metrics["first_deployment"]
    rows = [
        ("Deployments counted (first one)",
         f"{metrics['deployments']} ({first:%Y-%m-%d})" if first else "0"),
        ("Deployment frequency", show(metrics["deployments_per_week"],
                                      "per week")),
        ("Change lead time (median)", show(metrics["lead_time_hours"], "h")),
        ("Change fail rate", show(metrics["change_fail_rate"], "%")),
        ("Failed deployment recovery time (median)",
         show(metrics["recovery_time_hours"], "h")),
        ("Deployment rework rate", show(metrics["rework_rate"], "%")),
    ]
    lines = [f"## DORA metrics ({ENVIRONMENT}, last {days} days)", "",
             "| Metric | Value |", "| --- | --- |"]
    lines += [f"| {name} | {value} |" for name, value in rows]
    return "\n".join(lines) + "\n"


# Nom de chaque métrique exportée → clé du résultat de compute() ; une
# valeur absente (aucune donnée) n'est pas exportée : Grafana affiche
# « No data » plutôt qu'un faux zéro
METRICS = (
    ("dora_deployments", "deployments"),
    ("dora_deployment_frequency_per_week", "deployments_per_week"),
    ("dora_change_lead_time_hours", "lead_time_hours"),
    ("dora_change_fail_ratio", "change_fail_rate"),
    ("dora_recovery_time_hours", "recovery_time_hours"),
    ("dora_rework_ratio", "rework_rate"),
)


def format_metrics(metrics, days):
    """Mêmes valeurs au format texte de Prometheus (une ligne par
    indicateur), avec l'environnement et la période en étiquettes."""
    labels = f'environment="{ENVIRONMENT}",window_days="{days}"'
    lines = [f"{name}{{{labels}}} {float(metrics[key]):g}"
             for name, key in METRICS if metrics[key] is not None]
    return "\n".join(lines) + "\n"


class GitHubClient:
    """Lecture de l'API REST de GitHub ; jeton envoyé s'il existe."""

    def __init__(self, api_url, repository, token=None):
        self.base = f"{api_url}/repos/{repository}"
        self.token = token

    def get(self, path):
        headers = {"Accept": "application/vnd.github+json",
                   "X-GitHub-Api-Version": "2022-11-28"}
        if self.token:
            headers["Authorization"] = f"Bearer {self.token}"
        req = urllib.request.Request(self.base + path, headers=headers)
        # Délai de 30 s : un appel bloqué ne fige pas le job
        with urllib.request.urlopen(req, timeout=30) as response:
            return json.loads(response.read())


def load_deployments(client):
    """Déploiements terminés de la prod, du plus ancien au plus récent,
    chacun avec ses commits livrés et l'heure du déploiement suivant."""
    found = []
    for d in client.get(f"/deployments?environment={ENVIRONMENT}"
                        "&per_page=100"):
        # États rendus du plus récent au plus ancien ; on garde le dernier
        # état final. « inactive » est ajouté par GitHub après coup (version
        # remplacée, environnement recréé : 22 déploiements de prod le
        # 10/11) : ce n'est pas le résultat du déploiement, on l'ignore
        statuses = client.get(f"/deployments/{d['id']}/statuses?per_page=20")
        final = next((s for s in statuses or []
                      if s["state"] in FINISHED_STATES), None)
        if final:
            found.append({"sha": d["sha"], "state": final["state"],
                          "time": parse_time(final["created_at"])})
    found.sort(key=lambda d: d["time"])
    for index, current in enumerate(found):
        previous = found[index - 1] if index else None
        current["commits"] = []
        current["next_time"] = None
        if previous:
            previous["next_time"] = current["time"]
            compare = client.get(
                f"/compare/{previous['sha']}...{current['sha']}")
            # Les commits de fusion (« Merge pull request ») ne comptent pas
            current["commits"] = [
                {"message": c["commit"]["message"],
                 "time": parse_time(c["commit"]["committer"]["date"])}
                for c in compare["commits"] if len(c["parents"]) == 1]
    return found


def load_incidents(client):
    """Tickets étiquetés « incident » : ouverture et fermeture."""
    issues = client.get(f"/issues?labels={INCIDENT_LABEL}&state=all"
                        "&per_page=100")
    return [{"opened": parse_time(i["created_at"]),
             "closed": parse_time(i["closed_at"]) if i["closed_at"] else None}
            for i in issues if "pull_request" not in i]


def main():
    days_text = os.environ.get("DORA_DAYS", "30")
    if not days_text.isdigit() or int(days_text) == 0:
        print("dora.py: DORA_DAYS must be a positive number of days",
              file=sys.stderr)
        return 2
    days = int(days_text)
    client = GitHubClient(
        os.environ.get("GITHUB_API_URL", "https://api.github.com"),
        os.environ.get("GITHUB_REPOSITORY", "yohanbouchet/orion"),
        os.environ.get("GITHUB_TOKEN"))
    try:
        deployments = load_deployments(client)
        incidents = load_incidents(client)
    except (urllib.error.URLError, TimeoutError) as error:
        print(f"dora.py: GitHub API call failed: {error}", file=sys.stderr)
        return 1
    metrics = compute(deployments, incidents, datetime.now(UTC), days)
    report = format_report(metrics, days)
    print(report)
    # Dans GitHub Actions : le tableau s'affiche aussi sur la page du run
    summary = os.environ.get("GITHUB_STEP_SUMMARY")
    if summary:
        with open(summary, "a", encoding="utf-8") as f:
            f.write(report)
    # Fichier des métriques, envoyé ensuite à VictoriaMetrics (dora.yml)
    metrics_file = os.environ.get("DORA_METRICS_FILE")
    if metrics_file:
        with open(metrics_file, "w", encoding="utf-8") as f:
            f.write(format_metrics(metrics, days))
    return 0


if __name__ == "__main__":
    sys.exit(main())
