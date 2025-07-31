# daily-updater-staging.ps1

# Ensure Admin (optional but helpful if run manually)
if (-not ([Security.Principal.WindowsPrincipal] `
    [Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole(`
    [Security.Principal.WindowsBuiltInRole] "Administrator")) {
    Write-Error "❌ You must run this script as Administrator."
    exit 1
}

# Logging setup
$logPath = "C:\Scripts\corina-update-log.txt"
"[$(Get-Date)] 🔄 Starting Corina Staging update..." | Out-File -Append $logPath

$repo = "Care-AI-Inc/careai-corina-service-staging-releases"
$apiUrl = "https://api.github.com/repos/$repo/releases/latest"
$headers = @{ "User-Agent" = "CorinaServiceStagingUpdater" }

try {
    $response = Invoke-RestMethod -Uri $apiUrl -Headers $headers
    $zipAsset = $response.assets | Where-Object { $_.name -like '*.zip' } | Select-Object -First 1
    $zipUrl = $zipAsset.browser_download_url
    $zipName = $zipAsset.name

    $tempZip = "$env:TEMP\$zipName"
    $extractDir = "$env:TEMP\CorinaStagingExtract"

    # Download ZIP
    Invoke-WebRequest -Uri $zipUrl -OutFile $tempZip

    # Clean and prepare temp extract dir
    if (Test-Path $extractDir) { Remove-Item -Recurse -Force $extractDir }
    Expand-Archive -Path $tempZip -DestinationPath $extractDir

    # Stop service
    $serviceName = "CorinaService_Staging"
    if (Get-Service -Name $serviceName -ErrorAction SilentlyContinue) {
        Stop-Service -Name $serviceName -Force
        Start-Sleep -Seconds 2
    }

    # Overwrite install folder
    $installDir = Join-Path ${env:ProgramFiles} "CorinaService_Staging"
    Copy-Item -Path "$extractDir\*" -Destination $installDir -Recurse -Force

    # Restart service
    Start-Service -Name $serviceName

    "[$(Get-Date)] ✅ Corina Service (Staging) updated and restarted." | Out-File -Append $logPath
}
catch {
    "[$(Get-Date)] ❌ Update failed: $_" | Out-File -Append $logPath
}

# === Ensure Scheduled Task has all desired run times ===
$taskName = "CorinaDailyUpdater"

# Desired times in 24h format
$desiredTimes = @("07:00", "09:00", "11:00", "13:00", "15:00", "17:00")

try {
    $existingTask = Get-ScheduledTask -TaskName $taskName -ErrorAction Stop
    $existingTriggers = $existingTask.Triggers

    # Get current times (hh:mm) from triggers
    $existingTimes = $existingTriggers | ForEach-Object {
        ([DateTime]::Parse($_.StartBoundary)).ToString("HH:mm")
    }

    # Find times that are missing
    $missingTimes = $desiredTimes | Where-Object { $_ -notin $existingTimes }

    if ($missingTimes.Count -gt 0) {
        Write-Host "🕐 Adding missing schedule times: $($missingTimes -join ', ')"

        # Keep old triggers + add new ones
        $newTriggers = @($existingTriggers)
        foreach ($time in $missingTimes) {
            $dt = [datetime]::ParseExact($time, "HH:mm", $null)
            $newTriggers += New-ScheduledTaskTrigger -Daily -At $dt
        }

        # Set updated triggers
        Set-ScheduledTask -TaskName $taskName -Trigger $newTriggers
        Write-Host "✅ Updated triggers for '$taskName'."
    }
    else {
        Write-Host "✅ All desired trigger times already exist. No update needed."
    }
}
catch {
    Write-Error "❌ Could not check or update '$taskName': $_"
}
