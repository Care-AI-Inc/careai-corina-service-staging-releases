# install.ps1

# Ensure Admin
if (-not ([Security.Principal.WindowsPrincipal] `
    [Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole(`
    [Security.Principal.WindowsBuiltInRole] "Administrator")) {
    Write-Error "❌ You must run this script as Administrator."
    exit 1
}

Write-Host "✅ Running as Administrator"

# Ensure GitHub CLI
if (-not (Get-Command gh -ErrorAction SilentlyContinue)) {
    Write-Host "📦 GitHub CLI not found. Installing..."

    $msiPath = "$env:TEMP\gh.msi"
    Invoke-WebRequest -Uri https://github.com/cli/cli/releases/download/v2.50.0/gh_2.50.0_windows_amd64.msi -OutFile $msiPath

    Start-Process msiexec.exe -Wait -ArgumentList "/i `"$msiPath`" /quiet"

    # Reload PATH so gh is found immediately
    $env:Path = [System.Environment]::GetEnvironmentVariable("Path", "Machine") + ";" +
                [System.Environment]::GetEnvironmentVariable("Path", "User")

    if (-not (Get-Command gh -ErrorAction SilentlyContinue)) {
        Write-Error "❌ GitHub CLI install failed or not found in PATH"
        exit 1
    }

    Write-Host "✅ GitHub CLI installed"
} else {
    Write-Host "✅ GitHub CLI found"
}

# Fetch latest staging release tag
$repo = "Care-AI-Inc/careai-corina-service-staging-releases"
$latestTag = gh release list --repo $repo --limit 1 | ForEach-Object { ($_ -split "\s+")[0] }

if (-not $latestTag) {
    Write-Error "❌ Failed to get latest release tag"
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
