# OpenCode Bridge Tools

PowerShell module that manages the lifecycle of the [OpenCode](https://opencode.ai) CLI and its upstream Hermes Nous AI gateway.

When you type `opencode`, this wrapper:
1. Validates your opencode config for bridge compatibility
2. Auto-starts the Hermes gateway on `127.0.0.1:8642` (if not running)
3. Launches a **background health worker** that monitors the gateway and restarts it on crash
4. Runs the real `opencode` CLI
5. Tears down the gateway when your session ends (unless other opencode processes remain)
6. Optionally auto-stops the gateway after idle timeout

Quick commands like `opencode --version` and `opencode models` skip the gateway entirely — sub-400ms, no overhead.

## Quick Install

```powershell
# Clone and run the installer (adds one line to $PROFILE)
git clone https://github.com/VerbalChainsaw/opencode-bridge-tools.git "$env:USERPROFILE\Development\opencode-bridge-tools"
pwsh -NoProfile -File "$env:USERPROFILE\Development\opencode-bridge-tools\install.ps1"
```

Or manually — add to your `$PROFILE`:

```powershell
. $env:USERPROFILE\Development\opencode-bridge-tools\profile-loader.ps1
```

**Requirements:** PowerShell 7.0+, OpenCode CLI installed.

## Quick Uninstall

```powershell
# Stop the bridge and health worker
Disable-OpenCodeBridge

# Remove the line from $PROFILE (starts with '. ')
notepad $PROFILE
```

## Commands

| Function | Description |
|----------|-------------|
| `Start-OpenCodeBridge` | Ensure the upstream gateway is listening (retries + liveness checks) |
| `Stop-OpenCodeBridge` | Tear down the gateway (only if no other opencode remains, supports `-WhatIf`) |
| `Get-OpenCodePath` | Resolve the opencode CLI executable (prefers paths without spaces) |
| `Get-OpenCodeBridgeStatus` | Full runtime state: PID, uptime, image, health, idle time, lock |
| `Test-OpenCodeConfig` | Validate `opencode.jsonc` + `oh-my-opencode-slim.json` |
| `Test-OpenCodeBridgeHealth` | HTTP liveness check against the gateway's `/v1/models` endpoint |
| `Test-BridgeConnectivity` | TCP reachability check (pre-launch fast-fail) |
| `Disable-OpenCodeBridge` | Stop gateway + health worker (graceful shutdown, supports `-WhatIf`) |

### Example Output

```powershell
Get-OpenCodeBridgeStatus
```

```
BridgeReady  : True
Port         : 8642
ProcessId    : 21300
ImagePath    : C:\...\pythonw.exe
CmdLine      : pythonw.exe -m hermes_cli.main gateway run
Uptime       : 00:42:17
HealthOk     : True        # HTTP endpoint responds
HealthWorker : True        # Background monitor is running
IdleMinutes  : 12          # Minutes since last opencode activity
LockHeld     : False
BridgeCmd    : C:\hermes\gateway-service\Hermes_Gateway.cmd
```

## Health Monitoring

When the gateway starts, a background PowerShell job monitors it:

- **Polls every 30s** (configurable via `OPENCODE_BRIDGE_HEALTH_POLL_SEC`)
- **HTTP liveness check** against `/v1/models` — any response (even 401) counts as alive
- **Auto-restart** — if the gateway crashes, the worker relaunches it
- **Idle timeout** — auto-stops the gateway after N minutes of no opencode activity (configurable via `OPENCODE_BRIDGE_IDLE_TIMEOUT_MIN`, default 0 = disabled)
- **Log file** — health events written to `$env:LOCALAPPDATA\opencode-bridge.log`

## Configuration

All paths and timeouts are env-configurable:

| Env var | Default | Range | Description |
|---------|---------|-------|-------------|
| `OPENCODE_BRIDGE_CMD` | `C:\hermes\gateway-service\Hermes_Gateway.cmd` | — | Gateway launch script |
| `OPENCODE_BRIDGE_WORKDIR` | `C:\hermes` | — | Working directory |
| `OPENCODE_BRIDGE_PORT` | `8642` | 1–65535 | Gateway listen port |
| `OPENCODE_BRIDGE_HOST` | `127.0.0.1` | — | Gateway bind address |
| `OPENCODE_BRIDGE_BINARY` | venv `pythonw.exe` | — | Gateway binary for identity check |
| `OPENCODE_BRIDGE_STALE_LOCK_MIN` | `5` | 1–120 | Lock staleness threshold (min) |
| `OPENCODE_BRIDGE_START_TIMEOUT` | `25` | 5–300 | Seconds per start attempt |
| `OPENCODE_BRIDGE_START_RETRIES` | `3` | 1–10 | Max launch retries |
| `OPENCODE_BRIDGE_HEALTH_POLL_SEC` | `30` | 5–300 | Health check interval |
| `OPENCODE_BRIDGE_IDLE_TIMEOUT_MIN` | `0` (off) | 0–1440 | Auto-stop after idle (min) |

### Enabling idle timeout

```powershell
# Auto-stop the gateway after 30 minutes of no activity
$env:OPENCODE_BRIDGE_IDLE_TIMEOUT_MIN = 30
```

## Bridge-only mode

The wrapper skips the gateway for subcommands that never call AI models:

`completion`, `mcp`, `models`, `providers`, `auth`, `agent`, `upgrade`, `uninstall`, `debug`, `stats`, `export`, `import`, `session`, `plugin`, `plug`, `db`, `acp`, `github`

Shortcut flags `--version`, `-v`, `--help`, `-h` also skip the bridge.

## Architecture

```
User types 'opencode'
        │
        ▼
profile-loader.ps1 ── global:opencode() wrapper
        │
        ├─ skip-bridge? ── yes ──► & opencode.exe --version (no gateway)
        │
        └─ no ──► Test-BridgeConnectivity (TCP fast-fail)
                  │
                  ├─ Test-OpenCodeConfig (cached 60s)
                  │
                  ├─ Start-OpenCodeBridge
                  │    ├─ port free? ── launch gateway + retries
                  │    ├─ gateway up? ── fast path + Start-HealthWorker
                  │    └─ intruder?  ── bail with warning
                  │
                  ├─ & opencode.exe (interactive session)
                  │
                  └─ Stop-OpenCodeBridge (on session end)
                       └─ kill gateway only if no other opencode remains

Background health worker (30s poll loop):
        │
        ├─ HTTP ping /v1/models ── fail? ──► restart gateway
        ├─ idle timeout check ── expired? ──► stop gateway
        └─ log to $LOCALAPPDATA\opencode-bridge.log
```

## Safety

- **HTTP health verification** — gateway liveness confirmed via real API call, not just port check.
- **Never kills on port match alone** — gateway PID verified by process path AND command line.
- **Intruder detection** — refuses to start if a non-Hermes process holds the port. Re-checked at every retry.
- **TOCTOU lock** — atomic file lock (CreateNew, FileShare.None) prevents concurrent launches across terminals.
- **Stale lock recovery** — crash-leftover locks older than 5 minutes auto-removed.
- **Input validation** — all env-configurable ints clamped to safe ranges (port, retries, timeouts).
- **Stop double-check** — polls opencode processes twice before killing the gateway (TOCTOU guard).
- **Config size limit** — rejects configs > 1 MB before parsing.

## Testing

```powershell
# Lightweight smoke tests (no dependencies, 27 tests)
pwsh -NoProfile -File .\run-tests.ps1

# Pester test suite (if Pester is installed)
Invoke-Pester .\tests\OpenCodeBridge.Tests.ps1
```

## License

MIT
