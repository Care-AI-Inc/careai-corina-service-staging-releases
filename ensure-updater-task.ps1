# ensure-updater-task.ps1
# Shared helper used by install.ps1 and daily-updater.ps1.
# Writes the scheduled-task shim to C:\Scripts and registers/updates the
# CorinaStagingDailyUpdater scheduled task.
#
# Consumed at runtime via:
#   irm https://raw.githubusercontent.com/Care-AI-Inc/careai-corina-service-staging-releases/main/ensure-updater-task.ps1 | iex
# which defines Ensure-CorinaStagingUpdaterTask in the caller's scope.
#
# Behavior switches:
#   -ForceRecreate    : unregister an existing task and re-register it with the full
#                       trigger set (install behavior). Without it, an existing task
#                       gets its action refreshed and only missing triggers are added
#                       (updater behavior).
#   -LegacyShimPaths  : old shim files to delete once the new shim path is in use.
#   -Log              : scriptblock taking one message string; defaults to Write-Host.

function Ensure-CorinaStagingUpdaterTask {
    param(
        [string]$Instance,
        [Parameter(Mandatory=$true)][string]$TaskName,
        [string[]]$LegacyTaskNames = @(),
        [string[]]$LegacyShimPaths = @(),
        [switch]$ForceRecreate,
        [scriptblock]$Log = { param($Message) Write-Host "    -> $Message" }
    )

    $scriptDir = "C:\Scripts"
    if (-not (Test-Path $scriptDir)) { New-Item -ItemType Directory -Path $scriptDir | Out-Null }

    $shimPath = if ($Instance) {
        Join-Path $scriptDir "run-daily-updater-staging-$Instance.ps1"
    } else {
        Join-Path $scriptDir "run-daily-updater-staging.ps1"
    }

    foreach ($legacyTaskName in $LegacyTaskNames | Select-Object -Unique) {
        if ($legacyTaskName -and $legacyTaskName -ne $TaskName -and (Get-ScheduledTask -TaskName $legacyTaskName -ErrorAction SilentlyContinue)) {
            & $Log "Removing legacy scheduled task: $legacyTaskName"
            Unregister-ScheduledTask -TaskName $legacyTaskName -Confirm:$false
            Start-Sleep -Seconds 1
        }
    }

    foreach ($legacyShimPath in $LegacyShimPaths | Select-Object -Unique) {
        if ($legacyShimPath -and $legacyShimPath -ne $shimPath -and (Test-Path $legacyShimPath)) {
            & $Log "Removing legacy updater shim: $legacyShimPath"
            Remove-Item -LiteralPath $legacyShimPath -Force -ErrorAction SilentlyContinue
        }
    }

    # The shim runs as the scheduled task's target. It always fetches the latest
    # daily-updater.ps1 from GitHub so clinic machines self-update without redeploying
    # the task. Instance/environment variables are prepended per install below.
    $shimPrefix = "`$env:DOTNET_ENVIRONMENT = 'Staging'`r`n"
    if ($Instance) {
        $shimPrefix = "`$env:CorinaRegistryInstance = '$Instance'`r`n$shimPrefix"
    }
    & $Log "Writing updater shim: $shimPath"
    $shimContent = @'
# run-daily-updater-staging.ps1
# Shim run by the CorinaStagingDailyUpdater scheduled task.
# Downloads the latest daily-updater.ps1 from GitHub and runs it in a child process.
# Every stage is logged, and the child's exit code is propagated so Task Scheduler
# reports a real failure code instead of always showing 0x0.

$ErrorActionPreference = 'Stop'
$_inst   = $env:CorinaRegistryInstance
$LogPath = if ($_inst) { "C:\Scripts\corina-staging-update-log-$_inst.txt" } else { 'C:\Scripts\corina-staging-update-log.txt' }
$Url     = 'https://raw.githubusercontent.com/Care-AI-Inc/careai-corina-service-staging-releases/main/daily-updater.ps1'

# Writes a timestamped, structured entry to the update log (for scheduled runs /
# history) and echoes installer-style output to the console (for manual runs).
# Levels render a scannable status column in the log:
#   STEP -> "[*] ", DETAIL -> "    -> ", OK -> "[OK] ", ERROR -> "[FAIL] ", WARN -> "[WARN] "
function Write-Shim {
    param(
        [Parameter(Mandatory=$true)][string]$Message,
        [string]$Level = 'DETAIL'
    )
    $prefix = switch ($Level) {
        'STEP'  { '[*] ' }
        'OK'    { '[OK] ' }
        'ERROR' { '[FAIL] ' }
        'WARN'  { '[WARN] ' }
        default { '    -> ' }
    }
    try { "[$(Get-Date)] $prefix$Message" | Out-File -Append $LogPath } catch { }
    switch ($Level) {
        'ERROR' { Write-Host "ERROR: $Message" }
        'WARN'  { Write-Warning $Message }
        'OK'    { Write-Host "SUCCESS: $Message" }
        'STEP'  { Write-Host "`n[*] $Message" }
        default { Write-Host "    -> $Message" }
    }
}

$instLabel = if ($_inst) { $_inst } else { '<default>' }
# Blank line + banner so each run stands out when scanning the log.
try {
    "" | Out-File -Append $LogPath
    "[$(Get-Date)] ==================== RUN START: Corina Service (Staging) daily auto-updater ====================" | Out-File -Append $LogPath
} catch { }
Write-Host "`n[*] Corina Service (Staging) daily auto-updater"
Write-Shim "Shim: fetch latest daily-updater.ps1 from GitHub" 'STEP'
Write-Shim "instance: $instLabel, user: $env:USERNAME, PS: $($PSVersionTable.PSVersion)"
Write-Shim "update log: $LogPath"

# 1) Force TLS 1.2 (required for GitHub)
try {
    $proto = [System.Net.ServicePointManager]::SecurityProtocol
    $tls12 = [System.Net.SecurityProtocolType]::Tls12
    if (($proto -band $tls12) -eq 0) {
        [System.Net.ServicePointManager]::SecurityProtocol = $proto -bor $tls12
    }
} catch {
    Write-Shim "Failed to enable TLS 1.2: $_" 'WARN'
}

# 2) Simple retry helper
function Invoke-WithRetry {
    param(
        [scriptblock]$Action,
        [int]$MaxRetries = 3,
        [int]$DelaySec   = 5
    )
    $attempt = 0
    while ($true) {
        try {
            $attempt++
            return & $Action
        } catch {
            if ($attempt -ge $MaxRetries) { throw }
            Start-Sleep -Seconds $DelaySec
        }
    }
}

# 3) Download and save the latest updater
try {
    $Headers = @{ 'User-Agent' = 'PowerShell/5.1 CareAI-Updater' }
    $safeInst = if ($_inst) { $_inst } else { 'default' }
    $TmpFile = [System.IO.Path]::Combine([System.IO.Path]::GetTempPath(), "daily-updater-staging-$safeInst.ps1")

    $content = Invoke-WithRetry {
        (Invoke-WebRequest -Uri $Url -Headers $Headers -UseBasicParsing -TimeoutSec 30).Content
    }

    if ([string]::IsNullOrWhiteSpace($content)) {
        throw "Downloaded content is empty."
    }
    if ($content.Length -gt 0 -and $content[0] -eq [char]0xFEFF) {
        $content = $content.Substring(1)
    }

    $content | Set-Content -LiteralPath $TmpFile -Encoding UTF8
    Write-Shim "downloaded updater ($($content.Length) chars) to $TmpFile"
    Write-Shim "Shim: updater fetched" 'OK'
}
catch {
    Write-Shim "Shim: failed to fetch latest staging updater: $_" 'ERROR'
    exit 1
}

# 4) Run the updater in a child process and propagate its exit code.
#    A child failure (non-zero exit, AV/AppLocker block, GPO denial) does NOT throw
#    here, so it must be detected via $LASTEXITCODE -- otherwise the scheduled task
#    always reports 0x0 even when nothing ran.
#    stdout/stderr are captured (and still echoed live) so that errors the updater
#    prints to the console -- admin-check failures, parse errors, AppLocker blocks --
#    can be written to the log on failure instead of vanishing with the process.
try {
    Write-Shim "Shim: run updater in a child process" 'STEP'
    $childOutput = New-Object System.Collections.Generic.List[string]
    $prevEAP = $ErrorActionPreference
    # In PowerShell 5.1, 2>&1 on a native command turns stderr lines into terminating
    # errors when ErrorActionPreference is Stop; relax it just for this invocation.
    $ErrorActionPreference = 'Continue'
    try {
        & powershell -NoProfile -ExecutionPolicy Bypass -File $TmpFile 2>&1 | ForEach-Object {
            $line = [string]$_
            $childOutput.Add($line)
            Write-Host $line
        }
        $updaterExit = $LASTEXITCODE
    } finally {
        $ErrorActionPreference = $prevEAP
    }
}
catch {
    Write-Shim "Shim: failed to start updater process: $_" 'ERROR'
    exit 1
}

if ($null -eq $updaterExit) { $updaterExit = 1 }
if ($updaterExit -ne 0) {
    $tail = @($childOutput | Select-Object -Last 40)
    if ($tail.Count -gt 0) {
        try {
            "[$(Get-Date)] [FAIL] Shim: updater console output (last $($tail.Count) line(s)):" | Out-File -Append $LogPath
            $tail | ForEach-Object { "[$(Get-Date)]     |  $_" | Out-File -Append $LogPath }
        } catch { }
    }
    Write-Shim "Shim: updater exited with code $updaterExit. If the updater logged nothing above, it was likely blocked before running (AV/AppLocker/GPO)." 'ERROR'
    exit $updaterExit
}

Write-Shim "Shim: updater finished with exit code 0" 'OK'
exit 0
'@
    ($shimPrefix + $shimContent) | Set-Content -Path $shimPath -Encoding UTF8

    if ($Instance) {
        $taskArgument = "-NoProfile -ExecutionPolicy Bypass -Command `"`$env:CorinaRegistryInstance='$Instance'; `$env:DOTNET_ENVIRONMENT='Staging'; & '$shimPath'`""
    } else {
        $taskArgument = "-NoProfile -ExecutionPolicy Bypass -File `"$shimPath`""
    }
    $taskAction   = New-ScheduledTaskAction -Execute "powershell.exe" -Argument $taskArgument
    $principal    = New-ScheduledTaskPrincipal -UserId "SYSTEM" -LogonType ServiceAccount -RunLevel Highest
    $settings     = New-ScheduledTaskSettingsSet -MultipleInstances IgnoreNew
    $desiredTimes = @("00:00", "07:00", "09:00", "11:00", "13:00", "15:00", "17:00")

    $existingTask = Get-ScheduledTask -TaskName $TaskName -ErrorAction SilentlyContinue
    if ($existingTask -and $ForceRecreate) {
        & $Log "Replacing existing scheduled task: $TaskName"
        Unregister-ScheduledTask -TaskName $TaskName -Confirm:$false
        Start-Sleep -Seconds 1
        $existingTask = $null
    }

    if (-not $existingTask) {
        $triggers = foreach ($time in $desiredTimes) {
            New-ScheduledTaskTrigger -Daily -At ([datetime]::ParseExact($time, "HH:mm", $null))
        }
        Register-ScheduledTask -TaskName $TaskName -Action $taskAction -Trigger $triggers -Principal $principal -Settings $settings | Out-Null
        & $Log "Scheduled task '$TaskName' created with $($desiredTimes.Count) daily triggers."
        return
    }

    # Task already exists (updater path): refresh the action, keep existing triggers,
    # and add any of the desired times that are missing.
    Set-ScheduledTask -TaskName $TaskName -Action $taskAction -Settings $settings -ErrorAction SilentlyContinue | Out-Null

    # Extract the wall-clock time straight from the StartBoundary string
    # (e.g. "2026-07-06T07:00:00" -> "07:00"). [DateTime]::Parse is culture-sensitive
    # and can fail on some locales; a failed parse used to make every desired time
    # look missing, piling duplicate triggers onto the task on every run.
    $existingTimes = @($existingTask.Triggers | ForEach-Object {
        if ([string]$_.StartBoundary -match 'T(\d{2}:\d{2})') { $Matches[1] } else { $null }
    } | Where-Object { $_ })

    $uniqueTimes  = @($existingTimes | Select-Object -Unique)
    $missingTimes = @($desiredTimes | Where-Object { $_ -notin $uniqueTimes })

    if ($uniqueTimes.Count -lt $existingTimes.Count) {
        # Duplicates accumulated from the old culture-sensitive parsing: rebuild the
        # trigger list once with each time appearing exactly once.
        $allTimes = @($uniqueTimes + $missingTimes | Select-Object -Unique)
        $newTriggers = foreach ($time in $allTimes) {
            New-ScheduledTaskTrigger -Daily -At ([datetime]::ParseExact($time, "HH:mm", $null))
        }
        Set-ScheduledTask -TaskName $TaskName -Trigger $newTriggers
        & $Log "Rebuilt triggers for '$TaskName' to remove duplicates ($($existingTimes.Count) -> $($allTimes.Count)): $($allTimes -join ', ')"
        return
    }

    if ($missingTimes.Count -gt 0) {
        $newTriggers = @($existingTask.Triggers)
        foreach ($time in $missingTimes) {
            $newTriggers += New-ScheduledTaskTrigger -Daily -At ([datetime]::ParseExact($time, "HH:mm", $null))
        }
        Set-ScheduledTask -TaskName $TaskName -Trigger $newTriggers
        & $Log "Added missing scheduled task triggers for '$TaskName': $($missingTimes -join ', ')"
    }
}
