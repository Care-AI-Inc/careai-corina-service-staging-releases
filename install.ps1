# install.ps1

# Ensure Admin
if (-not ([Security.Principal.WindowsPrincipal] `
    [Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole(`
    [Security.Principal.WindowsBuiltInRole] "Administrator")) {
    Write-Error "❌ You must run this script as Administrator."
    exit 1
}

Write-Host "✅ Running as Administrator"

# Fetch latest staging release tag via GitHub API
$repo = "Care-AI-Inc/careai-corina-service-staging-releases"
$latestReleaseApi = "https://api.github.com/repos/$repo/releases/latest"
$headers = @{ "User-Agent" = "CorinaServiceInstaller" }

try {
    $response = Invoke-RestMethod -Uri $latestReleaseApi -Headers $headers
    $latestTag = $response.tag_name
} catch {
    Write-Error "❌ Failed to get latest release info from GitHub API"
    exit 1
}

Write-Host "⬇ Downloading release $latestTag from $repo"

# Download the ZIP
$zipName = "$latestTag.zip"
$zipUrl = "https://github.com/$repo/releases/download/$latestTag/$zipName"
$zipPath = "$env:TEMP\$zipName"

Invoke-WebRequest -Uri $zipUrl -OutFile $zipPath

# Extract to Program Files
$installDir = Join-Path ${env:ProgramFiles} "CorinaService"
if (Test-Path $installDir) { Remove-Item -Recurse -Force $installDir }
Expand-Archive -Path $zipPath -DestinationPath $installDir

# Install as Windows Service
$exePath = Join-Path $installDir "careai-corina-service.exe"
$serviceName = "CorinaService"

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
