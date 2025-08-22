# daily-updater-staging.ps1
# Purpose: Keep Samantha Uploader (Staging) up to date and finish migration from Corina if any remnants exist.
# Includes robust cleanup to handle locked files (e.g., logs).

# =========================
# Admin Check
# =========================
if (-not ([Security.Principal.WindowsPrincipal] `
    [Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole(`
    [Security.Principal.WindowsBuiltInRole] "Administrator")) {
    Write-Error "❌ You must run this script as Administrator."
    exit 1
}

# =========================
# Logging
# =========================
$logDir  = "C:\Scripts"
if (-not (Test-Path $logDir)) { New-Item -ItemType Directory -Path $logDir | Out-Null }
$logPath = Join-Path $logDir "samantha-update-log.txt"
"[$(Get-Date)] 🔄 Starting Samantha Uploader (Staging) update..." | Out-File -Append $logPath

# =========================
# Release Source (unchanged repo/artifacts)
# =========================
$repo   = "Care-AI-Inc/careai-corina-service-staging-releases"
$apiUrl = "https://api.github.com/repos/$repo/releases/latest"
$headers = @{ "User-Agent" = "SamanthaUploaderStagingUpdater" }

# =========================
# Names and Paths
# =========================
$newServiceName = "SamanthaUploader_Staging"
$oldServiceName = "CorinaService_Staging"

$newTaskName    = "SamanthaDailyUpdater"
$oldTaskName    = "CorinaDailyUpdater"

$exeName        = "careai-corina-service.exe"  # keep current exe name; change later when your releases do
$installDir     = Join-Path ${env:ProgramFiles} "SamanthaUploader_Staging"
$oldInstallDir  = Join-Path ${env:ProgramFiles} "CorinaService_Staging"
$exePath        = Join-Path $installDir $exeName

$tempZip    = $null
$extractDir = Join-Path $env:TEMP "SamanthaStagingExtract"

# =========================
# Robust directory removal helper
# =========================
function Remove-DirRobust {
    param(
        [Parameter(Mandatory=$true)][string]$Path,
        [int]$Retries = 3,
        [int]$DelaySeconds = 2
    )

    # 0) Best-effort: ensure nothing is holding the folder
    Get-Process careai-corina-service -ErrorAction SilentlyContinue | Stop-Process -Force
    Start-Sleep -Seconds 1

    # 1) Try a straight delete a few times
    for ($i=1; $i -le $Retries; $i++) {
        try {
            if (Test-Path $Path) {
                # Clear read-only attributes just in case
                Get-ChildItem -LiteralPath $Path -Force -Recurse -ErrorAction SilentlyContinue |
                    ForEach-Object { try { $_.Attributes = 'Normal' } catch {} }

                Remove-Item -LiteralPath $Path -Recurse -Force -ErrorAction Stop
            }
            return $true
        } catch {
            Start-Sleep -Seconds $DelaySeconds
        }
    }

    # 2) Use robocopy MIR trick to clear most contents (leaves only locked files)
    if (Test-Path $Path) {
        $empty = Join-Path $env:TEMP ("empty_" + [guid]::NewGuid())
        New-Item -ItemType Directory -Path $empty | Out-Null
        $rc = robocopy $empty $Path /MIR /R:1 /W:1 /NFL /NDL /NP /NJH /NJS
        Remove-Item -LiteralPath $empty -Recurse -Force -ErrorAction SilentlyContinue
        try {
            Remove-Item -LiteralPath $Path -Recurse -Force -ErrorAction Stop
            return $true
        } catch { }
    }

    # 3) Quarantine (rename) the folder, then schedule a one-shot delete at next boot
    if (Test-Path $Path) {
        $stamp = Get-Date -Format "yyyyMMddHHmmss"
        $quarantine = "$Path._stale_$stamp"
        try {
            Rename-Item -LiteralPath $Path -NewName (Split-Path $quarantine -Leaf) -ErrorAction Stop
        } catch {
            return $false  # rename failed; next run will retry
        }

        # Create a self-deleting startup task to remove the quarantined folder on next boot
        $taskName  = "SamanthaCleanupOldCorina_$stamp"
        $cmd       = "cmd.exe"
        $args      = "/c rmdir /s /q `"$quarantine`" && schtasks /Delete /TN `"$taskName`" /F"

        $action    = New-ScheduledTaskAction -Execute $cmd -Argument $args
        $trigger   = New-ScheduledTaskTrigger -AtStartup
        $principal = New-ScheduledTaskPrincipal -UserId "SYSTEM" -LogonType ServiceAccount -RunLevel Highest
        try {
            Register-ScheduledTask -TaskName $taskName -Action $action -Trigger $trigger -Principal $principal | Out-Null
        } catch { }

        return $false  # not gone now, but will be removed at next boot
    }

    return $true
}

try {
    # =========================
    # Fetch latest ZIP asset
    # =========================
    $response = Invoke-RestMethod -Uri $apiUrl -Headers $headers
    $zipAsset = $response.assets | Where-Object { $_.name -like '*.zip' } | Select-Object -First 1
    if (-not $zipAsset) { throw "No .zip asset found in latest release." }

    $zipUrl  = $zipAsset.browser_download_url
    $zipName = $zipAsset.name
    $tempZip = Join-Path $env:TEMP $zipName

    Invoke-WebRequest -Uri $zipUrl -OutFile $tempZip

    # =========================
    # Prepare extraction
    # =========================
    if (Test-Path $extractDir) { Remove-Item -Recurse -Force $extractDir }
    Expand-Archive -Path $tempZip -DestinationPath $extractDir

    # =========================
    # Stop whichever service exists first (new preferred)
    # =========================
    $svcToStop = Get-Service -Name $newServiceName -ErrorAction SilentlyContinue
    if (-not $svcToStop) { $svcToStop = Get-Service -Name $oldServiceName -ErrorAction SilentlyContinue }
    if ($svcToStop) {
        Stop-Service -Name $svcToStop.Name -Force -ErrorAction SilentlyContinue
        Start-Sleep -Seconds 2
        # Best-effort kill of lingering process
        Get-Process careai-corina-service -ErrorAction SilentlyContinue | Stop-Process -Force
        Start-Sleep -Seconds 1
    }

    # =========================
    # Ensure new install directory exists; if migrating, copy old -> new once
    # =========================
    if (-not (Test-Path $installDir)) {
        New-Item -ItemType Directory -Path $installDir -Force | Out-Null
        if (Test-Path $oldInstallDir) {
            # Robust copy preserving ACLs and attributes
            $rc = robocopy $oldInstallDir $installDir /E /COPYALL /R:2 /W:2 /NFL /NDL /NP /NJH /NJS
            if ($LASTEXITCODE -gt 8) { throw "Robocopy (old→new) failed with code $LASTEXITCODE" }
        }
    }

    # =========================
    # Copy extracted files → new install folder (preserve ACLs)
    # =========================
    $rc2 = robocopy $extractDir $installDir /E /R:2 /W:2 /NFL /NDL /NP /NJH /NJS
    if ($LASTEXITCODE -gt 8) { throw "Robocopy (extract→install) failed with code $LASTEXITCODE" }

    if (-not (Test-Path $exePath)) {
        throw "Executable not found at $exePath"
    }

    # =========================
    # Ensure service is the NEW name; migrate if needed
    # =========================
    $hasNew = Get-Service -Name $newServiceName -ErrorAction SilentlyContinue
    $hasOld = Get-Service -Name $oldServiceName -ErrorAction SilentlyContinue

    if (-not $hasNew) {
        if ($hasOld) {
            # Create new service, start it, then remove old
            sc.exe create $newServiceName binPath= "`"$exePath`"" start= auto DisplayName= "Samantha Uploader (Staging)" | Out-Null
            sc.exe failure     $newServiceName reset= 86400 actions= restart/5000/restart/5000/restart/5000 | Out-Null
            sc.exe failureflag $newServiceName 1 | Out-Null

            Start-Service -Name $newServiceName
            Start-Sleep -Seconds 3
            $svc = Get-Service -Name $newServiceName -ErrorAction Stop
            if ($svc.Status -ne 'Running') { throw "New service failed to start (status: $($svc.Status))" }

            sc.exe delete $oldServiceName | Out-Null
            Start-Sleep -Seconds 1
        } else {
            # Neither exists → create new cleanly
            sc.exe create $newServiceName binPath= "`"$exePath`"" start= auto DisplayName= "Samantha Uploader (Staging)" | Out-Null
            sc.exe failure     $newServiceName reset= 86400 actions= restart/5000/restart/5000/restart/5000 | Out-Null
            sc.exe failureflag $newServiceName 1 | Out-Null
            Start-Service -Name $newServiceName
        }
    } else {
        # New exists → start it
        Start-Service -Name $newServiceName
    }

    # =========================
    # Clean up old install folder (robust)
    # =========================
    if (Test-Path $oldInstallDir) {
        $ok = Remove-DirRobust -Path $oldInstallDir
        if (-not $ok) {
            "[$(Get-Date)] ⚠️ Old Corina folder was quarantined; a startup task will delete it on next boot." | Out-File -Append $logPath
        } else {
            "[$(Get-Date)] ✅ Old Corina folder removed." | Out-File -Append $logPath
        }
    }

    "[$(Get-Date)] ✅ Samantha Uploader (Staging) updated and service running." | Out-File -Append $logPath
}
catch {
    "[$(Get-Date)] ❌ Update failed: $_" | Out-File -Append $logPath
}

# =========================
# Scheduled Task: migrate old → new, or ensure new with desired times
# =========================
$scriptDir = "C:\Scripts"
$shimPath  = Join-Path $scriptDir "run-daily-updater-staging.ps1"

# Ensure shim exists (pulls latest updater on each run)
if (-not (Test-Path $scriptDir)) { New-Item -ItemType Directory -Path $scriptDir | Out-Null }
if (-not (Test-Path $shimPath)) {
@'
# run-daily-updater-staging.ps1
try {
    Invoke-Expression (Invoke-WebRequest -Uri "https://raw.githubusercontent.com/Care-AI-Inc/careai-corina-service-staging-releases/main/daily-updater.ps1" -UseBasicParsing).Content
} catch {
    "`n[$(Get-Date)] ❌ Failed to fetch and run latest updater: $_" | Out-File -Append "C:\Scripts\samantha-update-log.txt"
}
'@ | Set-Content -Path $shimPath -Encoding UTF8
}

try {
    if (Get-ScheduledTask -TaskName $oldTaskName -ErrorAction SilentlyContinue) {
        $oldTask = Get-ScheduledTask -TaskName $oldTaskName
        $action  = $oldTask.Actions[0]
        $trigs   = $oldTask.Triggers
        Unregister-ScheduledTask -TaskName $oldTaskName -Confirm:$false
        $principal = New-ScheduledTaskPrincipal -UserId "SYSTEM" -LogonType ServiceAccount -RunLevel Highest
        Register-ScheduledTask -TaskName $newTaskName -Action $action -Trigger $trigs -Principal $principal | Out-Null
    } elseif (-not (Get-ScheduledTask -TaskName $newTaskName -ErrorAction SilentlyContinue)) {
        $action    = New-ScheduledTaskAction -Execute "powershell.exe" -Argument "-File `"$shimPath`""
        $principal = New-ScheduledTaskPrincipal -UserId "SYSTEM" -LogonType ServiceAccount -RunLevel Highest
        $trigs = @(
            New-ScheduledTaskTrigger -Daily -At 7am,
            New-ScheduledTaskTrigger -Daily -At 9am,
            New-ScheduledTaskTrigger -Daily -At 11am,
            New-ScheduledTaskTrigger -Daily -At 1pm,
            New-ScheduledTaskTrigger -Daily -At 3pm,
            New-ScheduledTaskTrigger -Daily -At 5pm
        )
        Register-ScheduledTask -TaskName $newTaskName -Action $action -Trigger $trigs -Principal $principal | Out-Null
    }

    # Ensure desired additional times exist (idempotent)
    $desiredTimes = @("07:00", "09:00", "11:00", "13:00", "15:00", "17:00")
    $existingTask = Get-ScheduledTask -TaskName $newTaskName -ErrorAction Stop
    $existingTimes = $existingTask.Triggers | ForEach-Object {
        try { ([DateTime]::Parse($_.StartBoundary)).ToString("HH:mm") } catch { $null }
    } | Where-Object { $_ }

    $missingTimes = $desiredTimes | Where-Object { $_ -notin $existingTimes }
    if ($missingTimes.Count -gt 0) {
        $newTriggers = @($existingTask.Triggers)
        foreach ($time in $missingTimes) {
            $dt = [datetime]::ParseExact($time, "HH:mm", $null)
            $newTriggers += New-ScheduledTaskTrigger -Daily -At $dt
        }
        Set-ScheduledTask -TaskName $newTaskName -Trigger $newTriggers
    }
}
catch {
    "[$(Get-Date)] ❌ Scheduled task migration/ensure failed: $_" | Out-File -Append $logPath
}
