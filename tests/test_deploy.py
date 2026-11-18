"""Файлы выкладки: образы закреплены, кнопку релиза жмут только свои, сигналы копий — в Healthchecks."""
from __future__ import annotations

import os
import re
import shutil
import subprocess
import tempfile
import threading
import unittest
from http.server import BaseHTTPRequestHandler, HTTPServer
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
UZCLOUD = ROOT / "deploy" / "uzcloud"
WORKFLOWS = ROOT / ".github" / "workflows"
PINNED = re.compile(r"^mirror\.gcr\.io/[a-z0-9/._-]+:[0-9][0-9.]*@sha256:[0-9a-f]{64}$")


def images() -> dict[str, list[str]]:
    """Образ → где встречается: compose (image:), backup.sh (*_IMAGE=), проверки (image:)."""
    found: dict[str, list[str]] = {}
    for path in [UZCLOUD / "compose.admin.yml", UZCLOUD / "compose.web.yml", WORKFLOWS / "tests.yml"]:
        for ref in re.findall(r"^\s*image:\s*(\S+)", path.read_text(encoding="utf-8"), re.M):
            if not ref.startswith("${"):  # свой образ сайта — по тегу коммита, собирается в релизе
                found.setdefault(ref, []).append(path.name)
    for ref in re.findall(r"^[A-Z_]+_IMAGE=(\S+)", (UZCLOUD / "backup.sh").read_text(encoding="utf-8"), re.M):
        found.setdefault(ref, []).append("backup.sh")
    return found


class ImagesCase(unittest.TestCase):
    def test_images_pinned_through_mirror(self):
        found = images()
        self.assertGreaterEqual(len(found), 3)
        for ref, where in found.items():
            self.assertRegex(ref, PINNED, f"{ref} ({', '.join(where)}): нужна точная версия и digest через mirror.gcr.io")

    def test_one_postgres_everywhere(self):
        postgres = {ref: where for ref, where in images().items() if "/postgres:" in ref}
        self.assertEqual(len(postgres), 1, f"разные PostgreSQL: {postgres}")
        self.assertEqual(sorted(next(iter(postgres.values()))), ["backup.sh", "compose.admin.yml", "tests.yml"])


class WorkflowsCase(unittest.TestCase):
    def test_actions_pinned_by_sha(self):
        for path in WORKFLOWS.glob("*.yml"):
            for ref in re.findall(r"uses:\s*(\S+)", path.read_text(encoding="utf-8")):
                if ref.startswith("./"):
                    continue
                self.assertRegex(ref, r"@[0-9a-f]{40}$", f"{path.name}: {ref} — по SHA коммита, а не по тегу")

    def test_release_gate_comes_first(self):
        text = (WORKFLOWS / "release.yml").read_text(encoding="utf-8")
        steps = re.findall(r"^      - (?:name|uses): (.+)$", text, re.M)
        self.assertEqual(steps[0], "Кто и откуда выкладывает")  # до checkout и до любого SSH
        self.assertIn("vars.RELEASE_ACTORS", text)
        self.assertIn("vars.RELEASE_BRANCH || 'main'", text)

    def test_release_gate_logic(self):
        """Сам шаг проверки — как его выполнит GitHub, с разными логинами и ветками."""
        text = (WORKFLOWS / "release.yml").read_text(encoding="utf-8")
        script = re.search(r"- name: Кто и откуда выкладывает\n.*?run: \|\n(.*?)\n\n", text, re.S).group(1)
        script = "\n".join(line[10:] for line in script.splitlines())

        def run(actor, ref, allowed="Tem4ik69, nsayfullaev2007-dev", branch="uzcloud"):
            env = {"PATH": os.environ["PATH"], "ACTOR": actor, "ALLOWED": allowed, "BRANCH": branch, "GITHUB_REF": ref}
            return subprocess.run(["bash", "-c", script], env=env, capture_output=True, text=True).returncode

        self.assertEqual(run("tem4ik69", "refs/heads/uzcloud"), 0)           # регистр логина не важен
        self.assertEqual(run("nsayfullaev2007-dev", "refs/heads/uzcloud"), 0)
        self.assertNotEqual(run("xondamirx9", "refs/heads/uzcloud"), 0)       # право записи — не право релиза
        self.assertNotEqual(run("Tem4ik69", "refs/heads/feature"), 0)        # не та ветка
        self.assertNotEqual(run("Tem4ik69", "refs/heads/uzcloud", allowed=""), 0)  # список пуст — никому
        self.assertNotEqual(run("tem4ik", "refs/heads/uzcloud"), 0)          # часть логина не считается


class PingHandler(BaseHTTPRequestHandler):
    hits: list[tuple[str, str]] = []

    def do_POST(self):  # noqa: N802
        body = self.rfile.read(int(self.headers.get("Content-Length") or 0)).decode()
        PingHandler.hits.append((self.path, body))
        self.send_response(200)
        self.end_headers()

    def log_message(self, *args):
        pass


@unittest.skipUnless(shutil.which("curl"), "нужен curl")
class BackupSignalsCase(unittest.TestCase):
    """backup.sh шлёт /start и /fail в Healthchecks; копия перед релизом — без сигналов."""

    def setUp(self):
        PingHandler.hits = []
        self.server = HTTPServer(("127.0.0.1", 0), PingHandler)
        threading.Thread(target=self.server.serve_forever, daemon=True).start()
        self.home = Path(tempfile.mkdtemp())
        (self.home / "env").mkdir()
        (self.home / "deploy").mkdir()
        base = f"http://127.0.0.1:{self.server.server_port}"
        (self.home / "env" / "backup.env").write_text(
            "S3_ENDPOINT=https://s3.example\nS3_BUCKET=b\nS3_ACCESS_KEY=k\nS3_SECRET_KEY=s\n"
            f"BACKUP_PASSPHRASE=p\nHC_PING_DB={base}/db\nHC_PING_CHECK={base}/check\n")
        # Вместо docker — заглушка: база «не запущена», хранилище «недоступно»
        bin_dir = self.home / "bin"
        bin_dir.mkdir()
        (bin_dir / "docker").write_text("#!/bin/sh\nexit 1\n")
        (bin_dir / "docker").chmod(0o755)
        self.env = {"PATH": f"{bin_dir}:{os.environ['PATH']}", "CODEXLAB_HOME": str(self.home)}

    def tearDown(self):
        self.server.shutdown()
        self.server.server_close()
        shutil.rmtree(self.home)

    def backup(self, *args):
        return subprocess.run(["bash", str(UZCLOUD / "backup.sh"), *args], env=self.env, capture_output=True, text=True)

    def test_nightly_failure_reaches_healthchecks(self):
        result = self.backup("db")
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual([path for path, _ in PingHandler.hits], ["/db/start", "/db/fail"])
        self.assertIn("база не запущена", PingHandler.hits[-1][1])

    def test_restore_check_failure_reaches_healthchecks(self):
        result = self.backup("check")
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual([path for path, _ in PingHandler.hits][0], "/check/start")
        self.assertEqual(PingHandler.hits[-1][0], "/check/fail")

    def test_release_copy_sends_nothing(self):
        self.backup("db", "release")
        self.assertEqual(PingHandler.hits, [])

    def test_no_addresses_no_signals(self):
        env_file = self.home / "env" / "backup.env"
        env_file.write_text("\n".join(l for l in env_file.read_text().splitlines() if not l.startswith("HC_")))
        self.assertNotEqual(self.backup("db").returncode, 0)
        self.assertEqual(PingHandler.hits, [])


if __name__ == "__main__":
    unittest.main()
