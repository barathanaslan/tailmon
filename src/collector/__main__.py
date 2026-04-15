"""Entry point: `python -m collector` or the installed `studiod` console script."""

from __future__ import annotations

import logging
import sys

import uvicorn

from collector.app import create_app
from collector.config import ConfigError, load_config
from shared.auth import ensure_dev_token, read_token


def main() -> None:
    logging.basicConfig(
        level=logging.INFO,
        format="%(asctime)s %(levelname)s %(name)s: %(message)s",
    )
    try:
        cfg = load_config()
    except ConfigError as exc:
        print(f"[studiod] invalid configuration: {exc}", file=sys.stderr)
        sys.exit(2)

    if cfg.dev_mode:
        token = ensure_dev_token(cfg.token_path)
    else:
        try:
            token = read_token(cfg.token_path)
        except Exception as exc:  # pragma: no cover - prod path
            print(f"[studiod] failed to load token: {exc}", file=sys.stderr)
            sys.exit(2)

    app = create_app(token=token)

    print(
        f"[studiod] serving on http://{cfg.bind_host}:{cfg.bind_port} "
        f"(dev_mode={cfg.dev_mode})"
    )
    uvicorn.run(
        app,
        host=cfg.bind_host,
        port=cfg.bind_port,
        log_level="info",
    )


if __name__ == "__main__":
    main()
