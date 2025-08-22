# install-samantha-uploader-staging.ps1
# Purpose: Clean install or migrate from Corina → Samantha Uploader (Staging) with new service/folder/task names.

# =========================
# Admin Check
# =========================
if (-not ([Security.Principal.WindowsPrincipal] `
    [Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole(`
    [Security.Principal.WindowsBuiltInRole] "Administrator")) {
    Write-Error "❌ You must run this script as Administrator."
    exit 1
}
Write-Host "✅ Running as Administrator (Samantha Uploader - Staging Installer)"

# =========================
# Release Source (unchanged repo/artifacts)
# =========================
$repo   = "Care-AI-Inc/careai-corina-service-staging-releases"
$apiUrl = "https://api.github.com/repos/$repo/releases/latest"
$headers = @{ "User-Agent" = "SamanthaUploaderStagingInstaller" }

try {
    $response = Invoke-RestMethod -Uri $apiUrl -Headers $headers
    $zipAsset = $response.assets | Where-Object { $_.name -like '*.zip' } | Select-Object -First 1
    if (-not $zipAsset) { throw "No .zip asset found in latest release." }
    $zipUrl  = $zipAsset.browser_download_url
    $zipName = $zipAsset.name
} catch {
    Write-Error "❌ Failed to fetch staging release or asset info from GitHub: $_"
    exit 1
}

Write-Host "⬇ Downloading staging ZIP: $zipName"
$zipPath    = Join-Path $env:TEMP $zipName
$extractDir = Join-Path $env:TEMP "SamanthaStagingExtract"
Invoke-WebRequest -Uri $zipUrl -OutFile $zipPath

# =========================
# Names and Paths
# =========================
$newServiceName = "SamanthaUploader_Staging"
$oldServiceName = "CorinaService_Staging"

$newTaskName    = "SamanthaDailyUpdater"
$oldTaskName    = "CorinaDailyUpdater"

$exeName        = "careai-corina-service.exe"  # keep current exe name; change later when your releases do
$newInstallDir  = Join-Path ${env:ProgramFiles} "SamanthaUploader_Staging"
$oldInstallDir  = Join-Path ${env:ProgramFiles} "CorinaService_Staging"
$exePath        = Join-Path $newInstallDir $exeName

# =========================
# Stop and remove services to ensure a clean state (idempotent)
# =========================
foreach ($svc in @($newServiceName, $oldServiceName)) {
    if (Get-Service -Name $svc -ErrorAction SilentlyContinue) {
        Write-Host "🛑 Stopping service $svc..."
        Stop-Service -Name $svc -Force -ErrorAction SilentlyContinue
        Start-Sleep -Seconds 2
        Write-Host "🧹 Deleting service $svc..."
        sc.exe delete $svc | Out-Null
        Start-Sleep -Seconds 2
    }
}
# Best-effort kill of lingering process
Get-Process careai-corina-service -ErrorAction SilentlyContinue | Stop-Process -Force
Start-Sleep -Seconds 1

# =========================
# Prepare directories and migration copy (old → new) once
# =========================
if (Test-Path $extractDir) { Remove-Item -Recurse -Force $extractDir }
Expand-Archive -Path $zipPath -DestinationPath $extractDir

if (-not (Test-Path $newInstallDir)) {
    New-Item -ItemType Directory -Path $newInstallDir -Force | Out-Null
    if (Test-Path $oldInstallDir) {
        Write-Host "📦 Migrating existing files from old folder to new folder..."
        $rc = robocopy $oldInstallDir $newInstallDir /E /COPYALL /R:2 /W:2 /NFL /NDL /NP /NJH /NJS
        if ($LASTEXITCODE -gt 8) { Write-Warning "⚠️ Robocopy (old→new) reported code $LASTEXITCODE" }
    }
}

Write-Host "📥 Copying new release files into $newInstallDir ..."
$rc2 = robocopy $extractDir $newInstallDir /E /R:2 /W:2 /NFL /NDL /NP /NJH /NJS
if ($LASTEXITCODE -gt 8) { Write-Warning "⚠️ Robocopy (extract→install) reported code $LASTEXITCODE" }

if (-not (Test-Path $exePath)) {
    Write-Error "❌ Failed to find service executable at $exePath"
    exit 1
}

# =========================
# Register new service and configure recovery
# =========================
Write-Host "🆕 Creating Windows service: $newServiceName"
sc.exe create $newServiceName binPath= "`"$exePath`"" start= auto DisplayName= "Samantha Uploader (Staging)" | Out-Null
sc.exe failure     $newServiceName reset= 86400 actions= restart/5000/restart/5000/restart/5000 | Out-Null
sc.exe failureflag $newServiceName 1 | Out-Null

# Start and verify
Start-Service -Name $newServiceName
Start-Sleep -Seconds 3
$svc = Get-Service -Name $newServiceName -ErrorAction Stop
if ($svc.Status -ne 'Running') {
    Write-Error "❌ New service failed to start (status: $($svc.Status)). Aborting."
    exit 1
}
Write-Host "✅ Service '$newServiceName' is running."

# =========================
# Scheduled Task: remove old, create new
# =========================
$scriptDir = "C:\Scripts"
$newShimPath = Join-Path $scriptDir "run-daily-updater-staging.ps1"
$logPath = Join-Path $scriptDir "samantha-update-log.txt"

if (-not (Test-Path $scriptDir)) { New-Item -ItemType Directory -Path $scriptDir | Out-Null }

# Remove legacy shim if you had a different name
$oldShimPath = Join-Path $scriptDir "run-daily-updater-corina.ps1"
if (Test-Path $oldShimPath) {
    Remove-Item $oldShimPath -Force -ErrorAction SilentlyContinue
}

# Write/overwrite shim (pulls latest updater every run)
@'
# run-daily-updater-staging.ps1
try {
    Invoke-Expression (Invoke-WebRequest -Uri "https://raw.githubusercontent.com/Care-AI-Inc/careai-corina-service-staging-releases/main/daily-updater.ps1" -UseBasicParsing).Content
} catch {
    "`n[$(Get-Date)] ❌ Failed to fetch and run latest updater: $_" | Out-File -Append "C:\Scripts\samantha-update-log.txt"
}
'@ | Set-Content -Path $newShimPath -Encoding UTF8

# Remove legacy task if present
if (Get-ScheduledTask -TaskName $oldTaskName -ErrorAction SilentlyContinue) {
    Write-Host "🗑 Removing old scheduled task '$oldTaskName'"
    Unregister-ScheduledTask -TaskName $oldTaskName -Confirm:$false
    Start-Sleep -Seconds 1
}

# Define action/principal/triggers
$action    = New-ScheduledTaskAction -Execute "powershell.exe" -Argument "-File `"$newShimPath`""
$principal = New-ScheduledTaskPrincipal -UserId "SYSTEM" -LogonType ServiceAccount -RunLevel Highest
$trigger1  = New-ScheduledTaskTrigger -Daily -At 7am
$trigger2  = New-ScheduledTaskTrigger -Daily -At 9am
$trigger3  = New-ScheduledTaskTrigger -Daily -At 11am
$trigger4  = New-ScheduledTaskTrigger -Daily -At 1pm
$trigger5  = New-ScheduledTaskTrigger -Daily -At 3pm
$trigger6  = New-ScheduledTaskTrigger -Daily -At 5pm

# Delete existing new-named task if present (idempotent create)
if (Get-ScheduledTask -TaskName $newTaskName -ErrorAction SilentlyContinue) {
    Unregister-ScheduledTask -TaskName $newTaskName -Confirm:$false
    Start-Sleep -Seconds 1
}

Register-ScheduledTask -TaskName $newTaskName -Action $action -Trigger $trigger1, $trigger2, $trigger3, $trigger4, $trigger5, $trigger6 -Principal $principal
Write-Host "📅 Scheduled task '$newTaskName' created with 6 triggers."

# =========================
# Clean up old install folder (safe to remove now)
# =========================
if (Test-Path $oldInstallDir) {
    try {
        Write-Host "🧼 Removing old install directory: $oldInstallDir"
        Remove-Item -Recurse -Force $oldInstallDir
    } catch {
        Write-Warning "⚠️ Could not fully delete $oldInstallDir; you can remove it later."
    }
}

Write-Host "🎉 Samantha Uploader (Staging) installed and configured successfully!"
