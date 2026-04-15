"""studio_cli: client-side CLI for the studiod collector daemon.

Replaces the user's hand-written `studio` zsh function with a Python click
application that talks to the collector over HTTP (across Tailscale) and
also preserves the existing tmux-picker / direct-attach UX.
"""

from __future__ import annotations

__version__ = "0.1.0"
