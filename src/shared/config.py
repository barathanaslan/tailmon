"""Shared configuration: default ports, paths, environment variable names."""

from __future__ import annotations

from pathlib import Path

# Environment variable names (single source of truth)
ENV_TOKEN_FILE = "STUDIOD_TOKEN_FILE"
ENV_BIND_HOST = "STUDIOD_BIND_HOST"
ENV_BIND_PORT = "STUDIOD_BIND_PORT"
ENV_DEV_MODE = "STUDIOD_DEV_MODE"

# Defaults
DEFAULT_BIND_HOST = "127.0.0.1"
DEFAULT_BIND_PORT = 8765

# Token file locations
PROD_TOKEN_FILE = Path("/etc/studiod/token")
DEV_TOKEN_FILENAME = ".studiod-dev-token"  # resolved relative to cwd / repo root

# Versioning
VERSION = "0.1.0"
