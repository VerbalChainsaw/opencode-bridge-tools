# OpenCode Bridge Tools

PowerShell module that manages the lifecycle of the [OpenCode](https://opencode.ai) CLI wrapper and its upstream Hermes Nous AI gateway.

When you type `opencode`, this wrapper:
1. Auto-starts the Hermes gateway on `127.0.0.1:8642` (if not already running)
2. Runs the real `opencode` CLI
3. Tears down the gateway when your session ends (unless other opencode processes remain)

Quick commands like `opencode --version` and `opencode models` skip the gateway entirely — no wasted startup time.

## Install

```powershell
# 1. Clone the repo
git clone https://github.com/VerbalChainsaw/opencode-bridge-tools.git $env:USERPROFILE\Development\opencode-bridge-tools

# 2. Edit your PowerShell profile
notepad $PROFILE

# Add this line:
. $env:USERPROFILE\Development\opencode-bridge-tools\profile-loader.ps1

# 3. Reload your profile or restart your terminal
. $PROFILE
```

**Requirements:** PowerShell 7.0+, OpenCode CLI installed.

## Configuration

All paths and timeouts are env-configurable:

| Env var | Default | Description |
|---------|---------|-------------|
| `OPENCODE_BRIDGE_CMD` | `C:\hermes\gateway-service\Hermes_Gateway.cmd` | Path to gateway launch script |
| `OPENCODE_BRIDGE_WORKDIR` | `C:\hermes` | Working directory for the gateway |
| `OPENCODE_BRIDGE_PORT` | `8642` | Gateway listen port |
| `OPENCODE_BRIDGE_HOST` | `127.0.0.1` | Gateway bind address |
| `OPENCODE_BRIDGE_STALE_LOCK_MIN` | `5` | Minutes before a stale lock is reclaimed |
| `OPENCODE_BRIDGE_START_TIMEOUT` | `25` | Seconds to wait per start attempt |
| `OPENCODE_BRIDGE_START_RETRIES` | `3` | Max launch retries before giving up |

## Commands

| Function | Description |
|----------|-------------|
| `Start-OpenCodeBridge` | Ensure the upstream gateway is listening |
| `Stop-OpenCodeBridge` | Tear down the gateway (only if no opencode remains) |
| `Get-OpenCodePath` | Resolve the opencode CLI executable path |
| `Get-OpenCodeBridgeStatus` | Runtime state: PID, uptime, image, cmdline, lock |
| `Test-OpenCodeConfig` | Validate `opencode.jsonc` + `oh-my-opencode-slim.json` |

### Example

```powershell
Import-Module .\OpenCodeBridge.psd1

# Check if the bridge is up
Get-OpenCodeBridgeStatus

# Output:
# BridgeReady : True
# Port        : 8642
# ProcessId   : 21772
# ImagePath   : C:\...\pythonw.exe
# CmdLine     : pythonw.exe -m hermes_cli.main gateway run
# Uptime      : 00:12:34
# LockHeld    : False
# BridgeCmd   : C:\hermes\gateway-service\Hermes_Gateway.cmd

# Validate your config
Test-OpenCodeConfig  # returns $true or $false with warning diagnostics
```

## Bridge-only mode

The wrapper skips the gateway entirely for subcommands that never call AI models:

`completion`, `mcp`, `models`, `providers`, `auth`, `agent`, `upgrade`, `uninstall`, `debug`, `stats`, `export`, `import`, `session`, `plugin`, `plug`, `db`, `acp`, `github`

Shortcut flags `--version`, `-v`, `--help`, `-h` also skip the bridge.

## Testing

```powershell
# Lightweight smoke tests (no dependencies)
pwsh -NoProfile -File .\run-tests.ps1

# Pester test suite (if Pester is installed)
Invoke-Pester .\tests\OpenCodeBridge.Tests.ps1
```

## How it works

```
User types 'opencode'
        │
        ▼
profile-loader.ps1 ── global:opencode() wrapper
        │
        ├─ skip-bridge? ── yes ──► & opencode.exe --version
        │                         (no gateway needed)
        │
        └─ no ──► Test-OpenCodeConfig (cached 60s)
                  │
                  ├─ config OK? ──► Start-OpenCodeBridge
                  │                  ├─ port free? ── launch gateway
                  │                  ├─ gateway up? ── fast path, skip
                  │                  └─ intruder?  ── bail with warning
                  │
                  └─ & opencode.exe (interactive session)
                     │
                     └─ Stop-OpenCodeBridge (on session end)
                        └─ kill gateway only if no other opencode remains
```

## Safety

- **Never kills on port match alone** — gateway PID is verified by process image AND command line.
- **Intruder detection** — refuses to start if a non-Hermes process holds port 8642.
- **TOCTOU lock** — atomic file lock prevents concurrent gateway launches across terminals.
- **Stale lock recovery** — crash-leftover locks older than 5 minutes are automatically removed.
