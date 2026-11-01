# Fichier  : scripts/tests/test_notify.py
# Rôle     : tests unitaires de scripts/notify.py (pytest), avec un faux
#            client GitHub (doublure) : aucun appel réseau, aucun ticket
# Utilise  : pytest 9.2.0 (scripts/tests/requirements.txt), notify.py
# Utilisé par : job script-tests de la CI ; en local : pytest scripts/tests
"""Tests unitaires de scripts/notify.py."""

import sys
from pathlib import Path

import pytest

# notify.py n'est pas un paquet installé : on ajoute scripts/ au chemin
sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
import notify

RUN_URL = "https://github.com/acme/app/actions/runs/1"
SHA = "0123456789abcdef"


class FakeClient:
    """Doublure du client GitHub : note les appels, renvoie des réponses
    préparées à l'avance."""

    def __init__(self, open_issues=(), assignees=("owner",)):
        self.open_issues = list(open_issues)
        self.assignees = list(assignees)
        self.calls = []

    def request(self, method, path, body=None):
        self.calls.append((method, path, body))
        if method == "GET":
            return self.open_issues
        if method == "POST" and path == "/issues":
            return {"number": 7, "assignees": self.assignees}
        return {}


# Ticket de panne déjà ouvert, tel que GitHub le renvoie (champs utiles)
def broken_issue():
    return {"number": 3, "title": notify.ISSUE_TITLE}


def test_failed_jobs_keeps_failures_and_cancellations_only():
    needs = {
        "trivy": {"result": "failure"},
        "images": {"result": "cancelled"},
        "release": {"result": "skipped"},
        "test-front": {"result": "success"},
    }
    assert notify.failed_jobs(needs) == ["images", "trivy"]


def test_drill_adds_a_simulated_failure():
    assert notify.failed_jobs({}, simulate=True) == [
        "simulated-failure (notification drill)"]


def test_first_failure_opens_an_issue_assigned_to_the_owner():
    client = FakeClient()
    action = notify.notify(client, ["trivy"], RUN_URL, SHA, "owner")
    assert action == "opened"
    method, path, body = client.calls[-1]
    assert (method, path) == ("POST", "/issues")
    assert body["title"] == notify.ISSUE_TITLE
    assert body["assignees"] == ["owner"]
    assert "@owner" in body["body"]
    assert RUN_URL in body["body"]


def test_dropped_assignee_is_reported(capsys):
    notify.notify(FakeClient(assignees=()), ["trivy"], RUN_URL, SHA, "owner")
    assert "assignee dropped" in capsys.readouterr().err


def test_new_failure_comments_the_open_issue():
    client = FakeClient(open_issues=[broken_issue()])
    action = notify.notify(client, ["trivy"], RUN_URL, SHA, "owner")
    assert action == "commented"
    assert client.calls[-1][:2] == ("POST", "/issues/3/comments")


def test_success_closes_the_open_issue():
    client = FakeClient(open_issues=[broken_issue()])
    action = notify.notify(client, [], RUN_URL, SHA, "owner")
    assert action == "closed"
    assert client.calls[-1] == (
        "PATCH", "/issues/3",
        {"state": "closed", "state_reason": "completed"})


def test_success_without_open_issue_does_nothing():
    client = FakeClient()
    assert notify.notify(client, [], RUN_URL, SHA, "owner") == "nothing"
    assert [call[0] for call in client.calls] == ["GET"]


def test_summary_lists_failed_jobs(tmp_path):
    summary = tmp_path / "summary.md"
    notify.write_summary(str(summary), ["trivy"], "opened")
    text = summary.read_text(encoding="utf-8")
    assert "failure (opened)" in text
    assert "- `trivy`" in text


def test_main_without_parameters_returns_2(monkeypatch):
    monkeypatch.delenv("NEEDS_JSON", raising=False)
    assert notify.main() == 2


@pytest.mark.parametrize("value, expected", [("true", True), ("false", False)])
def test_main_reads_the_drill_switch(monkeypatch, value, expected):
    seen = {}

    def fake_notify(client, failed, run_url, sha, owner):
        seen["failed"] = failed
        return "nothing"

    for name in ("GITHUB_SERVER_URL", "GITHUB_REPOSITORY", "GITHUB_RUN_ID",
                 "GITHUB_SHA", "GITHUB_REPOSITORY_OWNER", "GITHUB_API_URL",
                 "GITHUB_TOKEN"):
        monkeypatch.setenv(name, "x")
    monkeypatch.setenv("NEEDS_JSON", "{}")
    monkeypatch.setenv("SIMULATE_FAILURE", value)
    monkeypatch.delenv("GITHUB_STEP_SUMMARY", raising=False)
    monkeypatch.setattr(notify, "notify", fake_notify)
    assert notify.main() == 0
    assert bool(seen["failed"]) is expected
