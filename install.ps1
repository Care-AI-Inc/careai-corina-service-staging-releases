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
if (Test-Path $installDir) { Remove-Item -Recurse -Force $installDir }
Expand-Archive -Path $zipPath -DestinationPath $installDir

# Install as Windows Service (Staging version)
$exePath = Join-Path $installDir "careai-corina-service.exe"
$serviceName = "CorinaService_Staging"

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

# Start the service
Start-Service -Name $serviceName

Write-Host "🎉 Corina Service (Staging) installed and started successfully!"

# === [ Setup Daily Auto-Updater ] ===
$scriptDir = "C:\Scripts"
$scriptPath = "$scriptDir\daily-updater.ps1"
$taskName = "CorinaDailyUpdater"

# Ensure folder
if (-not (Test-Path $scriptDir)) {
    New-Item -ItemType Directory -Path $scriptDir | Out-Null
}

# Download updater script
Invoke-WebRequest `
  -Uri "https://raw.githubusercontent.com/Care-AI-Inc/careai-corina-service-staging-releases/main/daily-updater.ps1" `
  -OutFile "C:\Scripts\daily-updater.ps1" `
  -Headers @{ "User-Agent" = "CorinaInstaller" }

# Register scheduled task (runs daily at 7 AM)
$action = New-ScheduledTaskAction -Execute "powershell.exe" -Argument "-File `"$scriptPath`""
$trigger = New-ScheduledTaskTrigger -Daily -At 7am
$principal = New-ScheduledTaskPrincipal -UserId "SYSTEM" -LogonType ServiceAccount -RunLevel Highest

# Remove old task if exists
if (Get-ScheduledTask -TaskName $taskName -ErrorAction SilentlyContinue) {
    Unregister-ScheduledTask -TaskName $taskName -Confirm:$false
}

Register-ScheduledTask -TaskName $taskName -Action $action -Trigger $trigger -Principal $principal

Write-Host "📅 Scheduled task '$taskName' created to run daily at 7 AM"
