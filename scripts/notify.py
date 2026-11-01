#!/usr/bin/env python3
# Fichier  : scripts/notify.py
# Rôle     : notifie le résultat du pipeline sur main : en cas d'échec,
#            ouvre (ou commente) un ticket « CI failing on main » assigné au
#            propriétaire du dépôt, ce qui envoie un e-mail par GitHub ; au
#            retour au vert, commente et ferme ce ticket ; écrit toujours un
#            résumé dans la page de l'exécution
# Utilise  : bibliothèque standard de Python seulement ; API REST de GitHub
#            avec le jeton temporaire du job (droit issues: write)
# Utilisé par : job notify de ci.yml ; tests : scripts/tests/test_notify.py
# Paramètres (variables d'environnement) : NEEDS_JSON (résultat des jobs,
#            fourni par la CI), SIMULATE_FAILURE (« true » : exercice
#            d'alerte), GITHUB_TOKEN, GITHUB_REPOSITORY,
#            GITHUB_REPOSITORY_OWNER, GITHUB_SERVER_URL, GITHUB_API_URL,
#            GITHUB_RUN_ID, GITHUB_SHA, GITHUB_STEP_SUMMARY (fournis par
#            GitHub Actions)
"""Notifie le résultat de la CI sur main par un ticket GitHub."""

import json
import os
import sys
import urllib.parse
import urllib.request
from datetime import UTC, datetime

# Titre du ticket de panne : sert aussi à retrouver le ticket déjà ouvert
ISSUE_TITLE = "CI failing on main"
# Auteur des tickets ouverts par le jeton de la CI
BOT_LOGIN = "github-actions[bot]"
# Résultats de job considérés comme un échec (« skipped » n'en est pas un)
FAILED_RESULTS = ("failure", "cancelled")


def log(level, message):
    """Journal au même format que scripts/lib/common.sh, sur stderr."""
    now = datetime.now(UTC).strftime("%Y-%m-%dT%H:%M:%SZ")
    print(f"{now} {level:<5} notify.py: {message}", file=sys.stderr)


def failed_jobs(needs, simulate=False):
    """Noms des jobs en échec, triés ; l'exercice ajoute un faux job."""
    failed = sorted(
        name for name, job in needs.items()
        if job.get("result") in FAILED_RESULTS
    )
    if simulate:
        failed.append("simulated-failure (notification drill)")
    return failed


class GitHubClient:
    """Appels à l'API REST de GitHub ; le jeton ne quitte jamais l'en-tête."""

    def __init__(self, api_url, repository, token):
        self.base = f"{api_url}/repos/{repository}"
        self.token = token

    def request(self, method, path, body=None):
        data = json.dumps(body).encode() if body is not None else None
        req = urllib.request.Request(
            self.base + path, data=data, method=method,
            headers={
                "Authorization": f"Bearer {self.token}",
                "Accept": "application/vnd.github+json",
                "X-GitHub-Api-Version": "2022-11-28",
            },
        )
        # Délai de 30 s : un appel bloqué ne fige pas le job
        with urllib.request.urlopen(req, timeout=30) as response:
            return json.loads(response.read() or "null")


def find_open_issue(client):
    """Ticket de panne déjà ouvert par la CI, ou None."""
    creator = urllib.parse.quote(BOT_LOGIN)
    issues = client.request("GET", f"/issues?state=open&creator={creator}")
    for issue in issues:
        if issue["title"] == ISSUE_TITLE and "pull_request" not in issue:
            return issue
    return None


def notify(client, failed, run_url, sha, owner):
    """Ouvre, commente ou ferme le ticket ; renvoie l'action faite."""
    issue = find_open_issue(client)
    if failed:
        jobs = "\n".join(f"- `{name}`" for name in failed)
        text = (f"Commit `{sha[:7]}`: failed jobs:\n\n{jobs}\n\n"
                f"Run: {run_url}")
        if issue is None:
            created = client.request("POST", "/issues", {
                "title": ISSUE_TITLE,
                "body": f"@{owner} the pipeline failed on main.\n\n{text}",
                "assignees": [owner],
            })
            if not created.get("assignees"):
                log("WARN", "assignee dropped; relying on the @mention")
            return "opened"
        client.request("POST", f"/issues/{issue['number']}/comments",
                       {"body": f"Still failing.\n\n{text}"})
        return "commented"
    if issue is not None:
        client.request("POST", f"/issues/{issue['number']}/comments",
                       {"body": f"Fixed by `{sha[:7]}`: {run_url}"})
        client.request("PATCH", f"/issues/{issue['number']}",
                       {"state": "closed", "state_reason": "completed"})
        return "closed"
    return "nothing"


def write_summary(path, failed, action):
    """Résumé affiché dans la page de l'exécution (si GitHub le permet)."""
    if not path:
        return
    status = "failure" if failed else "success"
    lines = [f"## Notification: {status} ({action})", ""]
    lines += [f"- `{name}`" for name in failed] or ["All jobs succeeded."]
    with open(path, "a", encoding="utf-8") as summary:
        summary.write("\n".join(lines) + "\n")


def main():
    """Lit les paramètres, notifie ; codes : 0 réussi, 1 échec, 2 usage."""
    env = os.environ
    try:
        needs = json.loads(env["NEEDS_JSON"])
        simulate = env.get("SIMULATE_FAILURE", "false") == "true"
        server, repo = env["GITHUB_SERVER_URL"], env["GITHUB_REPOSITORY"]
        run_url = f"{server}/{repo}/actions/runs/{env['GITHUB_RUN_ID']}"
        sha, owner = env["GITHUB_SHA"], env["GITHUB_REPOSITORY_OWNER"]
        client = GitHubClient(env["GITHUB_API_URL"], repo,
                              env["GITHUB_TOKEN"])
    except (KeyError, json.JSONDecodeError) as error:
        log("ERROR", f"missing or invalid parameter: {error}")
        return 2
    failed = failed_jobs(needs, simulate)
    try:
        action = notify(client, failed, run_url, sha, owner)
    except OSError as error:
        log("ERROR", f"GitHub API call failed: {error}")
        return 1
    write_summary(env.get("GITHUB_STEP_SUMMARY"), failed, action)
    log("INFO", f"{len(failed)} failed job(s); issue {action}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
