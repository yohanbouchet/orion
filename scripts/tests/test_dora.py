# Fichier  : scripts/tests/test_dora.py
# Rôle     : tests unitaires de scripts/dora.py (pytest), avec des
#            données figées et un faux client GitHub (doublure) : aucun
#            appel réseau
# Utilise  : pytest 9.2.0 (scripts/tests/requirements.txt), dora.py
# Utilisé par : job script-tests de la CI ; en local : pytest scripts/tests
"""Tests unitaires de scripts/dora.py."""

import sys
from datetime import UTC, datetime
from pathlib import Path

import pytest

# dora.py n'est pas un paquet installé : on ajoute scripts/ au chemin
sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
import dora

NOW = datetime(2026, 11, 30, 12, 0, tzinfo=UTC)


def at(day, hour=12):
    """Date du mois de novembre 2026, en UTC."""
    return datetime(2026, 11, day, hour, 0, tzinfo=UTC)


def deployment(day, state="success", commits=(), next_day=None):
    """Déploiement tel que load_deployments le prépare."""
    return {"sha": f"sha{day}", "state": state, "time": at(day),
            "commits": list(commits),
            "next_time": at(next_day) if next_day else None}


def commit(message, day, hour=12):
    return {"message": message, "time": at(day, hour)}


def test_parse_time_reads_github_dates_in_utc():
    assert dora.parse_time("2026-11-05T10:43:35Z") == datetime(
        2026, 11, 5, 10, 43, 35, tzinfo=UTC)


@pytest.mark.parametrize("messages, expected", [
    (["fix(monitoring): a", "fix(ansible): b"], True),
    (["fix(back): a", "feat(back): b"], False),
    (["docs(readme): a"], False),
    ([], False),
])
def test_rework_means_only_fix_commits(messages, expected):
    commits = [commit(m, 1) for m in messages]
    assert dora.is_rework(commits) is expected


def test_frequency_counts_successes_in_the_period_only():
    deployments = [deployment(1), deployment(20), deployment(21),
                   deployment(22, state="failure")]
    metrics = dora.compute(deployments, [], NOW, days=14)
    # 2 réussis en 14 jours (le 1er est hors période, l'échec ne compte pas)
    assert metrics["deployments_per_week"] == 1
    assert metrics["deployments"] == 3
    assert metrics["first_deployment"] == at(20)


def test_lead_time_is_the_median_from_commit_to_deployment():
    deployments = [deployment(20, commits=[
        commit("feat: a", 19, 12),   # 24 h avant
        commit("fix: b", 20, 10),    # 2 h avant
        commit("docs: c", 20, 11),   # 1 h avant
    ])]
    metrics = dora.compute(deployments, [], NOW, days=30)
    assert metrics["lead_time_hours"] == 2


def test_failure_status_and_incident_both_count_as_failed():
    deployments = [deployment(10, next_day=12),
                   deployment(12, next_day=14),
                   deployment(14, state="failure")]
    # Incident ouvert pendant que le déploiement du 10 était en prod
    incidents = [{"opened": at(11), "closed": at(11, 18)}]
    metrics = dora.compute(deployments, incidents, NOW, days=30)
    assert metrics["change_fail_rate"] == pytest.approx(2 / 3)
    assert metrics["recovery_time_hours"] == 6


def test_open_incident_has_no_recovery_time_yet():
    incidents = [{"opened": at(11), "closed": None}]
    metrics = dora.compute([deployment(10)], incidents, NOW, days=30)
    assert metrics["change_fail_rate"] == 1
    assert metrics["recovery_time_hours"] is None


def test_rework_rate_among_successful_deployments():
    deployments = [deployment(10, commits=[commit("feat: a", 10, 9)]),
                   deployment(11, commits=[commit("fix: b", 11, 9)])]
    metrics = dora.compute(deployments, [], NOW, days=30)
    assert metrics["rework_rate"] == 0.5


def test_no_deployment_gives_empty_values_not_a_crash():
    metrics = dora.compute([], [], NOW, days=30)
    assert metrics["deployments_per_week"] == 0
    assert metrics["lead_time_hours"] is None
    assert metrics["change_fail_rate"] is None
    report = dora.format_report(metrics, 30)
    assert "| Change fail rate | n/a |" in report
    assert "| Deployments counted (first one) | 0 |" in report


class FakeClient:
    """Doublure du client GitHub : réponses préparées, par chemin."""

    def __init__(self, answers):
        self.answers = answers

    def get(self, path):
        return self.answers[path.split("?")[0]]


def api_commit(message, date, parents=1):
    return {"commit": {"message": message, "committer": {"date": date}},
            "parents": [{}] * parents}


def test_load_deployments_keeps_finished_ones_with_their_commits():
    client = FakeClient({
        "/deployments": [
            {"id": 2, "sha": "b"}, {"id": 1, "sha": "a"},
            {"id": 3, "sha": "c"}],
        "/deployments/1/statuses": [
            {"state": "success", "created_at": "2026-11-01T10:00:00Z"}],
        # Marqué « inactive » plus tard (environnement recréé) : le
        # résultat reste le succès, à l'heure du succès
        "/deployments/2/statuses": [
            {"state": "inactive", "created_at": "2026-11-10T10:09:00Z"},
            {"state": "success", "created_at": "2026-11-02T10:00:00Z"},
            {"state": "in_progress", "created_at": "2026-11-02T09:59:00Z"}],
        # En attente d'approbation : ignoré
        "/deployments/3/statuses": [
            {"state": "waiting", "created_at": "2026-11-03T10:00:00Z"}],
        "/compare/a...b": {"commits": [
            api_commit("fix: b", "2026-11-02T09:00:00Z"),
            api_commit("Merge pull request #2", "2026-11-02T09:30:00Z",
                       parents=2)]},
    })
    found = dora.load_deployments(client)
    assert [d["sha"] for d in found] == ["a", "b"]
    assert found[0]["commits"] == []
    assert found[0]["next_time"] == found[1]["time"]
    assert found[1]["state"] == "success"
    assert found[1]["time"] == dora.parse_time("2026-11-02T10:00:00Z")
    assert [c["message"] for c in found[1]["commits"]] == ["fix: b"]


def test_load_incidents_ignores_pull_requests():
    client = FakeClient({"/issues": [
        {"created_at": "2026-11-05T08:00:00Z",
         "closed_at": "2026-11-05T09:00:00Z"},
        {"created_at": "2026-11-06T08:00:00Z", "closed_at": None},
        {"created_at": "2026-11-06T08:00:00Z", "closed_at": None,
         "pull_request": {}},
    ]})
    incidents = dora.load_incidents(client)
    assert len(incidents) == 2
    assert incidents[1]["closed"] is None


@pytest.mark.parametrize("value", ["abc", "0", "-3"])
def test_invalid_period_stops_with_code_2(monkeypatch, value):
    monkeypatch.setenv("DORA_DAYS", value)
    assert dora.main() == 2


def test_api_failure_stops_with_code_1(monkeypatch):
    def fail(self, path):
        raise dora.urllib.error.URLError("unreachable")

    monkeypatch.setenv("DORA_DAYS", "30")
    monkeypatch.setattr(dora.GitHubClient, "get", fail)
    assert dora.main() == 1


def test_metrics_use_prometheus_text_format_with_labels():
    metrics = {"deployments": 22, "first_deployment": NOW,
               "deployments_per_week": 5.133, "lead_time_hours": 2.9,
               "change_fail_rate": 0.0, "recovery_time_hours": None,
               "rework_rate": 0.32}
    text = dora.format_metrics(metrics, 30)
    labels = '{environment="production",window_days="30"}'
    assert f"dora_deployments{labels} 22\n" in text
    assert f"dora_deployment_frequency_per_week{labels} 5.133\n" in text
    assert f"dora_change_fail_ratio{labels} 0\n" in text
    # Aucune donnée : pas de ligne (Grafana affiche « No data »)
    assert "dora_recovery_time_hours" not in text
    assert len(text.splitlines()) == 5


def test_metrics_file_written_only_when_asked(monkeypatch, tmp_path):
    monkeypatch.setenv("DORA_DAYS", "30")
    monkeypatch.delenv("GITHUB_STEP_SUMMARY", raising=False)
    monkeypatch.setattr(dora, "load_deployments", lambda client: [])
    monkeypatch.setattr(dora, "load_incidents", lambda client: [])
    monkeypatch.delenv("DORA_METRICS_FILE", raising=False)
    assert dora.main() == 0
    assert list(tmp_path.iterdir()) == []
    target = tmp_path / "dora.prom"
    monkeypatch.setenv("DORA_METRICS_FILE", str(target))
    assert dora.main() == 0
    assert target.read_text().startswith("dora_deployments{")
