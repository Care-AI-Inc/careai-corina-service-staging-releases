# install.ps1 (Staging Installer)

$corinaInstallerOutputIndent = [Environment]::GetEnvironmentVariable("CorinaInstallerOutputIndent", [System.EnvironmentVariableTarget]::Process)
if ($null -eq $corinaInstallerOutputIndent) {
    $corinaInstallerOutputIndent = ""
}

function Write-Host {
    param(
        [Parameter(ValueFromRemainingArguments = $true)]
        [object[]]$Object
    )

    $message = if ($Object) { [string]::Join(" ", $Object) } else { "" }
    Microsoft.PowerShell.Utility\Write-Host "$corinaInstallerOutputIndent$message"
}

# =========================
# Admin Check
# =========================
if (-not ([Security.Principal.WindowsPrincipal] `
    [Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole(`
    [Security.Principal.WindowsBuiltInRole] "Administrator")) {
    Write-Error "You must run this script as Administrator."
    exit 1
}
Write-Host "[*] Running as Administrator (Corina Service - Staging)"

# =========================
# Multi-instance bootstrap
# =========================
function Get-CorinaRegistryInstance {
    $instance = [Environment]::GetEnvironmentVariable("CorinaRegistryInstance", [System.EnvironmentVariableTarget]::Process)

    if ([string]::IsNullOrWhiteSpace($instance)) {
        $callerValue = Get-Variable -Name registryInstance -ValueOnly -ErrorAction SilentlyContinue
        if (-not [string]::IsNullOrWhiteSpace([string]$callerValue)) {
            $instance = [string]$callerValue
        }
    }

    if ([string]::IsNullOrWhiteSpace($instance)) {
        return $null
    }

    $instance = $instance.Trim()
    if ($instance -notmatch '^[A-Za-z0-9](?:[A-Za-z0-9_-]*[A-Za-z0-9])?$') {
        throw "Invalid CorinaRegistryInstance '$instance'. Use letters, numbers, hyphen, or underscore."
    }

    $env:CorinaRegistryInstance = $instance
    return $instance
}

function Stop-ServiceProcessByName {
    param([Parameter(Mandatory = $true)][string]$Name)

    try {
        $svc = Get-CimInstance Win32_Service -Filter "Name='$Name'" -ErrorAction SilentlyContinue
        if ($svc -and $svc.ProcessId -and $svc.ProcessId -ne 0) {
            Stop-Process -Id $svc.ProcessId -Force -ErrorAction SilentlyContinue
        }
    } catch { }
}

function Set-CorinaServiceEnvironment {
    param(
        [Parameter(Mandatory = $true)][string]$Name,
        [string]$Instance
    )

    $svcRegPath = "HKLM:\SYSTEM\CurrentControlSet\Services\$Name"
    $values = @("DOTNET_ENVIRONMENT=Staging")
    if (-not [string]::IsNullOrWhiteSpace($Instance)) {
        $values += "CorinaRegistryInstance=$Instance"
    }

    New-ItemProperty -Path $svcRegPath -Name Environment -PropertyType MultiString -Value $values -Force | Out-Null
}

$corinaRegistryInstance = Get-CorinaRegistryInstance
if ($corinaRegistryInstance) {
    Write-Host "    -> Using Corina registry instance: $corinaRegistryInstance"
} else {
    Write-Host "    -> No CorinaRegistryInstance provided; using single-instance staging install."
}

$DefaultSamanthaBaseUrl = "https://backend.staging.caregp.com.au"

# =========================
# Release Source (unchanged repo/artifacts)
# =========================
Write-Host "`n[*] Fetching latest staging release"
$repo   = "Care-AI-Inc/careai-corina-service-staging-releases"
$apiUrl = "https://api.github.com/repos/$repo/releases/latest"
$headers = @{ "User-Agent" = "CorinaServiceInstaller - Staging" }

try {
    $response = Invoke-RestMethod -Uri $apiUrl -Headers $headers
    $zipAsset = $response.assets | Where-Object { $_.name -like '*.zip' } | Select-Object -First 1
    if (-not $zipAsset) { throw "No .zip asset found in latest release." }
    $zipUrl  = $zipAsset.browser_download_url
    $zipName = $zipAsset.name
} catch {
    Write-Error "Failed to fetch staging release or asset info from GitHub: $_"
    exit 1
}

Write-Host "    -> Downloading $zipName from $zipUrl"
$zipPath    = Join-Path $env:TEMP $zipName
try {
    Invoke-WebRequest -Uri $zipUrl -OutFile $zipPath
} catch {
    Write-Error "Failed to download ${zipName}: $_"
    exit 1
}
try { Unblock-File -LiteralPath $zipPath -ErrorAction Stop } catch { }

# =========================
# Names and Paths
# =========================
$exeName        = "careai-corina-service.exe"  # keep current exe name; change later when your releases do
if ($corinaRegistryInstance) {
    $serviceName = "CorinaService-Staging-$corinaRegistryInstance"
    $taskName    = "CorinaStagingDailyUpdater-$corinaRegistryInstance"
    $installDir  = Join-Path (Join-Path ${env:ProgramFiles} "CorinaService-Staging") $corinaRegistryInstance
    $serviceDisplayName = "Corina Service (Staging - $corinaRegistryInstance)"
} else {
    $serviceName = "CorinaService-Staging"
    $taskName    = "CorinaStagingDailyUpdater"
    $installDir  = Join-Path ${env:ProgramFiles} "CorinaService-Staging"
    $serviceDisplayName = "Corina Service (Staging)"
}
$exePath        = Join-Path $installDir $exeName

$regPath = "HKLM:\SOFTWARE\CareAI\CorinaService-Staging"
if ($corinaRegistryInstance) {
    $regPath = Join-Path $regPath $corinaRegistryInstance
}
Write-Host "`n[*] Checking registry configuration"
Write-Host "    -> Registry path: $regPath"
if (Test-Path $regPath) {
    $samanthaBaseUrl = (Get-ItemProperty -Path $regPath -Name "SamanthaBaseUrl" -ErrorAction SilentlyContinue).SamanthaBaseUrl
    if ([string]::IsNullOrWhiteSpace($samanthaBaseUrl)) {
        Set-ItemProperty -Path $regPath -Name "SamanthaBaseUrl" -Value $DefaultSamanthaBaseUrl
        Write-Host "    -> Set default SamanthaBaseUrl: $DefaultSamanthaBaseUrl"
    }

    $token = (Get-ItemProperty -Path $regPath -Name "CorinaAgentToken" -ErrorAction SilentlyContinue).CorinaAgentToken
    if ([string]::IsNullOrWhiteSpace($token)) {
        Write-Warning "CorinaAgentToken is not configured. Regenerate the staging installer script before starting the service."
    }
} else {
    Write-Warning "Registry path $regPath not found; run the generated clinic installer to configure CorinaAgentToken."
}

# =========================
# Extract to a temp staging dir and verify BEFORE touching the live install
# =========================
Write-Host "`n[*] Installing files"
$instanceSuffix = if ($corinaRegistryInstance) { "-$corinaRegistryInstance" } else { "" }
$extractDir = Join-Path $env:TEMP "CorinaServiceStagingExtract$instanceSuffix"
if (Test-Path $extractDir) { Remove-Item -Recurse -Force $extractDir }
Expand-Archive -Path $zipPath -DestinationPath $extractDir

if (-not (Test-Path (Join-Path $extractDir $exeName))) {
    Write-Error "Staged payload is missing '$exeName'; aborting before touching the existing install."
    exit 1
}

# =========================
# Stop and remove services to ensure a clean state (idempotent)
# =========================
foreach ($svc in @($serviceName)) {
    if (Get-Service -Name $svc -ErrorAction SilentlyContinue) {
        Write-Host "    -> Stopping existing service..."
        Stop-Service -Name $svc -Force -ErrorAction SilentlyContinue
        Start-Sleep -Seconds 2
        Write-Host "    -> Deleting existing service..."
        Stop-ServiceProcessByName -Name $svc
        sc.exe delete $svc | Out-Null
        Start-Sleep -Seconds 2
    }
}

# =========================
# Remove old install dir (payload already verified)
# =========================
if (Test-Path $installDir) {
    try {
        Write-Host "    -> Removing old install directory: $installDir"
        Remove-Item -Recurse -Force $installDir -ErrorAction Stop
    } catch {
        Write-Warning "Could not fully delete $installDir, retrying in 5 seconds..."
        Start-Sleep -Seconds 5
        Remove-Item -Recurse -Force $installDir -ErrorAction SilentlyContinue
    }
}

# =========================
# Copy verified files into place
# =========================
Write-Host "    -> Copying new release files into $installDir ..."
New-Item -ItemType Directory -Path $installDir -Force | Out-Null
robocopy $extractDir $installDir /E /R:2 /W:2 /NFL /NDL /NP /NJH /NJS | Out-Null
if ($LASTEXITCODE -ge 8) {
    Write-Error "Failed to copy new files into $installDir (robocopy exit $LASTEXITCODE)."
    exit 1
}
Remove-Item -Recurse -Force $extractDir -ErrorAction SilentlyContinue

if (-not (Test-Path $exePath)) {
    Write-Error "Failed to find service executable at $exePath"
    exit 1
}

# =========================
# Register new service and configure recovery
# =========================
Write-Host "`n[*] Registering Windows service"
Write-Host "    -> Creating Windows service: $serviceName"
sc.exe create $serviceName binPath= "`"$exePath`"" start= auto obj= "LocalSystem" DisplayName= "$serviceDisplayName" | Out-Null
if ($LASTEXITCODE -ne 0) {
    Write-Error "sc.exe create failed for '$serviceName' (exit code $LASTEXITCODE)."
    exit 1
}
Set-CorinaServiceEnvironment -Name $serviceName -Instance $corinaRegistryInstance
Write-Host "    -> Set service environment: DOTNET_ENVIRONMENT=Staging"
if ($corinaRegistryInstance) {
    Write-Host "    -> Set service environment: CorinaRegistryInstance=$corinaRegistryInstance"
}

Write-Host "    -> Configuring service recovery options for Staging..."
sc.exe failure     $serviceName reset= 86400 actions= restart/5000/restart/5000/restart/5000 | Out-Null
sc.exe failureflag $serviceName 1 | Out-Null
Write-Host "    -> Service will auto-restart on failure (5s delay, failure count resets daily)"

# Start and verify
Start-Service -Name $serviceName
Start-Sleep -Seconds 3
$svc = Get-Service -Name $serviceName -ErrorAction Stop
if ($svc.Status -ne 'Running') {
    Write-Error "Service failed to start (status: $($svc.Status)). Aborting."
    exit 1
}
Write-Host "SUCCESS: Corina Service (Staging) installed and started."

# =========================
# Scheduled Task: remove old, create new
# =========================
Write-Host "`n[*] Configuring daily auto-updater"
$scriptDir = "C:\Scripts"
if ($corinaRegistryInstance) {
    $shimPath = Join-Path $scriptDir "run-daily-updater-staging-$corinaRegistryInstance.ps1"
    $legacyShimPath = Join-Path $scriptDir "run-daily-updater-staging.ps1"
    $legacyTaskName = "CorinaStagingDailyUpdater"
} else {
    $shimPath = Join-Path $scriptDir "run-daily-updater-staging.ps1"
    $legacyShimPath = $null
    $legacyTaskName = $null
}

if (-not (Test-Path $scriptDir)) { New-Item -ItemType Directory -Path $scriptDir | Out-Null }
Write-Host "    -> Updater script directory: $scriptDir"

# =========================
# Instance installs must not leave the old single-instance updater running in parallel.
# =========================
if ($legacyTaskName -and (Get-ScheduledTask -TaskName $legacyTaskName -ErrorAction SilentlyContinue)) {
    Write-Host "    -> Removing legacy scheduled task: $legacyTaskName"
    Unregister-ScheduledTask -TaskName $legacyTaskName -Confirm:$false
    Start-Sleep -Seconds 1
}
if ($legacyShimPath -and (Test-Path $legacyShimPath)) {
    Write-Host "    -> Removing legacy updater shim: $legacyShimPath"
    Remove-Item -LiteralPath $legacyShimPath -Force -ErrorAction SilentlyContinue
}

# =========================
# Write shim script that always fetches latest updater.
# Instance/env are written into the shim so manual runs behave like the scheduled task.
# =========================
$shimPrefix = "`$env:DOTNET_ENVIRONMENT = 'Staging'`r`n"
if ($corinaRegistryInstance) {
    $shimPrefix = "`$env:CorinaRegistryInstance = '$corinaRegistryInstance'`r`n$shimPrefix"
}
Write-Host "    -> Writing updater shim: $shimPath"
$shimContent = @'
# run-daily-updater-staging.ps1
# Safer and more reliable version with TLS 1.2, retry logic, and logging.

$ErrorActionPreference = 'Stop'
$_inst   = $env:CorinaRegistryInstance
$LogPath = if ($_inst) { "C:\Scripts\samantha-update-log-$_inst.txt" } else { 'C:\Scripts\samantha-update-log.txt' }
$Url     = 'https://raw.githubusercontent.com/Care-AI-Inc/careai-corina-service-staging-releases/main/daily-updater.ps1'

# 1) Force TLS 1.2 (required for GitHub)
try {
    $proto = [System.Net.ServicePointManager]::SecurityProtocol
    $tls12 = [System.Net.SecurityProtocolType]::Tls12
    if (($proto -band $tls12) -eq 0) {
        [System.Net.ServicePointManager]::SecurityProtocol = $proto -bor $tls12
    }
} catch {
    "`n[$(Get-Date)] Failed to enable TLS 1.2: $_" | Out-File -Append $LogPath
}

# 2) Simple retry helper
function Invoke-WithRetry {
    param(
        [scriptblock]$Action,
        [int]$MaxRetries = 3,
        [int]$DelaySec   = 5
    )
    $attempt = 0
    while ($true) {
        try {
            $attempt++
            return & $Action
        } catch {
            if ($attempt -ge $MaxRetries) { throw }
            Start-Sleep -Seconds $DelaySec
        }
    }
}

# 3) Download, save, and run
try {
    $Headers = @{ 'User-Agent' = 'PowerShell/5.1 CareAI-Updater' }
    $safeInst = if ($_inst) { $_inst } else { 'default' }
    $TmpFile = [System.IO.Path]::Combine([System.IO.Path]::GetTempPath(), "daily-updater-staging-$safeInst.ps1")

    $content = Invoke-WithRetry {
        (Invoke-WebRequest -Uri $Url -Headers $Headers -UseBasicParsing -TimeoutSec 30).Content
    }

    if ([string]::IsNullOrWhiteSpace($content)) {
        throw "Downloaded content is empty."
    }
    if ($content.Length -gt 0 -and $content[0] -eq [char]0xFEFF) {
        $content = $content.Substring(1)
    }

    $content | Set-Content -LiteralPath $TmpFile -Encoding UTF8

    # Run the downloaded script in a new process
    & powershell -NoProfile -ExecutionPolicy Bypass -File $TmpFile
}
catch {
    "`n[$(Get-Date)] Failed to fetch and run latest staging updater: $_" | Out-File -Append $LogPath
    exit 1
}
'@
($shimPrefix + $shimContent) | Set-Content -Path $shimPath -Encoding UTF8

# =========================
# Define action/principal/triggers
# =========================
if ($corinaRegistryInstance) {
    $taskArgument = "-NoProfile -ExecutionPolicy Bypass -Command `"`$env:CorinaRegistryInstance='$corinaRegistryInstance'; `$env:DOTNET_ENVIRONMENT='Staging'; & '$shimPath'`""
} else {
    $taskArgument = "-NoProfile -ExecutionPolicy Bypass -File `"$shimPath`""
}
$action    = New-ScheduledTaskAction -Execute "powershell.exe" -Argument $taskArgument
$principal = New-ScheduledTaskPrincipal -UserId "SYSTEM" -LogonType ServiceAccount -RunLevel Highest
$trigger1  = New-ScheduledTaskTrigger -Daily -At 7am
$trigger2  = New-ScheduledTaskTrigger -Daily -At 9am
$trigger3  = New-ScheduledTaskTrigger -Daily -At 11am
$trigger4  = New-ScheduledTaskTrigger -Daily -At 1pm
$trigger5  = New-ScheduledTaskTrigger -Daily -At 3pm
$trigger6  = New-ScheduledTaskTrigger -Daily -At 5pm
$trigger7  = New-ScheduledTaskTrigger -Daily -At 12am

# =========================
# Delete existing new-named task if present (idempotent create)
# =========================
if (Get-ScheduledTask -TaskName $taskName -ErrorAction SilentlyContinue) {
    Write-Host "    -> Replacing existing scheduled task: $taskName"
    Unregister-ScheduledTask -TaskName $taskName -Confirm:$false
    Start-Sleep -Seconds 1
}

Register-ScheduledTask -TaskName $taskName -Action $action -Trigger $trigger1, $trigger2, $trigger3, $trigger4, $trigger5, $trigger6, $trigger7 -Principal $principal | Out-Null
Write-Host "    -> Scheduled task '$taskName' created with 7 daily triggers."

Write-Host "`nSUCCESS: Corina Service (Staging) install complete."

# Signal success to a wrapping installer script. This script runs in the caller's
# scope via `irm | iex`, so the wrapper can check this flag after the call.
$corinaStagingInstallSucceeded = $true
