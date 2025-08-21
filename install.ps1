# Ensure Admin
if (-not ([Security.Principal.WindowsPrincipal] `
    [Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole(`
    [Security.Principal.WindowsBuiltInRole] "Administrator")) {
    Write-Error "❌ You must run this script as Administrator."
    exit 1
}
Write-Host "✅ Running as Administrator (Staging Installer)"

# Get latest staging release from GitHub API
$repo   = "Care-AI-Inc/careai-corina-service-staging-releases"
$apiUrl = "https://api.github.com/repos/$repo/releases/latest"
$headers = @{ "User-Agent" = "SamanthaUploaderStagingInstaller" }

try {
    $response = Invoke-RestMethod -Uri $apiUrl -Headers $headers
    $latestTag = $response.tag_name
    $zipAsset  = $response.assets | Where-Object { $_.name -like '*.zip' } | Select-Object -First 1
    $zipUrl    = $zipAsset.browser_download_url
    $zipName   = $zipAsset.name
} catch {
    Write-Error "❌ Failed to fetch staging release or asset info from GitHub"
    exit 1
}

Write-Host "⬇ Downloading staging ZIP: $zipName from $zipUrl"
$zipPath = "$env:TEMP\$zipName"
Invoke-WebRequest -Uri $zipUrl -OutFile $zipPath

# Install paths (keep folder name to avoid breaking paths/permissions)
$installDir  = Join-Path ${env:ProgramFiles} "CorinaService_Staging"
$exePath     = Join-Path $installDir "careai-corina-service.exe"

# Service names
$newServiceName = "SamanthaUploader_Staging"
$oldServiceName = "CorinaService_Staging"

# Stop and remove old/new to ensure clean state (idempotent)
foreach ($svc in @($newServiceName, $oldServiceName)) {
    if (Get-Service -Name $svc -ErrorAction SilentlyContinue) {
        Write-Host "🛑 Stopping existing service $svc..."
        Stop-Service -Name $svc -Force -ErrorAction SilentlyContinue
        Start-Sleep -Seconds 2
        Write-Host "🧹 Deleting service $svc..."
        sc.exe delete $svc | Out-Null
        Start-Sleep -Seconds 2
    }
}

# Kill any lingering process just in case
Get-Process careai-corina-service -ErrorAction SilentlyContinue | Stop-Process -Force
Start-Sleep -Seconds 1

# Replace install folder
if (Test-Path $installDir) {
    try {
        Write-Host "🧼 Removing old install directory: $installDir"
        Remove-Item -Recurse -Force $installDir
    } catch {
        Write-Warning "⚠️ Could not fully delete $installDir, retrying in 5 seconds..."
        Start-Sleep -Seconds 5
        Remove-Item -Recurse -Force $installDir -ErrorAction SilentlyContinue
    }
}
Expand-Archive -Path $zipPath -DestinationPath $installDir

if (-not (Test-Path $exePath)) {
    Write-Error "❌ Failed to find service executable at $exePath"
    exit 1
}

# Register the NEW service (name change)
sc.exe create $newServiceName binPath= "`"$exePath`"" start= auto DisplayName= "Samantha Uploader (Staging)"

# Configure recovery options
Write-Host "🔁 Configuring service recovery options for Staging..."
sc.exe failure    $newServiceName reset= 86400 actions= restart/5000/restart/5000/restart/5000 | Out-Null
sc.exe failureflag $newServiceName 1 | Out-Null
Write-Host "✅ Service will auto-restart on failure (3x retries, 5s wait, reset every 1 day)"

# Start the service
Start-Service -Name $newServiceName
Write-Host "🎉 Samantha Uploader (Staging) installed and started successfully!"

# === [ Setup Dynamic Daily Auto-Updater ] ===
$scriptDir   = "C:\Scripts"
$newShimPath = "$scriptDir\run-daily-updater-staging.ps1"   # keep filename to avoid ACL surprises
$oldShimPath = "$scriptDir\run-daily-updater-corina.ps1"    # if you had an older name, remove it
$taskName    = "SamanthaDailyUpdater"
$oldTaskName = "CorinaDailyUpdater"

if (-not (Test-Path $scriptDir)) {
    New-Item -ItemType Directory -Path $scriptDir | Out-Null
}

# Clean up any legacy shim
if (Test-Path $oldShimPath) {
    Remove-Item $oldShimPath -Force -ErrorAction SilentlyContinue
}

# Write/overwrite the shim (dynamic fetcher)
@'
# run-daily-updater-staging.ps1
try {
    Invoke-Expression (Invoke-WebRequest -Uri "https://raw.githubusercontent.com/Care-AI-Inc/careai-corina-service-staging-releases/main/daily-updater.ps1" -UseBasicParsing).Content
} catch {
    "`n[$(Get-Date)] ❌ Failed to fetch and run latest updater: $_" | Out-File -Append "C:\Scripts\corina-update-log.txt"
}
'@ | Set-Content -Path $newShimPath -Encoding UTF8

Write-Host "🔧 Setting up scheduled task: $taskName"
$action    = New-ScheduledTaskAction -Execute "powershell.exe" -Argument "-File `"$newShimPath`""
$principal = New-ScheduledTaskPrincipal -UserId "SYSTEM" -LogonType ServiceAccount -RunLevel Highest

# Remove legacy task if present
if (Get-ScheduledTask -TaskName $oldTaskName -ErrorAction SilentlyContinue) {
    Write-Host "🗑 Removing old scheduled task '$oldTaskName'"
    Unregister-ScheduledTask -TaskName $oldTaskName -Confirm:$false
    Start-Sleep -Seconds 1
}

# Triggers at 7,9,11,13,15,17
$trigger1 = New-ScheduledTaskTrigger -Daily -At 7am
$trigger2 = New-ScheduledTaskTrigger -Daily -At 9am
$trigger3 = New-ScheduledTaskTrigger -Daily -At 11am
$trigger4 = New-ScheduledTaskTrigger -Daily -At 1pm
$trigger5 = New-ScheduledTaskTrigger -Daily -At 3pm
$trigger6 = New-ScheduledTaskTrigger -Daily -At 5pm

# Delete existing new-named task if found (idempotent)
if (Get-ScheduledTask -TaskName $taskName -ErrorAction SilentlyContinue) {
    Unregister-ScheduledTask -TaskName $taskName -Confirm:$false
    Start-Sleep -Seconds 1
}

Register-ScheduledTask -TaskName $taskName -Action $action -Trigger $trigger1, $trigger2, $trigger3, $trigger4, $trigger5, $trigger6 -Principal $principal
Write-Host "📅 Scheduled task '$taskName' created with 6 triggers: 7AM, 9AM, 11AM, 1PM, 3PM, 5PM"
