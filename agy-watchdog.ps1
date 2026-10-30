#Requires -Version 7.2
<#
.SYNOPSIS
    Keeps an Antigravity CLI (agy) session working through its saved plan until it is done.

.DESCRIPTION
    Attach mode (-Attach, recommended): you start and use agy as usual. A hidden background process attaches to
    the console of that agy, reads its screen every few seconds and types a continue prompt into it:
    - when agy has been idle (screen unchanged) for IdleMinutes;
    - when the quota banner ("... quota ... Resets in XhYmZs") is shown, once the reset time has passed.
    It stops when agy prints the done marker, asks for a human (NEED_HUMAN), exits, or typing has no effect.
    Nothing has to be installed: it uses the Windows console API (kernel32), no terminal multiplexer.

    Headless mode (default): resumes the conversation itself in print mode (agy --print), round after round:
    - every time agy ends a turn without the done marker, it is told to continue with the next plan step;
    - when the quota is exhausted, waits and retries (the 5h window resets on its own);
    - stops when agy reports the done marker, asks for a human (NEED_HUMAN), hits an auth error,
      makes no changes to the working tree for several rounds in a row, or reaches MaxRounds.
    Close the interactive agy session for this project before starting (two clients on one conversation conflict).

.EXAMPLE
    pwsh -NoProfile -File agy-watchdog.ps1 -Attach

.EXAMPLE
    pwsh -NoProfile -File agy-watchdog.ps1 -Attach -WorkDir C:\Projekty\my-app -PlanFile PLAN.md

.EXAMPLE
    pwsh -NoProfile -File agy-watchdog.ps1 -WorkDir C:\Projekty\my-app -PlanFile PLAN.md
#>
[CmdletBinding()]
param(
    # Project directory agy works in.
    [string] $WorkDir = (Get-Location).Path,

    # Plan file path relative to WorkDir (the agent's saved work plan). Required in headless mode, optional in attach mode.
    [string] $PlanFile,

    # Attach mode: watch an interactive agy window instead of running agy headless.
    [switch] $Attach,

    # Attach mode: process ID of the agy to watch; when omitted, the only interactive agy is used.
    [int] $AgyPid,

    # Attach mode: minutes of an unchanged agy screen before a continue prompt is typed.
    [ValidateRange(1, 240)]
    [int] $IdleMinutes = 10,

    # Attach mode: how often the agy screen is read.
    [ValidateRange(5, 600)]
    [int] $PollSeconds = 30,

    # Attach mode: maximum number of continue prompts typed before the watchdog gives up.
    [ValidateRange(1, 1000)]
    [int] $MaxNudges = 200,

    # Internal: runs the hidden attach-mode worker process.
    [Parameter(DontShow)]
    [switch] $AttachWorker,

    # Headless mode: conversation ID to resume; when omitted, the most recent conversation is continued (--continue).
    [string] $Conversation,

    # Headless mode: model for the resumed session.
    [string] $Model,

    [ValidateRange(1, 500)]
    [int] $MaxRounds = 100,

    [ValidateRange(5, 240)]
    [int] $RoundTimeoutMinutes = 90,

    # Wait after the quota runs out, when the reset time is unknown.
    [ValidateRange(1, 300)]
    [int] $QuotaWaitMinutes = 30,

    [ValidateRange(1, 60)]
    [int] $ErrorWaitMinutes = 5,

    [ValidateRange(1, 20)]
    [int] $MaxConsecutiveErrors = 6,

    # Rounds in a row without any working-tree or HEAD change before the watchdog gives up.
    [ValidateRange(1, 20)]
    [int] $MaxStalledRounds = 3,

    [string] $LogFile = (Join-Path ([IO.Path]::GetTempPath()) "agy-watchdog-$(Get-Date -Format 'yyyyMMdd-HHmmss').log")
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$DoneMarker = 'ALL_PLAN_STEPS_DONE'
$HumanMarker = 'NEED_HUMAN:'

# Extra wait after the announced quota reset, so the first prompt does not hit the old window.
$QuotaResetMarginSeconds = 120

# Polls with an unchanged screen before agy is treated as idle (not working).
$IdlePollsBeforeAction = 2

# Typed prompts that leave the screen unchanged, in a row, before the watchdog gives up.
$MaxIneffectiveNudges = 3

$ContinuePrompt = @"
Continue your work according to the plan in $PlanFile and all the guidelines you were given earlier in this conversation.
- Do not stop after finishing a step and do not ask whether to continue: move straight on to the next step of the plan.
- Keep $PlanFile up to date (mark finished steps) as you go.
- Only when EVERY step of the plan is finished and verified, end your answer with a separate line: $DoneMarker
- If you are truly blocked and need a decision from a human, end your answer with a separate line: $HumanMarker <short reason>
"@

$FalseDonePrompt = @"
You reported $DoneMarker, but $PlanFile still contains unchecked items ("- [ ]").
Re-read the plan. Finish the remaining steps, or mark them as done if they really are done, then continue as instructed before.
"@

# Attach-mode prompts are typed into the agy input box, so they are single lines (Enter submits) and spell the
# markers out instead of quoting them: the echoed prompt on screen must never look like a marker line.
$AttachPlanReference = if ($PlanFile) { "the plan in $PlanFile" } else { 'your plan' }
$AttachContinuePrompt = "Continue your work according to $AttachPlanReference and all the guidelines you were given earlier. " +
    'Do not stop after a step and do not ask whether to continue: go straight on to the next step of the plan and keep the plan up to date. ' +
    'Only when EVERY step is finished and verified, end your answer with a line containing only the words ALL, PLAN, STEPS and DONE joined with underscores. ' +
    'If you are truly blocked and need a human decision, end with a line starting with the words NEED and HUMAN joined with an underscore, then a colon and the reason.'

$AttachFalseDonePrompt = "You reported that all plan steps are done, but $PlanFile still contains unchecked items. " +
    'Re-read the plan, finish the remaining steps or mark them as done if they really are done, then continue as instructed before.'

$ConsoleBridgeSource = @'
using System;
using System.Runtime.InteropServices;
using System.Text;
using System.Threading;

public static class AgyConsoleBridge
{
    [StructLayout(LayoutKind.Sequential)]
    private struct Coord { public short X; public short Y; }

    [StructLayout(LayoutKind.Sequential)]
    private struct SmallRect { public short Left; public short Top; public short Right; public short Bottom; }

    [StructLayout(LayoutKind.Sequential)]
    private struct ScreenBufferInfo
    {
        public Coord Size;
        public Coord CursorPosition;
        public ushort Attributes;
        public SmallRect Window;
        public Coord MaximumWindowSize;
    }

    [StructLayout(LayoutKind.Explicit)]
    private struct KeyInputRecord
    {
        [FieldOffset(0)] public ushort EventType;
        [FieldOffset(4)] public int KeyDown;
        [FieldOffset(8)] public ushort RepeatCount;
        [FieldOffset(10)] public ushort VirtualKeyCode;
        [FieldOffset(12)] public ushort VirtualScanCode;
        [FieldOffset(14)] public ushort UnicodeChar;
        [FieldOffset(16)] public uint ControlKeyState;
    }

    private const ushort KeyEvent = 0x0001;
    private const uint ShiftPressed = 0x0010;
    private const ushort VkReturn = 0x0D;
    private const uint GenericRead = 0x80000000;
    private const uint GenericWrite = 0x40000000;
    private const uint FileShareReadWrite = 0x00000003;
    private const uint OpenExisting = 3;
    private static readonly IntPtr InvalidHandle = new IntPtr(-1);

    [DllImport("kernel32.dll", SetLastError = true)]
    private static extern bool FreeConsole();

    [DllImport("kernel32.dll", SetLastError = true)]
    private static extern bool AttachConsole(uint processId);

    [DllImport("kernel32.dll", SetLastError = true)]
    private static extern bool SetConsoleCtrlHandler(IntPtr handler, bool add);

    [DllImport("kernel32.dll", SetLastError = true, CharSet = CharSet.Unicode)]
    private static extern IntPtr CreateFileW(string name, uint access, uint share, IntPtr security, uint disposition, uint flags, IntPtr template);

    [DllImport("kernel32.dll", SetLastError = true)]
    private static extern bool CloseHandle(IntPtr handle);

    [DllImport("kernel32.dll", SetLastError = true)]
    private static extern bool GetConsoleScreenBufferInfo(IntPtr output, out ScreenBufferInfo info);

    [DllImport("kernel32.dll", SetLastError = true, CharSet = CharSet.Unicode)]
    private static extern bool ReadConsoleOutputCharacterW(IntPtr output, [Out] char[] buffer, uint length, Coord readCoord, out uint read);

    [DllImport("kernel32.dll", SetLastError = true)]
    private static extern bool WriteConsoleInputW(IntPtr input, KeyInputRecord[] records, uint length, out uint written);

    [DllImport("user32.dll", CharSet = CharSet.Unicode)]
    private static extern short VkKeyScanW(char ch);

    public static void Detach()
    {
        FreeConsole();
    }

    private static void AttachTo(uint processId)
    {
        FreeConsole();
        if (!AttachConsole(processId))
        {
            throw new InvalidOperationException("AttachConsole(" + processId + ") failed, Win32 error " + Marshal.GetLastWin32Error() + ".");
        }
        // Ctrl+C pressed in the agy window must not kill the watchdog.
        SetConsoleCtrlHandler(IntPtr.Zero, true);
    }

    private static IntPtr Open(string name)
    {
        IntPtr handle = CreateFileW(name, GenericRead | GenericWrite, FileShareReadWrite, IntPtr.Zero, OpenExisting, 0, IntPtr.Zero);
        if (handle == InvalidHandle)
        {
            throw new InvalidOperationException("Opening " + name + " failed, Win32 error " + Marshal.GetLastWin32Error() + ".");
        }
        return handle;
    }

    // Returns the visible part of the agy console screen, one line per row.
    public static string ReadScreen(uint processId)
    {
        AttachTo(processId);
        try
        {
            IntPtr output = Open("CONOUT$");
            try
            {
                ScreenBufferInfo info;
                if (!GetConsoleScreenBufferInfo(output, out info))
                {
                    throw new InvalidOperationException("GetConsoleScreenBufferInfo failed, Win32 error " + Marshal.GetLastWin32Error() + ".");
                }
                int width = info.Size.X;
                char[] row = new char[width];
                StringBuilder screen = new StringBuilder();
                for (int y = info.Window.Top; y <= info.Window.Bottom; y++)
                {
                    uint read;
                    Coord start = new Coord { X = 0, Y = (short)y };
                    if (!ReadConsoleOutputCharacterW(output, row, (uint)width, start, out read))
                    {
                        read = 0;
                    }
                    screen.Append(new string(row, 0, (int)read).TrimEnd()).Append('\n');
                }
                return screen.ToString();
            }
            finally
            {
                CloseHandle(output);
            }
        }
        finally
        {
            FreeConsole();
        }
    }

    // Types the text into the agy console input as key presses, then presses Enter.
    public static void TypeLine(uint processId, string text, int enterDelayMilliseconds)
    {
        AttachTo(processId);
        try
        {
            IntPtr input = Open("CONIN$");
            try
            {
                KeyInputRecord[] keys = new KeyInputRecord[text.Length * 2];
                for (int i = 0; i < text.Length; i++)
                {
                    short scan = VkKeyScanW(text[i]);
                    ushort virtualKey = scan == -1 ? (ushort)0 : (ushort)(scan & 0xFF);
                    uint control = scan != -1 && (scan & 0x100) != 0 ? ShiftPressed : 0;
                    keys[i * 2] = CreateKey(true, virtualKey, text[i], control);
                    keys[i * 2 + 1] = CreateKey(false, virtualKey, text[i], control);
                }
                Write(input, keys);

                // A separate, delayed Enter, so the TUI does not treat it as part of a paste.
                Thread.Sleep(enterDelayMilliseconds);
                Write(input, new[] { CreateKey(true, VkReturn, '\r', 0), CreateKey(false, VkReturn, '\r', 0) });
            }
            finally
            {
                CloseHandle(input);
            }
        }
        finally
        {
            FreeConsole();
        }
    }

    private static KeyInputRecord CreateKey(bool keyDown, ushort virtualKey, char character, uint controlKeyState)
    {
        return new KeyInputRecord
        {
            EventType = KeyEvent,
            KeyDown = keyDown ? 1 : 0,
            RepeatCount = 1,
            VirtualKeyCode = virtualKey,
            UnicodeChar = character,
            ControlKeyState = controlKeyState
        };
    }

    private static void Write(IntPtr input, KeyInputRecord[] keys)
    {
        uint written;
        if (!WriteConsoleInputW(input, keys, (uint)keys.Length, out written))
        {
            throw new InvalidOperationException("WriteConsoleInput failed, Win32 error " + Marshal.GetLastWin32Error() + ".");
        }
    }
}
'@

# The attach-mode worker has no console of its own; the visible window shows the log instead.
$script:LogOnly = $Attach -or $AttachWorker

function Write-Log([string] $Message, [string] $Color = 'Gray')
{
    $line = "[$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')] $Message"
    if (-not $script:LogOnly) { Write-Host $line -ForegroundColor $Color }
    Add-Content -LiteralPath $LogFile -Value $line -Encoding utf8
}

function Get-AgyPath
{
    $cmd = Get-Command agy -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($cmd) { return $cmd.Source }
    $fallback = Join-Path $env:LOCALAPPDATA 'agy\bin\agy.exe'
    if (Test-Path $fallback) { return $fallback }
    throw 'agy not found on PATH or in %LOCALAPPDATA%\agy\bin.'
}

function Test-PlanHasOpenItems
{
    if (-not $PlanFile) { return $false }
    $path = Join-Path $WorkDir $PlanFile
    if (-not (Test-Path -LiteralPath $path -PathType Leaf)) { return $false }
    return [bool](Select-String -LiteralPath $path -Pattern '^\s*[-*]\s+\[ \]' -Quiet)
}

function Stop-Watchdog([string] $Reason, [string] $Color)
{
    Write-Log $Reason $Color
    if ($script:Conversation) { Write-Log "Conversation: $script:Conversation" }
    Write-Log "Log: $LogFile"
    if (-not $script:LogOnly) { [Console]::Beep(880, 400); [Console]::Beep(660, 600) }
    exit 0
}

# --- headless mode -------------------------------------------------------------------------------

function Get-WorkTreeFingerprint
{
    $head = & git -C $WorkDir rev-parse --verify -q HEAD 2>$null
    if ($LASTEXITCODE -ne 0 -and -not $head) { $head = 'no-head' }
    $status = (& git -C $WorkDir status --porcelain=v1 -uall 2>$null) -join "`n"
    if ($LASTEXITCODE -ne 0) { return $null }
    # Hash file contents too, so further edits to already-dirty files count as progress.
    $contentHashes = foreach ($line in ($status -split "`n"))
    {
        if ($line.Length -lt 4) { continue }
        $path = ($line.Substring(3) -split ' -> ')[-1].Trim('"')
        $full = Join-Path $WorkDir $path
        if (Test-Path -LiteralPath $full -PathType Leaf) { (Get-FileHash -LiteralPath $full -Algorithm SHA256).Hash }
    }
    return "$head|$status|$($contentHashes -join ',')"
}

function Get-FailureKind([string] $Text, [datetime] $Since)
{
    $logDir = Join-Path $HOME '.gemini\antigravity-cli\log'
    if (Test-Path $logDir)
    {
        $log = Get-ChildItem $logDir -Filter 'cli-*.log' |
            Where-Object { $_.LastWriteTime -ge $Since.AddSeconds(-5) } |
            Sort-Object LastWriteTime -Descending | Select-Object -First 1
        if ($log) { $Text += "`n" + (Get-Content -LiteralPath $log.FullName -Raw) }
    }
    if ($Text -match 'auth timed out|silent auth failed|keyringAuth: timed out|unauthenticated|UNAUTHENTICATED') { return 'auth' }
    if ($Text -match 'RESOURCE_EXHAUSTED|quota|rate limit|\b429\b') { return 'quota' }
    return 'unknown'
}

function Invoke-AgyRound([string] $Prompt)
{
    # --print must be the last flag: it takes the prompt as its value.
    $agyArgs = [Collections.Generic.List[string]]::new()
    $agyArgs.Add('--dangerously-skip-permissions')   # headless: nobody can answer a permission prompt
    $agyArgs.AddRange([string[]]@('--output-format', 'json'))
    if ($Model) { $agyArgs.AddRange([string[]]@('--model', $Model)) }
    if ($script:Conversation) { $agyArgs.AddRange([string[]]@('--conversation', $script:Conversation)) }
    else { $agyArgs.Add('--continue') }
    $agyArgs.AddRange([string[]]@('--print', $Prompt))

    $psi = [Diagnostics.ProcessStartInfo]::new($script:AgyPath)
    foreach ($a in $agyArgs) { $psi.ArgumentList.Add($a) }
    $psi.WorkingDirectory = $WorkDir
    $psi.UseShellExecute = $false
    $psi.RedirectStandardInput = $true
    $psi.RedirectStandardOutput = $true
    $psi.RedirectStandardError = $true
    $psi.StandardOutputEncoding = [Text.Encoding]::UTF8
    $psi.StandardErrorEncoding = [Text.Encoding]::UTF8

    $started = Get-Date
    $proc = [Diagnostics.Process]::Start($psi)
    # An inherited open stdin can hang print mode.
    $proc.StandardInput.Close()
    $stdoutTask = $proc.StandardOutput.ReadToEndAsync()
    $stderrTask = $proc.StandardError.ReadToEndAsync()

    $timedOut = -not $proc.WaitForExit($RoundTimeoutMinutes * 60 * 1000)
    if ($timedOut)
    {
        $proc.Kill($true)
        $proc.WaitForExit()
    }
    $stdout = $stdoutTask.GetAwaiter().GetResult()
    $stderr = $stderrTask.GetAwaiter().GetResult()

    $json = $null
    if ($stdout.Trim())
    {
        try { $json = $stdout | ConvertFrom-Json -Depth 20 } catch { $json = $null }
    }

    $status = if ($timedOut) { 'TIMEOUT' } elseif ($json) { [string]$json.status } else { 'ERROR' }
    $response = if ($json) { [string]$json.response } else { $stdout }
    if ($json -and $json.conversation_id) { $script:Conversation = [string]$json.conversation_id }

    $failure = if ($status -eq 'SUCCESS' -or $timedOut) { $null } else { Get-FailureKind "$stdout`n$stderr" $started }

    return [pscustomobject]@{
        Status   = $status
        Response = $response
        Stderr   = $stderr
        Failure  = $failure
        Minutes  = [math]::Round(((Get-Date) - $started).TotalMinutes, 1)
    }
}

function Start-HeadlessMode
{
    $script:AgyPath = Get-AgyPath
    if (Get-Process -Name agy -ErrorAction SilentlyContinue)
    {
        Write-Log 'Warning: another agy process is running. Close the interactive agy session for this project first.' 'Yellow'
    }

    Write-Log "Watchdog started (headless). WorkDir: $WorkDir  Plan: $PlanFile  Log: $LogFile" 'Cyan'

    $prompt = $ContinuePrompt
    $consecutiveErrors = 0
    $stalledRounds = 0
    $lastFingerprint = Get-WorkTreeFingerprint

    for ($round = 1; $round -le $MaxRounds; $round++)
    {
        Write-Log "Round $round/${MaxRounds}: sending prompt to agy..." 'Cyan'
        $result = Invoke-AgyRound $prompt
        Write-Log "agy finished: status=$($result.Status), $($result.Minutes) min, conversation=$script:Conversation"
        if ($result.Response) { Add-Content -LiteralPath $LogFile -Value "--- agy response ---`n$($result.Response)`n---" -Encoding utf8 }

        if ($result.Status -ne 'SUCCESS' -and $result.Status -ne 'TIMEOUT')
        {
            switch ($result.Failure)
            {
                'auth' { Stop-Watchdog 'agy is not authenticated: run agy interactively once, then restart the watchdog.' 'Red' }
                'quota'
                {
                    Write-Log "Quota exhausted. Waiting $QuotaWaitMinutes min before retrying..." 'Yellow'
                    Start-Sleep -Seconds ($QuotaWaitMinutes * 60)
                    $round--   # waiting for quota does not use up a round
                    continue
                }
                default
                {
                    $consecutiveErrors++
                    Write-Log "agy error ($consecutiveErrors/$MaxConsecutiveErrors). stderr: $($result.Stderr.Trim())" 'Yellow'
                    if ($consecutiveErrors -ge $MaxConsecutiveErrors) { Stop-Watchdog 'Too many consecutive agy errors.' 'Red' }
                    Start-Sleep -Seconds ($ErrorWaitMinutes * 60)
                    continue
                }
            }
        }
        $consecutiveErrors = 0
        if ($result.Status -eq 'TIMEOUT') { Write-Log "Round hit the $RoundTimeoutMinutes min limit; agy was stopped and will be resumed." 'Yellow' }

        $tail = ($result.Response.TrimEnd() -split "`n" | Select-Object -Last 3) -join "`n"
        if ($tail -match [regex]::Escape($HumanMarker))
        {
            Stop-Watchdog "agy needs a human decision: $(($tail -split [regex]::Escape($HumanMarker))[-1].Trim())" 'Magenta'
        }
        if ($tail -match [regex]::Escape($DoneMarker))
        {
            if ((Test-PlanHasOpenItems) -and $prompt -ne $FalseDonePrompt)
            {
                Write-Log 'agy claims done, but the plan still has unchecked items. Pushing back once.' 'Yellow'
                $prompt = $FalseDonePrompt
                continue
            }
            Stop-Watchdog 'agy reports that all plan steps are done.' 'Green'
        }

        $fingerprint = Get-WorkTreeFingerprint
        if ($null -ne $fingerprint -and $fingerprint -eq $lastFingerprint)
        {
            $stalledRounds++
            Write-Log "No changes in the working tree this round ($stalledRounds/$MaxStalledRounds)." 'Yellow'
            if ($stalledRounds -ge $MaxStalledRounds) { Stop-Watchdog 'agy keeps stopping without making any changes. Check it manually.' 'Red' }
        }
        else
        {
            $stalledRounds = 0
        }
        $lastFingerprint = $fingerprint
        $prompt = $ContinuePrompt
    }

    Stop-Watchdog "Reached MaxRounds ($MaxRounds)." 'Yellow'
}

# --- attach mode ---------------------------------------------------------------------------------

function Resolve-AgyPid
{
    if ($AgyPid)
    {
        $process = Get-Process -Id $AgyPid -ErrorAction SilentlyContinue
        # A self-updated agy keeps running as "agy.exe.<timestamp>.old".
        if (-not $process -or $process.ProcessName -notlike 'agy*') { throw "No agy process with PID $AgyPid." }
        return $AgyPid
    }

    $all = @(Get-CimInstance Win32_Process -Filter "Name = 'agy.exe'")
    $allIds = @($all | ForEach-Object { $_.ProcessId })
    # Interactive sessions only: skip print-mode runs and agy child processes.
    $interactive = @($all | Where-Object {
            $_.CommandLine -notmatch '\s(--print|--prompt|-p)(\s|=|$)' -and $allIds -notcontains $_.ParentProcessId
        })
    if ($interactive.Count -eq 0) { throw 'No interactive agy is running. Start agy first, then the watchdog.' }
    if ($interactive.Count -gt 1)
    {
        $list = ($interactive | ForEach-Object { "  PID $($_.ProcessId), started $($_.CreationDate): $($_.CommandLine)" }) -join "`n"
        throw "More than one interactive agy is running. Choose one with -AgyPid:`n$list"
    }
    return [int]$interactive[0].ProcessId
}

function ConvertTo-ProcessArgument([string] $Value)
{
    return '"' + ($Value -replace '"', '\"') + '"'
}

function Start-AttachMode
{
    $agyId = Resolve-AgyPid
    $workerArgs = @(
        '-NoProfile', '-NonInteractive', '-File', (ConvertTo-ProcessArgument $PSCommandPath),
        '-AttachWorker',
        '-AgyPid', $agyId,
        '-WorkDir', (ConvertTo-ProcessArgument $WorkDir),
        '-IdleMinutes', $IdleMinutes,
        '-PollSeconds', $PollSeconds,
        '-MaxNudges', $MaxNudges,
        '-QuotaWaitMinutes', $QuotaWaitMinutes,
        '-LogFile', (ConvertTo-ProcessArgument $LogFile)
    )
    if ($PlanFile) { $workerArgs += @('-PlanFile', (ConvertTo-ProcessArgument $PlanFile)) }
    $workerArgs = $workerArgs -join ' '

    $planInfo = if ($PlanFile) { "  Plan: $PlanFile" } else { '' }
    Write-Log "Watchdog started (attach). agy PID: $agyId  WorkDir: $WorkDir$planInfo  Log: $LogFile"
    Write-Host 'Keep working in the agy window as usual. Press Ctrl+C here to stop watching.' -ForegroundColor Cyan

    # The worker runs hidden, because attaching to the agy console requires a process without a console of its own.
    $pwshPath = (Get-Process -Id $PID).Path
    $worker = Start-Process -FilePath $pwshPath -ArgumentList $workerArgs -WindowStyle Hidden -PassThru
    $shownLines = 0
    try
    {
        do
        {
            Start-Sleep -Seconds 2
            $lines = @(Get-Content -LiteralPath $LogFile -ErrorAction SilentlyContinue)
            for (; $shownLines -lt $lines.Count; $shownLines++) { Write-Host $lines[$shownLines] }
        }
        while (-not $worker.HasExited)
        [Console]::Beep(880, 400); [Console]::Beep(660, 600)
    }
    finally
    {
        if (-not $worker.HasExited)
        {
            Stop-Process -Id $worker.Id -Force
            Write-Host 'Watchdog stopped.' -ForegroundColor Yellow
        }
    }
}

function Get-ScreenFingerprint([string] $Screen)
{
    # Digits are ignored, so clocks and elapsed-time counters do not count as activity; spinners still do.
    $text = $Screen -replace '\d', ''
    return [Convert]::ToHexString([Security.Cryptography.SHA256]::HashData([Text.Encoding]::UTF8.GetBytes($text)))
}

function Find-QuotaBanner([string] $Screen)
{
    if ($Screen -notmatch '(?i)quota (reached|limit exceeded|exceeded)|RESOURCE_EXHAUSTED') { return $null }
    $banner = $Matches[0]
    $resetSeconds = $null
    if ($Screen -match '(?i)Resets in\s*(?:(\d+)\s*h)?\s*(?:(\d+)\s*m)?\s*(?:(\d+)\s*s)?')
    {
        $banner = $Matches[0]
        $resetSeconds = 3600 * [int]('0' + $Matches[1]) + 60 * [int]('0' + $Matches[2]) + [int]('0' + $Matches[3])
    }
    return [pscustomobject]@{ Text = $banner.Trim(); ResetSeconds = $resetSeconds }
}

function Invoke-AttachLoop([int] $AgyId)
{
    $quotaFirstSeen = @{}
    $lastFingerprint = $null
    $unchangedSince = Get-Date
    $unchangedPolls = 0
    $nudges = 0
    $ineffectiveNudges = 0
    $fingerprintBeforeNudge = $null
    $pushedBackOnDone = $false
    $waitLogged = @{}

    $first = [AgyConsoleBridge]::ReadScreen($AgyId)
    Write-Log "Attached to the agy console (PID $AgyId), $(($first.TrimEnd() -split "`n").Count) screen lines."

    while ($true)
    {
        if (-not (Get-Process -Id $AgyId -ErrorAction SilentlyContinue)) { Stop-Watchdog 'agy has exited.' }

        $screen = [AgyConsoleBridge]::ReadScreen($AgyId)
        $fingerprint = Get-ScreenFingerprint $screen
        if ($fingerprint -ne $lastFingerprint)
        {
            $lastFingerprint = $fingerprint
            $unchangedSince = Get-Date
            $unchangedPolls = 0
        }
        else
        {
            $unchangedPolls++
        }

        if ($null -ne $fingerprintBeforeNudge)
        {
            if ($fingerprint -eq $fingerprintBeforeNudge)
            {
                $ineffectiveNudges++
                Write-Log "The typed prompt did not change the agy screen ($ineffectiveNudges/$MaxIneffectiveNudges)."
                if ($ineffectiveNudges -ge $MaxIneffectiveNudges) { Stop-Watchdog 'Typing into the agy window has no effect. Check it manually.' }
            }
            else
            {
                $ineffectiveNudges = 0
            }
            $fingerprintBeforeNudge = $null
        }

        # Act only when agy has stopped working: a changing screen means it is busy.
        if ($unchangedPolls -ge $IdlePollsBeforeAction)
        {
            $lines = $screen -split "`n"
            $humanLine = $lines | Where-Object { $_ -match '^\W*NEED_HUMAN:\s*(\S.*)$' } | Select-Object -Last 1
            if ($humanLine)
            {
                Stop-Watchdog "agy needs a human decision: $(($humanLine -split 'NEED_HUMAN:')[-1].Trim())"
            }

            $nudge = $null
            if ($lines | Where-Object { $_ -match '^\W*ALL_PLAN_STEPS_DONE\W*$' })
            {
                if ($pushedBackOnDone -or -not (Test-PlanHasOpenItems)) { Stop-Watchdog 'agy reports that all plan steps are done.' }
                Write-Log 'agy claims done, but the plan still has unchecked items. Pushing back once.'
                $pushedBackOnDone = $true
                $nudge = $AttachFalseDonePrompt
            }

            $quota = if (-not $nudge) { Find-QuotaBanner $screen } else { $null }
            if ($quota)
            {
                if (-not $quotaFirstSeen.ContainsKey($quota.Text)) { $quotaFirstSeen[$quota.Text] = Get-Date }
                $waitSeconds = if ($null -ne $quota.ResetSeconds) { $quota.ResetSeconds + $QuotaResetMarginSeconds } else { $QuotaWaitMinutes * 60 }
                $resumeAt = $quotaFirstSeen[$quota.Text].AddSeconds($waitSeconds)
                if ((Get-Date) -lt $resumeAt)
                {
                    if (-not $waitLogged.ContainsKey($quota.Text))
                    {
                        Write-Log "Quota banner: '$($quota.Text)'. Resuming at $($resumeAt.ToString('yyyy-MM-dd HH:mm'))."
                        $waitLogged[$quota.Text] = $true
                    }
                }
                else
                {
                    Write-Log 'Quota window should be reset now.'
                    $nudge = $AttachContinuePrompt
                }
            }
            elseif (-not $nudge -and ((Get-Date) - $unchangedSince).TotalMinutes -ge $IdleMinutes)
            {
                Write-Log "agy has been idle for $IdleMinutes min."
                $nudge = $AttachContinuePrompt
            }

            if ($nudge)
            {
                if ($nudges -ge $MaxNudges) { Stop-Watchdog "Reached MaxNudges ($MaxNudges)." }
                $nudges++
                [AgyConsoleBridge]::TypeLine($AgyId, $nudge, 500)
                Write-Log "Typed a continue prompt into agy ($nudges/$MaxNudges)."
                $fingerprintBeforeNudge = $fingerprint
                $unchangedSince = Get-Date
                $unchangedPolls = 0
            }
        }

        Start-Sleep -Seconds $PollSeconds
    }
}

function Start-AttachWorker
{
    try
    {
        Add-Type -TypeDefinition $ConsoleBridgeSource
        [AgyConsoleBridge]::Detach()
        Invoke-AttachLoop $AgyPid
    }
    catch
    {
        Write-Log "Watchdog error: $($_.Exception.Message)"
        exit 1
    }
}

# --- entry point ---------------------------------------------------------------------------------

$WorkDir = (Resolve-Path -LiteralPath $WorkDir).Path
if (-not $PlanFile -and -not ($Attach -or $AttachWorker))
{
    throw 'Headless mode needs -PlanFile. Use -Attach to watch an interactive agy without a plan file.'
}
if ($PlanFile -and -not (Test-Path -LiteralPath (Join-Path $WorkDir $PlanFile) -PathType Leaf))
{
    throw "Plan file not found: $(Join-Path $WorkDir $PlanFile)"
}

if ($AttachWorker) { Start-AttachWorker }
elseif ($Attach) { Start-AttachMode }
else { Start-HeadlessMode }
