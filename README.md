# agy-watchdog

PowerShell watchdog that keeps an Antigravity CLI (`agy`) session working through its saved plan, nudging it to continue whenever it stops and resuming automatically once the quota resets.

**Nothing to install:** no terminal multiplexer (tmux, Zellij, herdr), no Node.js, no `unsnooze`. It talks to the `agy` console window directly through the Windows console API (`kernel32.dll`), so it works in a plain PowerShell window.

---

# 🚀 Quick start

> [!TIP]
> ## ⭐ Attach mode (recommended)
> **Keep working in `agy` as usual.** The watchdog watches your `agy` window in the background: you still see the `agy` TUI and can type to the agent at any time.
>
> **① Terminal 1** – start `agy` the way you always do and give it the task, the guidelines and the plan:
>
> ```powershell
> cd C:\Projects\my-app
> agy --dangerously-skip-permissions
> ```
>
> **② Terminal 2** – start the watchdog in the same folder:
>
> ```powershell
> cd C:\Projects\my-app
> pwsh -NoProfile -File C:\Tools\agy-watchdog\agy-watchdog.ps1 -Attach -PlanFile PLAN.md
> ```
>
> **That's it.** When `agy` has been idle for 10 minutes, or when the quota banner is shown and the reset time has passed, the watchdog types a continue prompt into the `agy` window for you. Press `Ctrl+C` in terminal 2 to stop watching.

> [!NOTE]
> **Requires PowerShell 7.2+** (`pwsh`). It does not run in Windows PowerShell 5.1.

<details>
<summary><b>Headless mode (fallback): the watchdog runs <code>agy</code> itself</b> – click to expand</summary>

<br>

Use it when attach mode doesn't fit (for example when typing into the `agy` window has no effect after an `agy` update). The watchdog resumes the conversation in print mode (`agy --print`), round after round. **You don't see the `agy` TUI and can't type to the agent** while it runs; full agent responses go to the log.

1. Start `agy --dangerously-skip-permissions`, give it the task and the plan, then exit it (`/exit`).
2. In the same terminal:
   ```powershell
   pwsh -NoProfile -File C:\Tools\agy-watchdog\agy-watchdog.ps1 -WorkDir C:\Projects\my-app -PlanFile PLAN.md
   ```
3. To talk to the agent again, stop the watchdog (`Ctrl+C`) and run `agy -c --dangerously-skip-permissions`.

</details>

---

## Why

Long autonomous runs in `agy` tend to stall:

- the agent finishes a step and waits for confirmation instead of moving on,
- the 5-hour quota runs out and the session stops at the quota banner (`Individual quota reached … Resets in 2h13m5s`),
- `agy` itself never resumes after the quota resets.

Tools like `unsnooze` detect the `agy` quota banner only through a terminal multiplexer pane, and the `agy` log files don't record it. `agy-watchdog` reads the `agy` console screen itself instead.

## How attach mode works

A hidden background process attaches to the console of the running `agy` (`AttachConsole`), reads its visible screen every `-PollSeconds` (`ReadConsoleOutputCharacter`) and, when needed, types a single-line continue prompt followed by Enter (`WriteConsoleInput`). It detaches between reads, so `Ctrl+C` in the `agy` window never reaches it.

It acts only when the `agy` screen hasn't changed for a while (the agent isn't working):

| On the `agy` screen | What the watchdog does |
|---|---|
| Quota banner with `Resets in XhYmZs` | Waits until the reset time + 2 min, then types the continue prompt |
| Quota banner without a reset time | Waits `-QuotaWaitMinutes`, then types the continue prompt |
| Unchanged for `-IdleMinutes` | Types the continue prompt |
| A line `ALL_PLAN_STEPS_DONE` | Stops. If the plan still has unchecked `- [ ]` items, pushes back once first |
| A line `NEED_HUMAN: <reason>` | Stops and shows the reason |
| Typed prompt changes nothing, 3 times in a row | Stops |
| `agy` exits | Stops |

The continue prompt tells the agent to go on with the next step of the plan, keep the plan file up to date, and end with one of the two markers above when it's done or blocked. Digits are ignored when comparing screens, so clocks and timers don't count as activity.

If more than one interactive `agy` is running, choose one with `-AgyPid <pid>` (the watchdog lists them).

## How headless mode works

Each round sends a continue prompt to the conversation with `agy --print`, then reacts to the result:

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

Without `-Conversation`, the most recent `agy` conversation is continued (`--continue`). Passing the ID is safer; recent conversation IDs and their workspaces are in `~/.gemini/antigravity-cli/history.jsonl`. Never run headless mode and an interactive `agy` on the same conversation at the same time.

## Requirements

- Windows 10 / 11, PowerShell 7.2+
- Antigravity CLI: `agy` on `PATH` or in `%LOCALAPPDATA%\agy\bin`, signed in
- A plan file in the project (checkboxes `- [ ]` / `- [x]` recommended)
- Git (optional, headless mode): enables the no-progress detection

## Parameters

| Parameter | Mode | Default | Description |
|---|---|---|---|
| `-PlanFile` | both | (required) | Plan file path, relative to `-WorkDir` |
| `-WorkDir` | both | current directory | Project directory `agy` works in |
| `-Attach` | attach | off | Watch an interactive `agy` window instead of running `agy` headless |
| `-AgyPid` | attach | the only interactive `agy` | Process ID of the `agy` to watch |
| `-IdleMinutes` | attach | `10` | Minutes of an unchanged screen before a continue prompt is typed |
| `-PollSeconds` | attach | `30` | How often the `agy` screen is read |
| `-MaxNudges` | attach | `200` | Maximum number of typed continue prompts |
| `-QuotaWaitMinutes` | both | `30` | Wait after the quota runs out when the reset time is unknown |
| `-Conversation` | headless | most recent | `agy` conversation ID to resume |
| `-Model` | headless | `agy` default | Model for the resumed session |
| `-MaxRounds` | headless | `100` | Maximum number of rounds |
| `-RoundTimeoutMinutes` | headless | `90` | Hard time limit of a single round |
| `-ErrorWaitMinutes` | headless | `5` | Wait before retrying after an error |
| `-MaxConsecutiveErrors` | headless | `6` | Errors in a row before giving up |
| `-MaxStalledRounds` | headless | `3` | Rounds without changes before giving up |
| `-LogFile` | both | `%TEMP%\agy-watchdog-*.log` | Log file path |

When the watchdog stops, it beeps and prints the reason and the log path.

## Notes

- Attach mode types into the `agy` input box. If you are in the middle of typing there when the watchdog acts, its prompt is appended to your text; with the default `-IdleMinutes 10` this is unlikely.
- Headless rounds run with `--dangerously-skip-permissions`, because nobody can answer permission prompts in print mode. Run it only in a project you trust, ideally a git repository with a clean starting state.
- To spread work over several Google accounts, see [agy-switch-accounts](https://github.com/raptyk/agy-switch-accounts).
