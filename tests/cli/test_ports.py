"""Tests for ``studio ports``."""

from __future__ import annotations

from studio_cli.cli import cli


def test_ports_happy_path(runner, patched_client) -> None:
    result = runner.invoke(cli, ["ports"])
    assert result.exit_code == 0, result.output
    assert "Listening ports" in result.output
    assert "sshd" in result.output
    assert "studiod" in result.output
    # Sorted ascending: 22 should appear before 8765 in the output stream.
    idx_22 = result.output.find("22")
    idx_8765 = result.output.find("8765")
    assert idx_22 < idx_8765
