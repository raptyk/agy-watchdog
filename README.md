# agy-watchdog

PowerShell watchdog that keeps an Antigravity CLI (`agy`) session working through its saved plan, nudging it to continue whenever it stops and resuming automatically once the quota resets.

> [!IMPORTANT]
> **The watchdog replaces the interactive `agy` window, it does not watch it.**
> While it runs, `agy` works headless (`agy --print`): you don't see the `agy` TUI and you can't type to the agent.
> The console shows only the watchdog status; full agent responses go to the log file.

## Quick start

1. Start `agy` as usual and give it the task, the guidelines and the plan:
   ```powershell
   agy --dangerously-skip-permissions
   ```
2. Exit `agy` (`/exit`).
3. In the same terminal, start the watchdog. It continues the same conversation with its full context:
   ```powershell
   pwsh -NoProfile -File .\agy-watchdog.ps1 -WorkDir "C:\Projects\my-app" -PlanFile "PLAN.md"
   ```
4. To talk to the agent again, stop the watchdog (`Ctrl+C`) and resume the conversation interactively:
   ```powershell
   agy -c --dangerously-skip-permissions
   ```

> [!NOTE]
> **Requires PowerShell 7.2+** (`pwsh`). It does not run in Windows PowerShell 5.1.
> Never run the watchdog and an interactive `agy` on the same conversation at the same time: two clients on one conversation conflict.

## Why

Long autonomous runs in `agy` tend to stall:

- the agent finishes a step and waits for confirmation instead of moving on,
- the 5-hour quota runs out and the session stops at the quota banner,
- `agy` itself never resumes after the quota resets.

`agy-watchdog` resumes the same conversation in print mode (`agy --print`) round after round, so the agent keeps its full context, guidelines and plan.

## How it works

Each round sends a "continue according to the plan" prompt to the conversation, then reacts to the result:

| Situation | What the watchdog does |
|---|---|
| Turn ended without the done marker | Sends the continue prompt again |
| Quota exhausted (`RESOURCE_EXHAUSTED`, `quota`, `429`) | Waits `-QuotaWaitMinutes`, then retries (does not count as a round) |
| Other `agy` error | Waits `-ErrorWaitMinutes`; stops after `-MaxConsecutiveErrors` in a row |
| Round exceeds `-RoundTimeoutMinutes` | Stops `agy` and resumes it in the next round |
| Agent prints `ALL_PLAN_STEPS_DONE` | Stops. If the plan still has unchecked `- [ ]` items, pushes back once first |
| Agent prints `NEED_HUMAN: <reason>` | Stops and shows the reason |
| No change in the git working tree for `-MaxStalledRounds` rounds | Stops (the agent is looping without progress) |
| Authentication error | Stops: run `agy` interactively once to sign in |

When it stops, it beeps and prints the conversation ID and the log path. Every round and every `agy` response go to the log (`%TEMP%\agy-watchdog-<timestamp>.log` by default).

## Requirements

- Windows 10 / 11, PowerShell 7.2+
- Antigravity CLI: `agy` on `PATH` or in `%LOCALAPPDATA%\agy\bin`, signed in
- A plan file in the project (checkboxes `- [ ]` / `- [x]` recommended)
- Git (optional): enables the no-progress detection

## Usage

```powershell
pwsh -NoProfile -File .\agy-watchdog.ps1 `
    -WorkDir  "C:\Projects\my-app" `
    -PlanFile "PLAN.md" `
    -Conversation "2f8464da-fa67-4d50-8313-337cac26be12"
```

Without `-Conversation`, the most recent `agy` conversation is continued (`--continue`). Passing the ID is safer. Recent conversation IDs and their workspaces are in `~/.gemini/antigravity-cli/history.jsonl`.

### Parameters

| Parameter | Default | Description |
|---|---|---|
| `-WorkDir` | (required) | Project directory `agy` works in |
| `-PlanFile` | (required) | Plan file path, relative to `-WorkDir` |
| `-Conversation` | most recent | `agy` conversation ID to resume |
| `-Model` | `agy` default | Model for the resumed session |
| `-MaxRounds` | `100` | Maximum number of rounds |
| `-RoundTimeoutMinutes` | `90` | Hard time limit of a single round |
| `-QuotaWaitMinutes` | `30` | Wait before retrying after the quota runs out |
| `-ErrorWaitMinutes` | `5` | Wait before retrying after another error |
| `-MaxConsecutiveErrors` | `6` | Errors in a row before giving up |
| `-MaxStalledRounds` | `3` | Rounds without changes before giving up |
| `-LogFile` | `%TEMP%\agy-watchdog-*.log` | Log file path |

## Notes

- Rounds run with `--dangerously-skip-permissions`, because nobody can answer permission prompts in print mode. Run it only in a project you trust, ideally a git repository with a clean starting state.
- Progress is visible in the watchdog console and in the log, not in the interactive `agy` TUI.
- Quota detection relies on the `agy` output and its log files in `~/.gemini/antigravity-cli/log`; the exact reset time is not parsed, so the watchdog simply retries every `-QuotaWaitMinutes`.
- To spread work over several Google accounts, see [agy-switch-accounts](https://github.com/raptyk/agy-switch-accounts).
