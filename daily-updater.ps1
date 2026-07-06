# daily-updater-staging.ps1
# Purpose: Keep Corina Service (Staging) up to date.

# =========================
# Admin Check
# =========================
if (-not ([Security.Principal.WindowsPrincipal] `
    [Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole(`
    [Security.Principal.WindowsBuiltInRole] "Administrator")) {
    Write-Error "You must run this script as Administrator."
    exit 1
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

    New-ItemProperty -Path $svcRegPath -Name Environment -PropertyType MultiString -Value $values -Force | Out-Null
}

$corinaRegistryInstance = Get-CorinaRegistryInstance

# =========================
# Logging
# =========================
$logDir  = "C:\Scripts"
if (-not (Test-Path $logDir)) { New-Item -ItemType Directory -Path $logDir | Out-Null }
if ($corinaRegistryInstance) {
    $logPath = Join-Path $logDir "corina-staging-update-log-$corinaRegistryInstance.txt"
} else {
    $logPath = Join-Path $logDir "corina-staging-update-log.txt"
}

# Structured log writer. Every line keeps the timestamp prefix; the level renders a
# scannable status column that mirrors the console style of the installer/shim:
#   STEP   -> "[*] "     section header
#   DETAIL -> "    -> "  progress detail inside a section
#   OK     -> "[OK] "    section finished successfully
#   FAIL   -> "[FAIL] "  section failed
#   WARN   -> "[WARN] "  non-fatal problem
#   INFO   -> no prefix  free-form line
function Write-Log {
    param(
        [Parameter(Mandatory=$true)][string]$Message,
        [ValidateSet('INFO','STEP','OK','FAIL','WARN','DETAIL')][string]$Level = 'DETAIL'
    )
    $prefix = switch ($Level) {
        'STEP'   { '[*] ' }
        'OK'     { '[OK] ' }
        'FAIL'   { '[FAIL] ' }
        'WARN'   { '[WARN] ' }
        'DETAIL' { '    -> ' }
        default  { '' }
    }
    "[$(Get-Date)] $prefix$Message" | Out-File -Append $logPath
}

Write-Log "Corina Service (Staging) updater started" 'INFO'

# =========================
# Force TLS 1.2 (required for GitHub; old .NET/PS 5.1 defaults to TLS 1.0)
# =========================
# The shim sets this too, but only for its own process; this script runs in a
# fresh child process, so it must set it again itself.
try {
    $proto = [System.Net.ServicePointManager]::SecurityProtocol
    $tls12 = [System.Net.SecurityProtocolType]::Tls12
    if (($proto -band $tls12) -eq 0) {
        [System.Net.ServicePointManager]::SecurityProtocol = $proto -bor $tls12
    }
} catch {
    Write-Log "Failed to enable TLS 1.2: $_" 'WARN'
}

# Concurrency guard  only one updater per instance at a time.
# Wait 5 minutes at most: if the lock is still busy, another updater is actively
# running and this round is redundant (the next trigger is at most 2 hours away).
$mutexName = if ($corinaRegistryInstance) { "Global\CorinaStagingUpdater-$corinaRegistryInstance" } else { "Global\CorinaStagingUpdater" }
$mutex = New-Object Threading.Mutex($false, $mutexName)
$mutexAcquired = $false
try {
    $mutexAcquired = $mutex.WaitOne([TimeSpan]::FromMinutes(5))
} catch [System.Threading.AbandonedMutexException] {
    # The previous holder was killed without releasing (e.g. powershell ended via
    # Task Manager). Despite the exception, ownership HAS passed to us; treat it as
    # acquired and continue -- the verify/backup/rollback flow below cleans up any
    # half-finished state the dead run left behind.
    Write-Log "Previous updater was killed without releasing the lock; continuing with this run." 'WARN'
    $mutexAcquired = $true
}
if (-not $mutexAcquired) {
    Write-Log "Another updater instance is already running. Exiting." 'WARN'
    exit 0
}

# Set on update failure so the script exits non-zero and the shim/scheduled task
# report the failure instead of always showing success.
$script:updateFailed = $false

# =========================
# Release Source (unchanged repo/artifacts)
# =========================
$repo   = "Care-AI-Inc/careai-corina-service-staging-releases"
$apiUrl = "https://api.github.com/repos/$repo/releases/latest"
$headers = @{ "User-Agent" = "CorinaServiceStagingUpdater" }

# =========================
# Names and Paths
# =========================
$exeName        = "careai-corina-service.exe"  # keep current exe name; change later when your releases do
if ($corinaRegistryInstance) {
    $newServiceName = "CorinaService-Staging-$corinaRegistryInstance"
    $newTaskName    = "CorinaStagingDailyUpdater-$corinaRegistryInstance"
    $installDir     = Join-Path (Join-Path ${env:ProgramFiles} "CorinaService-Staging") $corinaRegistryInstance
    $serviceDisplayName = "Corina Service (Staging - $corinaRegistryInstance)"
} else {
    $newServiceName = "CorinaService-Staging"
    $newTaskName    = "CorinaStagingDailyUpdater"
    $installDir     = Join-Path ${env:ProgramFiles} "CorinaService-Staging"
    $serviceDisplayName = "Corina Service (Staging)"
}
$exePath        = Join-Path $installDir $exeName
$defaultCorinaBackendBaseUrl = "https://backend.staging.caregp.com.au"

function Get-CorinaBackendBaseUrlFromRegistry {
    param([Parameter(Mandatory=$true)][string]$RegPath)

    $props = Get-ItemProperty -Path $RegPath -ErrorAction SilentlyContinue
    if (-not $props) { return $defaultCorinaBackendBaseUrl }

    if (-not [string]::IsNullOrWhiteSpace($props.SamanthaBaseUrl)) {
        return ([string]$props.SamanthaBaseUrl).TrimEnd('/')
    }

    $samanthaUrl = [string]$props.SamanthaUrl
    if ([string]::IsNullOrWhiteSpace($samanthaUrl)) { return $defaultCorinaBackendBaseUrl }

    foreach ($suffix in @(
        "/corina/analyse-with-gemini-for-corina-service",
        "/analyse-with-gemini-for-corina-service"
    )) {
        $idx = $samanthaUrl.IndexOf($suffix, [StringComparison]::OrdinalIgnoreCase)
        if ($idx -ge 0) {
            return $samanthaUrl.Substring(0, $idx).TrimEnd('/')
        }
    }

    try {
        $uri = [Uri]$samanthaUrl
        return $uri.GetLeftPart([UriPartial]::Authority).TrimEnd('/')
    } catch {
        return $defaultCorinaBackendBaseUrl
    }
}

function Request-CorinaAgentTokenMigration {
    param(
        [Parameter(Mandatory=$true)][string]$RegPath,
        [string]$Instance
    )

    $props = Get-ItemProperty -Path $RegPath -ErrorAction SilentlyContinue
    if (-not $props) { return $null }

    $haloGuid = [string]$props.HaloGuid
    if ([string]::IsNullOrWhiteSpace($haloGuid)) {
        Write-Log "cannot migrate CorinaAgentToken: HaloGuid missing in registry" 'WARN'
        return $null
    }

    $baseUrl = Get-CorinaBackendBaseUrlFromRegistry -RegPath $RegPath
    if ([string]::IsNullOrWhiteSpace($baseUrl)) {
        Write-Log "cannot migrate CorinaAgentToken: Samantha backend URL missing in registry" 'WARN'
        return $null
    }

    $clinicTag = [string]$props.ClinicTag
    if ([string]::IsNullOrWhiteSpace($clinicTag)) {
        $clinicTag = $Instance
    }

    $body = @{
        haloGuid = $haloGuid
        clinicTag = if ([string]::IsNullOrWhiteSpace($clinicTag)) { $null } else { $clinicTag }
        machineId = if ([string]::IsNullOrWhiteSpace($clinicTag)) { $haloGuid } else { "$haloGuid`:$clinicTag" }
    } | ConvertTo-Json -Compress

    try {
        $response = Invoke-RestMethod -Method Post -Uri "$baseUrl/corina/agent-tokens/migrate-by-halo-guid" -ContentType "application/json" -Body $body -TimeoutSec 30
        if (-not [string]::IsNullOrWhiteSpace([string]$response.token)) {
            Set-ItemProperty -Path $RegPath -Name "CorinaAgentToken" -Value ([string]$response.token)
            Set-ItemProperty -Path $RegPath -Name "SamanthaBaseUrl" -Value $baseUrl
            # WARN, not OK: a brand-new token being minted outside the installer is
            # unexpected and worth spotting when scanning the log.
            Write-Log "migrated CorinaAgentToken via temporary HaloGuid bridge (a NEW token was issued)" 'WARN'
            return [string]$response.token
        }
        Write-Log "migration endpoint returned no token" 'WARN'
    } catch {
        Write-Log "CorinaAgentToken migration failed: $_" 'WARN'
    }
    return $null
}

$regPath = "HKLM:\SOFTWARE\CareAI\CorinaService-Staging"
if ($corinaRegistryInstance) {
    $regPath = Join-Path $regPath $corinaRegistryInstance
}
Write-Log "Registry / token check" 'STEP'
Write-Log "registry path: $regPath"
if (-not (Test-Path $regPath)) {
    Write-Log "registry path not found; run the generated installer to configure CorinaAgentToken" 'FAIL'
} else {
    $token = (Get-ItemProperty -Path $regPath -Name "CorinaAgentToken" -ErrorAction SilentlyContinue).CorinaAgentToken
    if ([string]::IsNullOrWhiteSpace($token)) {
        Write-Log "CorinaAgentToken missing; attempting HaloGuid migration"
        $token = Request-CorinaAgentTokenMigration -RegPath $regPath -Instance $corinaRegistryInstance
    }
    if ([string]::IsNullOrWhiteSpace($token)) {
        Write-Log "CorinaAgentToken is missing after migration attempt; regenerate the staging installer script from analytics/backend" 'FAIL'
        # Keep the legacy Supabase/AWS values: a machine still on an old binary needs
        # them to keep running, and deleting them here with no token would leave it
        # with neither auth path if this update round also fails.
    } else {
        foreach ($name in @("SupabaseUrl", "SupabaseServiceKey", "SupabaseRealtimeUrl", "AWS_LOG_BUCKET", "AWS_ACCESS_KEY_ID", "AWS_SECRET_ACCESS_KEY", "AWS_REGION")) {
            Remove-ItemProperty -Path $regPath -Name $name -ErrorAction SilentlyContinue
        }
        Write-Log "CorinaAgentToken present" 'OK'
    }
}

$tempZip    = $null
$instanceSuffix = if ($corinaRegistryInstance) { "-$corinaRegistryInstance" } else { "" }
$extractDir = Join-Path $env:TEMP "CorinaServiceStagingExtract$instanceSuffix"

try {
    # =========================
    # Fetch latest ZIP asset
    # =========================
    Write-Log "Download and verify release payload" 'STEP'
    $response = Invoke-RestMethod -Uri $apiUrl -Headers $headers -TimeoutSec 30
    $zipAsset = $response.assets | Where-Object { $_.name -like '*.zip' } | Select-Object -First 1
    if (-not $zipAsset) { throw "No .zip asset found in latest release." }

    $zipUrl  = $zipAsset.browser_download_url
    $zipName = $zipAsset.name
    $zipBaseName = [System.IO.Path]::GetFileNameWithoutExtension($zipName)
    $tempZip = Join-Path $env:TEMP "$zipBaseName$instanceSuffix.zip"
    Write-Log "release asset: $zipName"

    Invoke-WebRequest -Uri $zipUrl -OutFile $tempZip -UseBasicParsing -TimeoutSec 300
    Write-Log "downloaded to $tempZip"

    # =========================
    # Prepare extraction
    # =========================
    if (Test-Path $extractDir) { Remove-Item -Recurse -Force $extractDir }
    Expand-Archive -Path $tempZip -DestinationPath $extractDir

    # =========================
    # Verify staged payload BEFORE touching the live install
    # =========================
    # NOTE: The service is intentionally NOT stopped yet. It keeps running through
    # download + extract + verification, so a bad or failed payload never causes downtime.
    # It is stopped later, only after the payload is verified and the current install is backed up.
    $stagedExe = Join-Path $extractDir $exeName

    # 1) main exe must be present in the staged payload
    if (-not (Test-Path $stagedExe)) { throw "Staged payload missing service exe '$exeName' in $extractDir" }

    # 2) staged exe must be a readable, valid PE with a version (catches truncation/corruption)
    try {
        $stagedVer = [Diagnostics.FileVersionInfo]::GetVersionInfo($stagedExe).FileVersion
        if ([string]::IsNullOrWhiteSpace($stagedVer)) { throw "no version info" }
    } catch { throw "Staged exe '$stagedExe' is not a valid executable: $_" }

    # 3) sanity check: a broken/partial zip often extracts to only 0-1 files
    $stagedCount = (Get-ChildItem -Path $extractDir -Recurse -File).Count
    if ($stagedCount -lt 5) { throw "Staged payload has only $stagedCount files; refusing to deploy" }

    # 4) refuse a downgrade relative to the currently installed exe (best-effort; never throws on parse)
    $curVer = $null
    if (Test-Path $exePath) {
        try { $curVer = [Diagnostics.FileVersionInfo]::GetVersionInfo($exePath).FileVersion } catch { }
    }
    if (-not [string]::IsNullOrWhiteSpace($curVer)) {
        $sv = $null; $cv = $null
        [void][Version]::TryParse($stagedVer, [ref]$sv)
        [void][Version]::TryParse($curVer, [ref]$cv)
        if ($sv -and $cv -and $sv -lt $cv) {
            throw "Staged version $stagedVer is older than installed $curVer; refusing downgrade"
        }
    }
    Write-Log "payload verified: exe=$exeName version=$stagedVer files=$stagedCount" 'OK'

    # =========================
    # Back up the current install so we can roll back
    # =========================
    Write-Log "Back up current install" 'STEP'
    $backupDir = Join-Path $env:TEMP "CorinaServiceStagingBackup$instanceSuffix"
    $haveBackup = $false
    if (Test-Path $backupDir) { Remove-Item -Recurse -Force $backupDir }
    if (Test-Path $installDir) {
        New-Item -ItemType Directory -Path $backupDir -Force | Out-Null
        & robocopy "$installDir" "$backupDir" * /E /COPY:DAT /R:5 /W:3 /NFL /NDL /NP /NJH /NJS | Out-Null
        if ($LASTEXITCODE -ge 8) { throw "Backup of current install failed (robocopy exit $LASTEXITCODE)" }
        $haveBackup = $true
        Write-Log "backed up current install to $backupDir" 'OK'
    } else {
        Write-Log "no existing install directory; skipping backup"
    }

    # =========================
    # Only NOW stop the service (payload verified + backup taken) -- minimal downtime
    # =========================
    Write-Log "Stop service and deploy new files" 'STEP'
    $svcToStop = Get-Service -Name $newServiceName -ErrorAction SilentlyContinue
    if ($svcToStop) {
        Stop-Service -Name $svcToStop.Name -Force -ErrorAction SilentlyContinue
        Start-Sleep -Seconds 2
        # Best-effort kill of this lingering service process
        Stop-ServiceProcessByName -Name $svcToStop.Name
        Start-Sleep -Seconds 1
        Write-Log "service '$($svcToStop.Name)' stopped"
    } else {
        Write-Log "service '$newServiceName' not present yet; nothing to stop"
    }

    # =========================
    # Ensure new install directory exists
    # =========================
    if (-not (Test-Path $installDir)) {
        New-Item -ItemType Directory -Path $installDir -Force | Out-Null
    }

    # =========================
    # Copy extracted files  new install folder (preserve ACLs)
    # =========================
    robocopy $extractDir $installDir /E /R:2 /W:2 /NFL /NDL /NP /NJH /NJS | Out-Null
    $rc2 = $LASTEXITCODE
    if ($rc2 -ge 8) {
        if ($haveBackup) {
            Write-Log "deploy robocopy failed (exit $rc2); restoring previous version" 'FAIL'
            & robocopy "$backupDir" "$installDir" * /MIR /COPY:DAT /R:10 /W:5 /NFL /NDL /NP /NJH /NJS | Out-Null
            if ($svcToStop) {
                Set-CorinaServiceEnvironment -Name $svcToStop.Name -Instance $corinaRegistryInstance
                Start-Service -Name $svcToStop.Name -ErrorAction SilentlyContinue
            }
            throw "Deploy failed (robocopy exit $rc2); rolled back to previous version."
        }
        throw "Robocopy (extractinstall) failed with code $rc2"
    }

    if (-not (Test-Path $exePath)) {
        throw "Executable not found at $exePath"
    }
    Write-Log "new files deployed to $installDir" 'OK'

    # =========================
    # Ensure the service exists, then start it
    # =========================
    Write-Log "Start service and health check" 'STEP'
    $hasNew = Get-Service -Name $newServiceName -ErrorAction SilentlyContinue
    if (-not $hasNew) {
        sc.exe create $newServiceName binPath= "`"$exePath`"" start= auto DisplayName= "$serviceDisplayName" | Out-Null
        Set-CorinaServiceEnvironment -Name $newServiceName -Instance $corinaRegistryInstance
        sc.exe failure     $newServiceName reset= 86400 actions= restart/5000/restart/5000/restart/5000 | Out-Null
        sc.exe failureflag $newServiceName 1 | Out-Null
        # Health check below decides success; roll back there instead of failing hard here
        Start-Service -Name $newServiceName -ErrorAction SilentlyContinue
    } else {
        Set-CorinaServiceEnvironment -Name $newServiceName -Instance $corinaRegistryInstance
        Start-Service -Name $newServiceName -ErrorAction SilentlyContinue
    }

    # =========================
    # Health-check; roll back if the new build will not stay Running
    # =========================
    # Wait up to 30s to reach Running (tolerates StartPending), then confirm it stays up ~5s
    $healthy = $false
    $hsw = [Diagnostics.Stopwatch]::StartNew()
    while ($hsw.Elapsed.TotalSeconds -lt 30) {
        Start-Sleep -Seconds 3
        $s = Get-Service -Name $newServiceName -ErrorAction SilentlyContinue
        if ($s -and $s.Status -eq 'Running') { $healthy = $true; break }
    }
    if ($healthy) {
        Start-Sleep -Seconds 5
        $s2 = Get-Service -Name $newServiceName -ErrorAction SilentlyContinue
        if (-not ($s2 -and $s2.Status -eq 'Running')) { $healthy = $false }
    }

    if (-not $healthy) {
        if ($haveBackup) {
            Write-Log "service did not stay Running after update; restoring previous version" 'FAIL'
            Stop-Service -Name $newServiceName -Force -ErrorAction SilentlyContinue
            & robocopy "$backupDir" "$installDir" * /MIR /COPY:DAT /R:10 /W:5 /NFL /NDL /NP /NJH /NJS | Out-Null
            Set-CorinaServiceEnvironment -Name $newServiceName -Instance $corinaRegistryInstance
            Start-Service -Name $newServiceName -ErrorAction SilentlyContinue
            throw "New build v$stagedVer failed health check; rolled back to previous version."
        }
        throw "Service '$newServiceName' did not stay Running after update (no backup available to roll back)."
    }

    # =========================
    # Clean up temp artifacts on success: this run's zip + extracted payload, plus
    # stale zips left by older versions (each release has a unique file name, so
    # they accumulate in SYSTEM's temp otherwise). On failure this is skipped and
    # the zip stays behind for diagnostics; the next successful run sweeps it up.
    # The backup dir is intentionally kept until the next run as a manual-rollback
    # artifact; its name is fixed, so it never accumulates.
    # =========================
    Remove-Item -LiteralPath $tempZip -Force -ErrorAction SilentlyContinue
    Remove-Item -Recurse -Force $extractDir -ErrorAction SilentlyContinue
    Get-ChildItem -Path $env:TEMP -Filter "corina-staging-*.zip" -ErrorAction SilentlyContinue |
        Where-Object { $_.LastWriteTime -lt (Get-Date).AddDays(-1) } |
        Remove-Item -Force -ErrorAction SilentlyContinue

    Write-Log "update complete: v$stagedVer deployed and service '$newServiceName' running" 'OK'
}
catch {
    Write-Log "Update failed: $_" 'FAIL'
    $script:updateFailed = $true
}
finally {
    $mutex.ReleaseMutex()
    $mutex.Dispose()
}

# =========================
# Scheduled Task: write shim and ensure desired times
# =========================
# Ensure-CorinaStagingUpdaterTask lives in a shared script (also used by install.ps1).
# This script runs from a temp file on clinic machines, so the helper must be fetched
# from the release repo rather than dot-sourced from disk.
try {
    Write-Log "Refresh updater shim and scheduled task" 'STEP'
    $ensureTaskUrl = "https://raw.githubusercontent.com/Care-AI-Inc/careai-corina-service-staging-releases/main/ensure-updater-task.ps1"
    Invoke-RestMethod -Uri $ensureTaskUrl -Headers $headers -TimeoutSec 30 | Invoke-Expression

    # Tagged installs must not leave the old single-instance task running in parallel.
    $taskNamesToRemove = @()
    if ($corinaRegistryInstance) {
        $taskNamesToRemove += "CorinaStagingDailyUpdater"
    }
    # Route the helper's progress messages into the log as indented detail lines.
    $logToFile = {
        param($Message)
        Write-Log $Message 'DETAIL'
    }
    Ensure-CorinaStagingUpdaterTask -Instance $corinaRegistryInstance -TaskName $newTaskName -LegacyTaskNames $taskNamesToRemove -Log $logToFile
    Write-Log "scheduled task '$newTaskName' verified" 'OK'
}
catch {
    Write-Log "scheduled task migration/ensure failed: $_" 'WARN'
}

if ($script:updateFailed) {
    Write-Log "RESULT: update did not complete; exiting with code 1 so the scheduled task records the failure" 'FAIL'
    exit 1
}
Write-Log "RESULT: updater run finished" 'OK'
