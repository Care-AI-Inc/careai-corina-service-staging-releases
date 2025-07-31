# Ensure Admin
if (-not ([Security.Principal.WindowsPrincipal] `
    [Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole(`
    [Security.Principal.WindowsBuiltInRole] "Administrator")) {
    Write-Error "❌ You must run this script as Administrator."
    exit 1
}

Write-Host "✅ Running as Administrator (Staging Installer)"

# Get latest staging release from GitHub API
$repo = "Care-AI-Inc/careai-corina-service-staging-releases"
$apiUrl = "https://api.github.com/repos/$repo/releases/latest"
$headers = @{ "User-Agent" = "CorinaServiceStagingInstaller" }

try {
    $response = Invoke-RestMethod -Uri $apiUrl -Headers $headers
    $latestTag = $response.tag_name
    $zipAsset = $response.assets | Where-Object { $_.name -like '*.zip' } | Select-Object -First 1
    $zipUrl = $zipAsset.browser_download_url
    $zipName = $zipAsset.name
} catch {
    Write-Error "❌ Failed to fetch staging release or asset info from GitHub"
    exit 1
}

Write-Host "⬇ Downloading staging ZIP: $zipName from $zipUrl"

# Download the ZIP
$zipPath = "$env:TEMP\$zipName"
Invoke-WebRequest -Uri $zipUrl -OutFile $zipPath

# Extract to Program Files (Staging Path)
$installDir = Join-Path ${env:ProgramFiles} "CorinaService_Staging"
$serviceName = "CorinaService_Staging"

# Stop and remove old service if exists
if (Get-Service -Name $serviceName -ErrorAction SilentlyContinue) {
    Write-Host "🛑 Stopping existing service..."
    Stop-Service -Name $serviceName -Force -ErrorAction SilentlyContinue
    Start-Sleep -Seconds 2

    Write-Host "🧹 Deleting existing service..."
    sc.exe delete $serviceName | Out-Null
    Start-Sleep -Seconds 2

    # Kill any lingering process just in case
    Get-Process careai-corina-service -ErrorAction SilentlyContinue | Stop-Process -Force
    Start-Sleep -Seconds 1
}

# Attempt to delete old install folder
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

# Install as Windows Service (Staging version)
$exePath = Join-Path $installDir "careai-corina-service.exe"

if (-not (Test-Path $exePath)) {
    Write-Error "❌ Failed to find service executable at $exePath"
    exit 1
}

# Remove old service if exists
if (Get-Service -Name $serviceName -ErrorAction SilentlyContinue) {
    Stop-Service -Name $serviceName -Force
    sc.exe delete $serviceName | Out-Null
    Start-Sleep -Seconds 2
}

# Register the staging service
sc.exe create $serviceName binPath= "`"$exePath`"" start= auto DisplayName= "Corina Service (Staging)"

# Set recovery options to auto-restart service on crash
Write-Host "🔁 Configuring service recovery options for Staging..."
sc.exe failure $serviceName reset= 86400 actions= restart/5000/restart/5000/restart/5000 | Out-Null
sc.exe failureflag $serviceName 1 | Out-Null
Write-Host "✅ Service will auto-restart on failure (3x retries, 5s wait, reset every 1 day)"

# Start the service
Start-Service -Name $serviceName

Write-Host "🎉 Corina Service (Staging) installed and started successfully!"

# === [ Setup Dynamic Daily Auto-Updater ] ===
$scriptDir = "C:\Scripts"
$shimPath = "$scriptDir\run-daily-updater-staging.ps1"
$taskName = "CorinaDailyUpdater"

# Ensure script folder exists
if (-not (Test-Path $scriptDir)) {
    New-Item -ItemType Directory -Path $scriptDir | Out-Null
}

# Write the shim (dynamic fetcher)
@'
# run-daily-updater-staging.ps1
try {
    Invoke-Expression (Invoke-WebRequest -Uri "https://raw.githubusercontent.com/Care-AI-Inc/careai-corina-service-staging-releases/main/daily-updater.ps1" -UseBasicParsing).Content
} catch {
    "`n[$(Get-Date)] ❌ Failed to fetch and run latest updater: $_" | Out-File -Append "C:\Scripts\corina-update-log.txt"
}
'@ | Set-Content -Path $shimPath -Encoding UTF8

# Register scheduled task (runs at 7am, 9am, 11am, 1pm, 3pm, and 5pm)
Write-Host "🔧 Setting up scheduled task: $taskName"

# Define action
$action = New-ScheduledTaskAction -Execute "powershell.exe" -Argument "-File `"$shimPath`""

# Define 6 separate time triggers
$triggers = @(
    (New-ScheduledTaskTrigger -Daily -At ([datetime]::Parse("07:00 AM"))),
    (New-ScheduledTaskTrigger -Daily -At ([datetime]::Parse("09:00 AM"))),
    (New-ScheduledTaskTrigger -Daily -At ([datetime]::Parse("11:00 AM"))),
    (New-ScheduledTaskTrigger -Daily -At ([datetime]::Parse("01:00 PM"))),
    (New-ScheduledTaskTrigger -Daily -At ([datetime]::Parse("03:00 PM"))),
    (New-ScheduledTaskTrigger -Daily -At ([datetime]::Parse("05:00 PM")))
)

# Run as SYSTEM
$principal = New-ScheduledTaskPrincipal -UserId "SYSTEM" -LogonType ServiceAccount -RunLevel Highest

# Delete existing task if found
if (Get-ScheduledTask -TaskName $taskName -ErrorAction SilentlyContinue) {
    Write-Host "🗑 Removing old scheduled task '$taskName'"
    Unregister-ScheduledTask -TaskName $taskName -Confirm:$false
    Start-Sleep -Seconds 1
}

# Register with all 6 triggers
Register-ScheduledTask -TaskName $taskName -Action $action -Trigger $triggers -Principal $principal

Write-Host "📅 Scheduled task '$taskName' created with 6 triggers: 7AM, 9AM, 11AM, 1PM, 3PM, 5PM"
