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
# Force TLS 1.2 (required for GitHub; old .NET/PS 5.1 defaults to TLS 1.0)
# =========================
try {
    $proto = [System.Net.ServicePointManager]::SecurityProtocol
    $tls12 = [System.Net.SecurityProtocolType]::Tls12
    if (($proto -band $tls12) -eq 0) {
        [System.Net.ServicePointManager]::SecurityProtocol = $proto -bor $tls12
    }
} catch {
    Write-Warning "Failed to enable TLS 1.2: $_"
}

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

    New-ItemProperty -Path $svcRegPath -Name Environment -PropertyType MultiString -Value $values -Force -ErrorAction Stop | Out-Null
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
    $response = Invoke-RestMethod -Uri $apiUrl -Headers $headers -TimeoutSec 30
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
    Invoke-WebRequest -Uri $zipUrl -OutFile $zipPath -UseBasicParsing -TimeoutSec 300
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
        # Keep the legacy Supabase/AWS values: a machine still on an old binary needs
        # them to keep running, and deleting them here with no token would leave it
        # with neither auth path.
    } else {
        foreach ($name in @("SupabaseUrl", "SupabaseServiceKey", "SupabaseRealtimeUrl", "AWS_LOG_BUCKET", "AWS_ACCESS_KEY_ID", "AWS_SECRET_ACCESS_KEY", "AWS_REGION")) {
            Remove-ItemProperty -Path $regPath -Name $name -ErrorAction SilentlyContinue
        }
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

$stagedExePath = Join-Path $extractDir $exeName
$stagedVersionFile = Join-Path $extractDir '.version'
if (-not (Test-Path -LiteralPath $stagedVersionFile -PathType Leaf)) {
    Write-Error "Staged payload is missing '.version'; aborting before touching the existing install."
    exit 1
}

$stagedFileVersion = [Diagnostics.FileVersionInfo]::GetVersionInfo($stagedExePath).FileVersion
$stagedVersionMatch = [regex]::Match([string]$stagedFileVersion, '^(\d+\.\d+\.\d+)\.\d+$')
if (-not $stagedVersionMatch.Success) {
    Write-Error "Staged executable has an invalid file version '$stagedFileVersion'; aborting."
    exit 1
}
$stagedReleaseVersion = (Get-Content -LiteralPath $stagedVersionFile -Raw).Trim()
if ($stagedReleaseVersion -cne $stagedVersionMatch.Groups[1].Value) {
    Write-Error "Staged .version '$stagedReleaseVersion' does not match executable version '$($stagedVersionMatch.Groups[1].Value)'; aborting."
    exit 1
}

# =========================
# Stop the existing service without deleting its registration (idempotent)
# =========================
$existingService = Get-Service -Name $serviceName -ErrorAction SilentlyContinue
$serviceCreatedByInstaller = $false
$installBackupDir = $null
$hadExistingInstall = Test-Path -LiteralPath $installDir -PathType Container

try {
foreach ($svc in @($serviceName)) {
    if ($existingService) {
        Write-Host "    -> Stopping existing service..."
        Stop-Service -Name $svc -Force -ErrorAction SilentlyContinue
        Start-Sleep -Seconds 2
        Stop-ServiceProcessByName -Name $svc
    }
}

# =========================
# Move old install dir to a same-volume backup (payload already verified)
# =========================
if ($hadExistingInstall) {
    $installBackupDir = "{0}.install-backup-{1}" -f $installDir, ([Guid]::NewGuid().ToString('N'))
    try {
        Write-Host "    -> Backing up old install directory to $installBackupDir"
        Move-Item -LiteralPath $installDir -Destination $installBackupDir -ErrorAction Stop
    } catch {
        throw "Could not move the existing install into a rollback backup: $_"
    }
}

# =========================
# Copy verified files into place
# =========================
Write-Host "    -> Copying new release files into $installDir ..."
New-Item -ItemType Directory -Path $installDir -Force | Out-Null
# /IS re-copies unchanged same-size files in general, but it is NOT reliable for
# the dotfile '.version' (robocopy's wildcard + fixed 1980 ZIP timestamp skip it
# as "Same"), so that marker is copied explicitly below.
robocopy $extractDir $installDir /E /IS /R:2 /W:2 /NFL /NDL /NP /NJH /NJS | Out-Null
if ($LASTEXITCODE -ge 8) {
    throw "Failed to copy new files into $installDir (robocopy exit $LASTEXITCODE)."
}

# Deterministically overwrite the version marker; robocopy cannot be trusted to
# re-copy the same-size/same-timestamp '.version' dotfile.
Copy-Item -LiteralPath (Join-Path $extractDir '.version') -Destination $installDir -Force -ErrorAction Stop

$installedVersionFile = Join-Path $installDir '.version'
if (-not (Test-Path -LiteralPath $installedVersionFile -PathType Leaf) -or
    (Get-Content -LiteralPath $installedVersionFile -Raw).Trim() -cne $stagedReleaseVersion) {
    throw "Installed .version does not match staged release version '$stagedReleaseVersion'."
}
Remove-Item -Recurse -Force $extractDir -ErrorAction SilentlyContinue

if (-not (Test-Path $exePath)) {
    throw "Failed to find service executable at $exePath"
}

# =========================
# Register new service and configure recovery
# =========================
Write-Host "`n[*] Registering Windows service"
if (-not (Get-Service -Name $serviceName -ErrorAction SilentlyContinue)) {
    Write-Host "    -> Creating Windows service: $serviceName"
    sc.exe create $serviceName binPath= "`"$exePath`"" start= auto obj= "LocalSystem" DisplayName= "$serviceDisplayName" | Out-Null
    if ($LASTEXITCODE -ne 0) {
        throw "sc.exe create failed for '$serviceName' (exit code $LASTEXITCODE)."
    }
    $serviceCreatedByInstaller = $true
} else {
    Write-Host "    -> Reusing existing Windows service: $serviceName"
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
    throw "Service failed to start (status: $($svc.Status)). Aborting."
}
Write-Host "SUCCESS: Corina Service (Staging) installed and started."

# The new payload and service are healthy; the old directory is no longer
# needed. Keep it on failure paths until this point so installation is recoverable.
if ($installBackupDir -and (Test-Path -LiteralPath $installBackupDir)) {
    try {
        Remove-Item -LiteralPath $installBackupDir -Recurse -Force -ErrorAction Stop
    } catch {
        Write-Warning "Could not remove install backup $installBackupDir; leaving it for manual recovery: $_"
    }
}
} catch {
    Write-Error "Installation failed; restoring the previous staging installation: $_"
    try {
        if ($serviceCreatedByInstaller -and (Get-Service -Name $serviceName -ErrorAction SilentlyContinue)) {
            Stop-Service -Name $serviceName -Force -ErrorAction SilentlyContinue
            Stop-ServiceProcessByName -Name $serviceName
            sc.exe delete $serviceName | Out-Null
            Start-Sleep -Seconds 2
        }
        if ($installBackupDir -and (Test-Path -LiteralPath $installBackupDir -PathType Container)) {
            if (Test-Path -LiteralPath $installDir) {
                Remove-Item -LiteralPath $installDir -Recurse -Force -ErrorAction Stop
            }
            Move-Item -LiteralPath $installBackupDir -Destination $installDir -ErrorAction Stop
        } elseif (-not $hadExistingInstall -and (Test-Path -LiteralPath $installDir)) {
            Remove-Item -LiteralPath $installDir -Recurse -Force -ErrorAction Stop
        }
        if ($existingService) {
            Set-CorinaServiceEnvironment -Name $serviceName -Instance $corinaRegistryInstance
            Start-Service -Name $serviceName -ErrorAction Stop
            Write-Host "    -> Previous service restored and started."
        }
    } catch {
        Write-Error "Automatic rollback failed: $_"
    }
    exit 1
}

# =========================
# Scheduled Task: remove old, create new
# =========================
Write-Host "`n[*] Configuring daily auto-updater"

# Ensure-CorinaStagingUpdaterTask lives in a shared script (also used by daily-updater.ps1).
# This script runs via `irm | iex` on clinic machines, so the helper must be fetched
# from the release repo rather than dot-sourced from disk.
$ensureTaskUrl = "https://raw.githubusercontent.com/Care-AI-Inc/careai-corina-service-staging-releases/main/ensure-updater-task.ps1"
try {
    $ensureTaskContent = Invoke-RestMethod -Uri $ensureTaskUrl -Headers $headers -TimeoutSec 30
    # Strip a UTF-8 BOM if present: Invoke-RestMethod keeps it as a leading U+FEFF
    # character, which breaks Invoke-Expression parsing.
    if ($ensureTaskContent.Length -gt 0 -and $ensureTaskContent[0] -eq [char]0xFEFF) {
        $ensureTaskContent = $ensureTaskContent.Substring(1)
    }
    Invoke-Expression $ensureTaskContent
} catch {
    Write-Error "Failed to fetch shared updater-task helper from ${ensureTaskUrl}: $_"
    exit 1
}

# Tagged installs must not leave the old single-instance task/shim running in parallel.
# Exception: while a default (no-tag) service is still installed on this machine, its
# updater task/shim are legitimately in use (staging test boxes run tagged and no-tag
# side by side), so only clean them up once the default service itself is gone.
$legacyTaskNames = @()
$legacyShimPaths = @()
$defaultServiceInstalled = [bool](Get-Service -Name "CorinaService-Staging" -ErrorAction SilentlyContinue)
if ($corinaRegistryInstance -and -not $defaultServiceInstalled) {
    $legacyTaskNames += "CorinaStagingDailyUpdater"
    $legacyShimPaths += Join-Path "C:\Scripts" "run-daily-updater-staging.ps1"
}
Ensure-CorinaStagingUpdaterTask -Instance $corinaRegistryInstance -TaskName $taskName -LegacyTaskNames $legacyTaskNames -LegacyShimPaths $legacyShimPaths -ForceRecreate

# Clean up the downloaded zip now that the install has fully succeeded
Remove-Item -LiteralPath $zipPath -Force -ErrorAction SilentlyContinue

Write-Host "`nSUCCESS: Corina Service (Staging) install complete."

# Signal success to a wrapping installer script. This script runs in the caller's
# scope via `irm | iex`, so the wrapper can check this flag after the call.
$corinaStagingInstallSucceeded = $true
