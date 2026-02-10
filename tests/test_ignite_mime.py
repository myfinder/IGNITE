"""tests/test_ignite_mime.py — ignite_mime.py のユニットテスト"""
import json
import subprocess
import sys
import tempfile
from pathlib import Path

import pytest

# ignite_mime.py のパス
SCRIPT = Path(__file__).resolve().parent.parent / "scripts" / "lib" / "ignite_mime.py"


def run_cli(*args: str, input_data: str | None = None) -> subprocess.CompletedProcess:
    return subprocess.run(
        [sys.executable, str(SCRIPT), *args],
        capture_output=True, text=True, input=input_data,
    )


# === build ===

class TestBuild:
    def test_basic_build(self):
        r = run_cli("build", "--from", "strategist", "--to", "coordinator",
                     "--type", "task_list", "--body", "hello: world")
        assert r.returncode == 0
        assert "From: strategist" in r.stdout
        assert "To: coordinator" in r.stdout
        assert "X-IGNITE-Type: task_list" in r.stdout
        assert "Content-Transfer-Encoding: 8bit" in r.stdout
        assert "hello: world" in r.stdout

    def test_cc_header(self):
        r = run_cli("build", "--from", "a", "--to", "b", "--cc", "c", "d",
                     "--type", "test", "--body", "x")
        assert "Cc: c, d" in r.stdout

    def test_priority_default(self):
        r = run_cli("build", "--from", "a", "--to", "b", "--type", "t", "--body", "")
        assert "X-IGNITE-Priority: normal" in r.stdout

    def test_custom_priority(self):
        r = run_cli("build", "--from", "a", "--to", "b", "--type", "t",
                     "--priority", "critical", "--body", "")
        assert "X-IGNITE-Priority: critical" in r.stdout

    def test_optional_headers(self):
        r = run_cli("build", "--from", "a", "--to", "b", "--type", "t",
                     "--thread-id", "th-1", "--in-reply-to", "<msg@x>",
                     "--repo", "org/repo", "--issue", "42", "--body", "")
        assert "X-IGNITE-Thread-ID: th-1" in r.stdout
        assert "In-Reply-To: <msg@x>" in r.stdout
        assert "X-IGNITE-Repository: org/repo" in r.stdout
        assert "X-IGNITE-Issue: 42" in r.stdout

    def test_body_file(self, tmp_path):
        body_file = tmp_path / "body.yaml"
        body_file.write_text("key: value\n", encoding="utf-8")
        r = run_cli("build", "--from", "a", "--to", "b", "--type", "t",
                     "--body-file", str(body_file))
        assert "key: value" in r.stdout

    def test_output_file(self, tmp_path):
        out = tmp_path / "msg.mime"
        r = run_cli("build", "--from", "a", "--to", "b", "--type", "t",
                     "--body", "test", "-o", str(out))
        assert r.returncode == 0
        assert out.read_text(encoding="utf-8").endswith("test")

    def test_multiple_to(self):
        r = run_cli("build", "--from", "a", "--to", "b", "c", "--type", "t", "--body", "")
        assert "To: b, c" in r.stdout

    def test_japanese_body(self):
        r = run_cli("build", "--from", "a", "--to", "b", "--type", "t",
                     "--body", "メッセージ: テスト")
        assert r.returncode == 0
        assert "メッセージ: テスト" in r.stdout

    def test_status_header(self):
        r = run_cli("build", "--from", "a", "--to", "b", "--type", "t",
                     "--status", "queued", "--body", "")
        assert "X-IGNITE-Status: queued" in r.stdout


# === parse ===

class TestParse:
    def _build_and_parse(self, *extra_args: str, body: str = "test") -> dict:
        with tempfile.NamedTemporaryFile(mode="w", suffix=".mime", delete=False) as f:
            r = run_cli("build", "--from", "sender", "--to", "receiver",
                        "--type", "msg_type", *extra_args, "--body", body,
                        "-o", f.name)
            assert r.returncode == 0
            r2 = run_cli("parse", f.name)
            assert r2.returncode == 0
            return json.loads(r2.stdout)

    def test_basic_parse(self):
        d = self._build_and_parse()
        assert d["from"] == "sender"
        assert d["to"] == ["receiver"]
        assert d["type"] == "msg_type"
        assert d["body"] == "test"

    def test_cc_parse(self):
        d = self._build_and_parse("--cc", "x", "y")
        assert d["cc"] == ["x", "y"]

    def test_empty_cc(self):
        d = self._build_and_parse()
        assert d["cc"] == []

    def test_priority_parse(self):
        d = self._build_and_parse("--priority", "high")
        assert d["priority"] == "high"


# === extract-body ===

class TestExtractBody:
    def test_extract(self, tmp_path):
        out = tmp_path / "msg.mime"
        run_cli("build", "--from", "a", "--to", "b", "--type", "t",
                "--body", "payload_here", "-o", str(out))
        r = run_cli("extract-body", str(out))
        assert r.stdout.strip() == "payload_here"


# === update-status ===

class TestUpdateStatus:
    def test_add_status(self, tmp_path):
        out = tmp_path / "msg.mime"
        run_cli("build", "--from", "a", "--to", "b", "--type", "t",
                "--body", "data", "-o", str(out))
        r = run_cli("update-status", str(out), "delivered",
                     "--processed-at", "2026-02-10T12:00:00+09:00")
        assert r.returncode == 0
        r2 = run_cli("parse", str(out))
        d = json.loads(r2.stdout)
        assert d["status"] == "delivered"

    def test_replace_status(self, tmp_path):
        out = tmp_path / "msg.mime"
        run_cli("build", "--from", "a", "--to", "b", "--type", "t",
                "--status", "queued", "--body", "data", "-o", str(out))
        run_cli("update-status", str(out), "processing")
        r = run_cli("parse", str(out))
        d = json.loads(r.stdout)
        assert d["status"] == "processing"

    def test_body_preserved_after_update(self, tmp_path):
        out = tmp_path / "msg.mime"
        run_cli("build", "--from", "a", "--to", "b", "--type", "t",
                "--body", "original_body", "-o", str(out))
        run_cli("update-status", str(out), "delivered")
        r = run_cli("extract-body", str(out))
        assert "original_body" in r.stdout
