# Ensure Admin
if (-not ([Security.Principal.WindowsPrincipal] `
    [Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole(`
    [Security.Principal.WindowsBuiltInRole] "Administrator")) {
    Write-Error "❌ You must run this script as Administrator."
    exit 1
}

Write-Host "✅ Running as Administrator"

# Get latest release from GitHub API
$repo = "Care-AI-Inc/careai-corina-service-staging-releases"
$apiUrl = "https://api.github.com/repos/$repo/releases/latest"
$headers = @{ "User-Agent" = "CorinaServiceInstaller" }

try {
    $response = Invoke-RestMethod -Uri $apiUrl -Headers $headers
    $latestTag = $response.tag_name
    $zipAsset = $response.assets | Where-Object { $_.name -like '*.zip' } | Select-Object -First 1
    $zipUrl = $zipAsset.browser_download_url
    $zipName = $zipAsset.name
} catch {
    Write-Error "❌ Failed to fetch release or asset info from GitHub"
    exit 1
}

Write-Host "⬇ Downloading $zipName from $zipUrl"

# Download the ZIP
$zipPath = "$env:TEMP\$zipName"
Invoke-WebRequest -Uri $zipUrl -OutFile $zipPath

# Extract to Program Files
$installDir = Join-Path ${env:ProgramFiles} "CorinaService"
if (Test-Path $installDir) { Remove-Item -Recurse -Force $installDir }
Expand-Archive -Path $zipPath -DestinationPath $installDir

# Install as Windows Service
$exePath = Join-Path $installDir "careai-corina-service.exe"
$serviceName = "CorinaService"

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

# Register service
sc.exe create $serviceName binPath= "`"$exePath`"" start= auto DisplayName= "Corina Service"

# Start service
Start-Service -Name $serviceName

Write-Host "🎉 Corina Service installed and started successfully!"
