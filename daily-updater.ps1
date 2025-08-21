# daily-updater-staging.ps1

# Ensure Admin (optional but helpful if run manually)
if (-not ([Security.Principal.WindowsPrincipal] `
    [Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole(`
    [Security.Principal.WindowsBuiltInRole] "Administrator")) {
    Write-Error "❌ You must run this script as Administrator."
    exit 1
}

# Logging setup (keep same file to preserve history)
$logPath = "C:\Scripts\corina-update-log.txt"
"[$(Get-Date)] 🔄 Starting Samantha Uploader (Staging) update..." | Out-File -Append $logPath

$repo   = "Care-AI-Inc/careai-corina-service-staging-releases"
$apiUrl = "https://api.github.com/repos/$repo/releases/latest"
$headers = @{ "User-Agent" = "SamanthaUploaderStagingUpdater" }

try {
    $response = Invoke-RestMethod -Uri $apiUrl -Headers $headers
    $zipAsset = $response.assets | Where-Object { $_.name -like '*.zip' } | Select-Object -First 1
    $zipUrl   = $zipAsset.browser_download_url
    $zipName  = $zipAsset.name

    $tempZip   = "$env:TEMP\$zipName"
    $extractDir = "$env:TEMP\CorinaStagingExtract"  # keep same temp dir; harmless

    # Download ZIP
    Invoke-WebRequest -Uri $zipUrl -OutFile $tempZip

    # Clean and prepare temp extract dir
    if (Test-Path $extractDir) { Remove-Item -Recurse -Force $extractDir }
    Expand-Archive -Path $tempZip -DestinationPath $extractDir

    # Service names (new then legacy)
    $newServiceName = "SamanthaUploader_Staging"
    $oldServiceName = "CorinaService_Staging"

    # Stop whichever service exists
    $svcToStop = Get-Service -Name $newServiceName -ErrorAction SilentlyContinue
    if (-not $svcToStop) { $svcToStop = Get-Service -Name $oldServiceName -ErrorAction SilentlyContinue }
    if ($svcToStop) {
        Stop-Service -Name $svcToStop.Name -Force
        Start-Sleep -Seconds 2
    }

    # Overwrite install folder (keep same path so we don't break anything)
    $installDir = Join-Path ${env:ProgramFiles} "CorinaService_Staging"
    Copy-Item -Path "$extractDir\*" -Destination $installDir -Recurse -Force

    # Prefer starting the new service if present, else start legacy
    if (Get-Service -Name $newServiceName -ErrorAction SilentlyContinue) {
        Start-Service -Name $newServiceName
    } elseif (Get-Service -Name $oldServiceName -ErrorAction SilentlyContinue) {
        Start-Service -Name $oldServiceName
    }

    "[$(Get-Date)] ✅ Samantha Uploader (Staging) updated and service restarted." | Out-File -Append $logPath
}
catch {
    "[$(Get-Date)] ❌ Update failed: $_" | Out-File -Append $logPath
}

# === Ensure Scheduled Task has all desired run times ===
# We are migrating task name: old -> new
$oldTaskName = "CorinaDailyUpdater"
$taskName    = "SamanthaDailyUpdater"

# Desired times in 24h format
$desiredTimes = @("07:00", "09:00", "11:00", "13:00", "15:00", "17:00")

try {
    # If old task exists, clone its triggers, then remove it
    $existingTriggers = $null
    if (Get-ScheduledTask -TaskName $oldTaskName -ErrorAction SilentlyContinue) {
        $oldTask = Get-ScheduledTask -TaskName $oldTaskName
        $existingTriggers = $oldTask.Triggers
        Unregister-ScheduledTask -TaskName $oldTaskName -Confirm:$false
        Write-Host "🗑 Removed legacy task '$oldTaskName'"
    }

    # Create new task if missing
    if (-not (Get-ScheduledTask -TaskName $taskName -ErrorAction SilentlyContinue)) {
        $scriptDir = "C:\Scripts"
        $shimPath  = "$scriptDir\run-daily-updater-staging.ps1"
        if (-not (Test-Path $scriptDir)) { New-Item -ItemType Directory -Path $scriptDir | Out-Null }

        # Ensure shim exists (fetches latest updater from GitHub)
        if (-not (Test-Path $shimPath)) {
@'
# run-daily-updater-staging.ps1
try {
    Invoke-Expression (Invoke-WebRequest -Uri "https://raw.githubusercontent.com/Care-AI-Inc/careai-corina-service-staging-releases/main/daily-updater.ps1" -UseBasicParsing).Content
} catch {
    "`n[$(Get-Date)] ❌ Failed to fetch and run latest updater: $_" | Out-File -Append "C:\Scripts\corina-update-log.txt"
}
'@ | Set-Content -Path $shimPath -Encoding UTF8
        }

        $action    = New-ScheduledTaskAction -Execute "powershell.exe" -Argument "-File `"$shimPath`""
        $principal = New-ScheduledTaskPrincipal -UserId "SYSTEM" -LogonType ServiceAccount -RunLevel Highest

        # Build triggers: use existing if we captured, else standard 6 times
        $triggers = @()
        if ($existingTriggers) {
            $triggers += $existingTriggers
        } else {
            $triggers += New-ScheduledTaskTrigger -Daily -At 7am
            $triggers += New-ScheduledTaskTrigger -Daily -At 9am
            $triggers += New-ScheduledTaskTrigger -Daily -At 11am
            $triggers += New-ScheduledTaskTrigger -Daily -At 1pm
            $triggers += New-ScheduledTaskTrigger -Daily -At 3pm
            $triggers += New-ScheduledTaskTrigger -Daily -At 5pm
        }

        Register-ScheduledTask -TaskName $taskName -Action $action -Trigger $triggers -Principal $principal
        Write-Host "📅 Scheduled task '$taskName' created."
    }

    # Ensure desired times exist on the new task
    $existingTask   = Get-ScheduledTask -TaskName $taskName -ErrorAction Stop
    $existingTimes  = $existingTask.Triggers | ForEach-Object {
        ([DateTime]::Parse($_.StartBoundary)).ToString("HH:mm")
    }
    $missingTimes = $desiredTimes | Where-Object { $_ -notin $existingTimes }

    if ($missingTimes.Count -gt 0) {
        Write-Host "🕐 Adding missing schedule times: $($missingTimes -join ', ')"
        $newTriggers = @($existingTask.Triggers)
        foreach ($time in $missingTimes) {
            $dt = [datetime]::ParseExact($time, "HH:mm", $null)
            $newTriggers += New-ScheduledTaskTrigger -Daily -At $dt
        }
        Set-ScheduledTask -TaskName $taskName -Trigger $newTriggers
        Write-Host "✅ Updated triggers for '$taskName'."
    } else {
        Write-Host "✅ All desired trigger times already exist. No update needed."
    }
}
catch {
    Write-Error "❌ Could not check or update scheduled task: $_"
}
