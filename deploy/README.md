# Deploy

Phase 2b walkthrough for getting `studiod` running on the Mac Studio and the `studio` CLI working on the MacBook.

These scripts are reviewed and ready to run, but **Phase 2a does not execute them**. The architect (you) runs them interactively with the human in the loop during Phase 2b.

## Files

| File | Where it runs | What it does |
|---|---|---|
| `com.bosphorify.studiod.plist` | (template) | launchd system daemon plist with `__TAILSCALE_IP__` placeholder |
| `install-server.sh` | Mac Studio (root) | Builds `/opt/studiod/venv`, generates `/etc/studiod/token`, drops the plist into `/Library/LaunchDaemons/`, bootstraps the daemon, verifies `/health` |
| `uninstall-server.sh` | Mac Studio (root) | Boots the daemon out, removes `/opt/studiod/`. Preserves the token unless `--purge-token`. |
| `install-client.sh` | MacBook (user) | Writes `~/.config/studio-cli/{config.toml,token}`, runs `uv pip install .[client]`, verifies `studio version`. Does NOT touch `~/.zshrc`. |
| `uninstall-client.sh` | MacBook (user) | `uv pip uninstall studio-cli` and optionally removes the config dir. |

## Phase 2b walkthrough (what the human + architect do together)

1. **Sanity check the MacBook side first**. From the repo root on the MacBook:

   ```
   uv sync --extra dev
   uv run pytest
   uv run studio --help
   ```

   Confirm 118+ tests pass and `studio --help` lists every subcommand.

2. **Push the repo to the Mac Studio**. The user already has an `~/studio-cli` checkout from previous work; if not:

   ```
   ssh macstudio "git clone https://github.com/<user>/studio-cli.git ~/studio-cli"
   ```

   Or `rsync -avz --exclude .venv ./ macstudio:~/studio-cli/`.

3. **Sanity check Tailscale on the Mac Studio**:

   ```
   ssh macstudio tailscale ip -4
   ```

   Should return the same `100.80.21.79` (or whatever the current CGNAT IP is). If empty, fix Tailscale before continuing.

4. **Run the server install on the Mac Studio**:

   ```
   ssh macstudio
   cd ~/studio-cli
   sudo bash deploy/install-server.sh
   ```

   The script:
   - asserts root + Darwin
   - finds the Tailscale IPv4
   - builds `/opt/studiod/venv` with `[collector]`
   - generates `/etc/studiod/token` (unless one already exists)
   - renders the plist with the IP substituted
   - `launchctl bootstrap`s it
   - hits `/health` to verify

   On success it prints the bearer-token path and a "copy this to the MacBook" reminder.

5. **Verify on the Mac Studio**:

   ```
   sudo launchctl print system/com.bosphorify.studiod
   curl -sf http://$(tailscale ip -4):8765/health
   sudo cat /var/log/studiod.err.log
   ```

6. **Copy the token to the MacBook** (do NOT pipe through bash history):

   ```
   ssh macstudio sudo cat /etc/studiod/token > /tmp/studiod-token
   install -m 600 /tmp/studiod-token ~/.config/studio-cli/token
   shred -u /tmp/studiod-token  # or rm -P
   ```

   Or paste interactively into `install-client.sh` in step 7.

7. **Run the client install on the MacBook**:

   ```
   bash deploy/install-client.sh
   ```

   It will prompt for the collector URL (default `http://100.80.21.79:8765`), the SSH host alias (default `macstudio`), and the bearer token. It writes `~/.config/studio-cli/config.toml` and `~/.config/studio-cli/token`, then runs `uv pip install .[client]` and verifies `studio version` + `studio status`.

8. **Remove the legacy `studio()` zsh function manually**. Open `~/.zshrc:95-140` and delete the function block. The Python CLI now provides `studio` as a console script. Reload your shell.

9. **Smoke test the user-facing surface**:

   ```
   studio --help
   studio version
   studio status
   studio who
   studio ports
   studio ps --sort cpu --limit 10
   studio sessions
   studio                  # opens the fzf picker
   studio main             # direct attach to the 'main' tmux session
   ```

   The last two should preserve the muscle memory exactly.

10. **Tail logs for ~5 minutes** to make sure nothing is crashing:

    ```
    ssh macstudio sudo tail -f /var/log/studiod.err.log
    ```

## CLI dispatch behavior

For the curious / for review:

- `studio` (no args) -> `studio_cli.commands.tmux.run_tmux_command(name=None)` -> fetches the tmux session list over HTTP, runs `fzf` locally, then `os.execvp`'s into `ssh -t macstudio tmux ...`.
- `studio main` -> `run_tmux_command(name="main")` -> direct `os.execvp` into `ssh`.
- `studio status` (or any reserved subcommand name) -> the corresponding click command. Reserved names live in `RESERVED_NAMES` in `src/studio_cli/cli.py`.
- `studio tmux <name>` -> explicit form, useful if you ever happen to have a tmux session literally called `status`.

The dispatch is implemented by a custom `click.Group` subclass (`StudioGroup`) whose `resolve_command` method falls back to the `tmux` command for any non-flag, non-reserved positional argument.

## Hard constraints

- **No `shell=True` anywhere.** `subprocess.run(["fzf", ...])` and `os.execvp("ssh", [...])` always take an argv list.
- **Tmux session names** are validated against `^[A-Za-z0-9_.-]+$` before they reach `os.execvp`. A name like `$(rm -rf /)` is rejected with `click.UsageError` before any subprocess is spawned.
- **Token file** is required to be `0600`; the client refuses to read it if the mode is wider.
- **Collector dependency surface** stays minimal -- only `fastapi`, `uvicorn`, `psutil` end up on the Mac Studio. `click`, `rich`, `httpx` are client-only.
