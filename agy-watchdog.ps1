#Requires -Version 7.2
<#
.SYNOPSIS
    Keeps an Antigravity CLI (agy) conversation working through its saved plan until it is done.

.DESCRIPTION
    Resumes one agy conversation in print mode, round after round:
    - every time agy ends a turn without the done marker, it is told to continue with the next plan step;
    - when the quota is exhausted, waits and retries (the 5h window resets on its own);
    - stops when agy reports the done marker, asks for a human (NEED_HUMAN), hits an auth error,
      makes no changes to the working tree for several rounds in a row, or reaches MaxRounds.
    Close the interactive agy session for this project before starting (two clients on one conversation conflict).

.EXAMPLE
    pwsh -NoProfile -File agy-watchdog.ps1 -WorkDir C:\Projekty\ip9.pl\cardputer.ip9.pl -PlanFile PLAN.md
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [string] $WorkDir,

    # Plan file path relative to WorkDir (the agent's saved work plan).
    [Parameter(Mandatory)]
    [string] $PlanFile,

    # Conversation ID to resume; when omitted, the most recent conversation is continued (--continue).
    [string] $Conversation,

    [string] $Model,

    [ValidateRange(1, 500)]
    [int] $MaxRounds = 100,

    [ValidateRange(5, 240)]
    [int] $RoundTimeoutMinutes = 90,

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

function Write-Log([string] $Message, [string] $Color = 'Gray')
{
    $line = "[$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')] $Message"
    Write-Host $line -ForegroundColor $Color
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

function Test-PlanHasOpenItems
{
    $path = Join-Path $WorkDir $PlanFile
    if (-not (Test-Path -LiteralPath $path -PathType Leaf)) { return $false }
    return [bool](Select-String -LiteralPath $path -Pattern '^\s*[-*]\s+\[ \]' -Quiet)
}

function Stop-Watchdog([string] $Reason, [string] $Color)
{
    Write-Log $Reason $Color
    Write-Log "Conversation: $script:Conversation  Log: $LogFile"
    [Console]::Beep(880, 400); [Console]::Beep(660, 600)
    exit 0
}

# --- main loop -----------------------------------------------------------------------------------

$WorkDir = (Resolve-Path -LiteralPath $WorkDir).Path
$AgyPath = Get-AgyPath
if (-not (Test-Path -LiteralPath (Join-Path $WorkDir $PlanFile) -PathType Leaf))
{
    throw "Plan file not found: $(Join-Path $WorkDir $PlanFile)"
}
if (Get-Process -Name agy -ErrorAction SilentlyContinue)
{
    Write-Log 'Warning: another agy process is running. Close the interactive agy session for this project first.' 'Yellow'
}

Write-Log "Watchdog started. WorkDir: $WorkDir  Plan: $PlanFile  Log: $LogFile" 'Cyan'

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
