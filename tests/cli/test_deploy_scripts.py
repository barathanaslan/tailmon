"""Smoke checks for the deploy/ scripts.

We do not execute any of them in this phase. We only:

* Run ``bash -n`` (parser / syntax check) on every ``.sh``.
* If ``shellcheck`` is installed, run it as well.
* Sanity-check that the launchd plist parses as XML and contains the
  expected ``Label`` key.
"""

from __future__ import annotations

import shutil
import subprocess
import xml.etree.ElementTree as ET
from pathlib import Path

import pytest

DEPLOY_DIR = Path(__file__).resolve().parents[2] / "deploy"
SHELL_SCRIPTS = sorted(DEPLOY_DIR.glob("*.sh"))


def test_deploy_dir_exists() -> None:
    assert DEPLOY_DIR.is_dir(), f"{DEPLOY_DIR} should exist"


@pytest.mark.parametrize("script", SHELL_SCRIPTS, ids=lambda p: p.name)
def test_bash_n_parses_cleanly(script: Path) -> None:
    result = subprocess.run(
        ["bash", "-n", str(script)],
        capture_output=True,
        text=True,
        check=False,
    )
    assert result.returncode == 0, f"bash -n {script} failed: {result.stderr}"


@pytest.mark.skipif(shutil.which("shellcheck") is None, reason="shellcheck not installed")
@pytest.mark.parametrize("script", SHELL_SCRIPTS, ids=lambda p: p.name)
def test_shellcheck_clean(script: Path) -> None:
    result = subprocess.run(
        ["shellcheck", "-S", "warning", str(script)],
        capture_output=True,
        text=True,
        check=False,
    )
    assert result.returncode == 0, f"shellcheck {script}:\n{result.stdout}"


def test_launchd_plist_is_valid_xml() -> None:
    plist = DEPLOY_DIR / "com.bosphorify.studiod.plist"
    assert plist.exists()
    tree = ET.parse(plist)
    root = tree.getroot()
    assert root.tag == "plist"
    text = plist.read_text()
    assert "com.bosphorify.studiod" in text
    assert "__TAILSCALE_IP__" in text  # placeholder for install-server.sh
    assert "RunAtLoad" in text
    assert "KeepAlive" in text
