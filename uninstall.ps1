# Corina Service staging uninstaller.
# Final release copies are Authenticode-signed after all build substitutions.
# The repository source intentionally contains no stale signature block.

[CmdletBinding()]
param(
    [ValidatePattern('^[A-Za-z0-9](?:[A-Za-z0-9_-]*[A-Za-z0-9])?$')]
    [string]$Instance,
    [string[]]$TrustedSignerThumbprints
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$builtInTrustedSignerThumbprints = @('__CORINA_RELEASE_SIGNER_THUMBPRINTS__')
$script:CorinaServiceBaseName = 'CorinaService-Staging'
$script:CorinaTaskBaseName = 'CorinaStagingDailyUpdater'
$script:CorinaProgramFilesLeaf = 'CorinaService-Staging'
$script:CorinaProgramDataRoot = 'CareAI\CorinaService-Staging'
$script:CorinaRegistryRoot = 'HKLM:\SOFTWARE\CareAI\CorinaService-Staging'
$script:CorinaLegacyShimBaseName = 'run-daily-updater-staging'

# Assign the fallback to a separate variable: writing $null back into the
# [ValidatePattern] parameter variable re-triggers validation and always throws
# on default-instance machines where the environment variable is unset.
$corinaRegistryInstance = $Instance
if ([string]::IsNullOrWhiteSpace($corinaRegistryInstance)) { $corinaRegistryInstance = [Environment]::GetEnvironmentVariable('CorinaRegistryInstance', [EnvironmentVariableTarget]::Process) }
if ($corinaRegistryInstance -and $corinaRegistryInstance -notmatch '^[A-Za-z0-9](?:[A-Za-z0-9_-]*[A-Za-z0-9])?$') { throw 'Invalid Corina registry instance.' }
$registryPath = $script:CorinaRegistryRoot
if ($corinaRegistryInstance) { $registryPath = Join-Path $registryPath $corinaRegistryInstance }

# Wrapping this parameter directly in @( ) is NOT a safe array-wrap: an unbound
# typed [string[]] parameter is a null whose array wrap stays $null, so the
# .Count below threw under Set-StrictMode and made every bare `.\uninstall.ps1`
# fail before the registry and built-in trust fallbacks could be reached.
$trustInput = @()
if ($null -ne $TrustedSignerThumbprints) {
    $trustInput = @($TrustedSignerThumbprints | Where-Object { -not [string]::IsNullOrWhiteSpace([string]$_) })
}
if ($trustInput.Count -eq 0 -and (Test-Path -LiteralPath $registryPath)) {
    # Blank entries must not count as trust state, or a registry value holding an
    # empty string would suppress the built-in fallback and block the uninstall.
    try { $trustInput = @((Get-ItemPropertyValue -LiteralPath $registryPath -Name TrustedSignerThumbprints -ErrorAction Stop) | Where-Object { -not [string]::IsNullOrWhiteSpace([string]$_) }) }
    catch { $trustInput = @() }
}
if ($trustInput.Count -eq 0) { $trustInput = $builtInTrustedSignerThumbprints }
$invalidTrust = @($trustInput | Where-Object {
    -not [string]::IsNullOrWhiteSpace([string]$_) -and
    ([string]$_).Replace(' ', '').ToUpperInvariant() -notmatch '^[0-9A-F]{40}$' -and
    [string]$_ -ne '__CORINA_RELEASE_SIGNER_THUMBPRINTS__'
})
if ($invalidTrust.Count -gt 0) { throw 'A trusted signer thumbprint is invalid.' }
$trusted = @($trustInput | ForEach-Object { ([string]$_).Replace(' ', '').ToUpperInvariant() } | Where-Object { $_ -match '^[0-9A-F]{40}$' } | Select-Object -Unique)
if ($trusted.Count -eq 0) { throw 'No trusted signer thumbprint is available; uninstall is blocked (fail closed).' }

if ([string]::IsNullOrWhiteSpace($PSCommandPath)) { throw 'uninstall.ps1 must run from a signed file on disk.' }
$signature = Get-AuthenticodeSignature -FilePath $PSCommandPath
if ($signature.Status -ne 'Valid' -or -not $signature.SignerCertificate) { throw "Uninstaller Authenticode signature is not valid: $($signature.Status)." }
$certificate = $signature.SignerCertificate
$thumbprint = $certificate.Thumbprint.Replace(' ', '').ToUpperInvariant()
if ($thumbprint -notin $trusted) { throw 'Uninstaller signer thumbprint is not trusted.' }
$simpleName = ($certificate.GetNameInfo([Security.Cryptography.X509Certificates.X509NameType]::SimpleName, $false) -replace '[^A-Za-z0-9]', '').ToUpperInvariant()
if ($simpleName -cne 'CAREAIPTYLTD') { throw 'Uninstaller publisher common name mismatch.' }
$subject = (([string]$certificate.Subject) -replace '[^A-Za-z0-9=,.]', '').ToUpperInvariant()
if ($subject -notmatch '(?:^|,)O=CAREAIPTYLTD(?:,|$)' -or
    $subject -notmatch '(?:^|,)C=AU(?:,|$)' -or
    $subject -notmatch '(?:^|,)(?:SERIALNUMBER|OID\.2\.5\.4\.5)=38681904512(?:,|$)') {
    throw 'Uninstaller publisher identity mismatch.'
}
$hasCodeSigningEku = $false
foreach ($extension in $certificate.Extensions) {
    if ($extension.Oid.Value -eq '2.5.29.37') {
        $eku = [Security.Cryptography.X509Certificates.X509EnhancedKeyUsageExtension]$extension
        if ($eku.EnhancedKeyUsages | Where-Object { $_.Value -eq '1.3.6.1.5.5.7.3.3' }) { $hasCodeSigningEku = $true }
    }
}
if (-not $hasCodeSigningEku) { throw 'Uninstaller certificate lacks the code-signing EKU.' }

$principal = [Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()
if (-not $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) { throw 'You must run uninstall.ps1 as Administrator.' }

$serviceName = if ($corinaRegistryInstance) { "$($script:CorinaServiceBaseName)-$corinaRegistryInstance" } else { $script:CorinaServiceBaseName }
$taskName = if ($corinaRegistryInstance) { "$($script:CorinaTaskBaseName)-$corinaRegistryInstance" } else { $script:CorinaTaskBaseName }
$installDir = if ($corinaRegistryInstance) { Join-Path (Join-Path $env:ProgramFiles $script:CorinaProgramFilesLeaf) $corinaRegistryInstance } else { Join-Path $env:ProgramFiles $script:CorinaProgramFilesLeaf }
$stateRoot = if ($corinaRegistryInstance) { Join-Path (Join-Path $env:ProgramData $script:CorinaProgramDataRoot) $corinaRegistryInstance } else { Join-Path (Join-Path $env:ProgramData $script:CorinaProgramDataRoot) 'default' }

function ConvertFrom-CorinaServiceQueryOutput {
    param(
        [Parameter(Mandatory)][AllowEmptyString()][AllowEmptyCollection()][string[]]$Output,
        [Parameter(Mandatory)][int]$ExitCode,
        [Parameter(Mandatory)][string]$Name
    )
    if ($ExitCode -in @(1060, 1072)) { return $null }
    if ($ExitCode -ne 0) { throw "sc.exe queryex failed for '$Name' (exit $ExitCode)." }
    $text = $Output -join "`n"
    $stateMatch = [regex]::Match($text, 'STATE\s*:\s*(?<code>\d+)\s+(?<state>[A-Z_]+)')
    $processMatch = [regex]::Match($text, 'PID\s*:\s*(?<pid>\d+)')
    if (-not $stateMatch.Success -or -not $processMatch.Success) { throw "Could not parse service state for '$Name'." }
    return [pscustomobject]@{
        StateCode = [int]$stateMatch.Groups['code'].Value
        State = $stateMatch.Groups['state'].Value
        ProcessId = [int]$processMatch.Groups['pid'].Value
    }
}

function Get-CorinaServiceNativeState {
    param([Parameter(Mandatory)][string]$Name)
    $output = @(& "$env:SystemRoot\System32\sc.exe" queryex $Name 2>&1)
    return ConvertFrom-CorinaServiceQueryOutput -Output $output -ExitCode $LASTEXITCODE -Name $Name
}

function Stop-CorinaServiceSafely {
    param(
        [Parameter(Mandatory)][string]$Name,
        [int]$GraceSeconds = 15,
        [scriptblock]$Log = { param($Message) Write-Warning $Message }
    )
    $state = Get-CorinaServiceNativeState -Name $Name
    if (-not $state -or $state.StateCode -eq 1) { return }

    # sc.exe sends the stop control without PowerShell's unbounded WaitForStatus call.
    $stopRequest = Start-Process -FilePath "$env:SystemRoot\System32\sc.exe" -ArgumentList @('stop', $Name) -PassThru -WindowStyle Hidden
    if (-not $stopRequest.WaitForExit(5000)) {
        try { $stopRequest.Kill() } catch { }
        if (-not $stopRequest.WaitForExit(5000)) {
            throw "The stop request for service '$Name' timed out and its sc.exe process could not be terminated."
        }
        & $Log "The stop request for service '$Name' timed out; waiting before forced termination."
    } elseif ($stopRequest.ExitCode -ne 0) {
        & $Log "sc.exe stop returned exit $($stopRequest.ExitCode) for service '$Name'; waiting before forced termination."
    }

    $timer = [Diagnostics.Stopwatch]::StartNew()
    while ($timer.Elapsed.TotalSeconds -lt $GraceSeconds) {
        Start-Sleep -Milliseconds 500
        $state = Get-CorinaServiceNativeState -Name $Name
        if (-not $state -or $state.StateCode -eq 1) { return }
    }

    # Refresh immediately before terminating so a PID from the polling interval
    # is never used after the service has already exited.
    $state = Get-CorinaServiceNativeState -Name $Name
    if (-not $state -or $state.StateCode -eq 1) { return }
    if ($state.ProcessId -gt 0) {
        & $Log "Service '$Name' did not stop within $GraceSeconds seconds; terminating process $($state.ProcessId)."
        try {
            Stop-Process -Id $state.ProcessId -Force -ErrorAction Stop
        }
        catch {
            # Process exit can race Stop-Process. Treat that as success only when
            # SCM independently confirms the service is now stopped.
            $terminationError = $_
            $state = Get-CorinaServiceNativeState -Name $Name
            if (-not $state -or $state.StateCode -eq 1) { return }
            & $Log "Terminating process $($state.ProcessId) for service '$Name' failed; waiting for SCM to settle: $terminationError"
        }
    }
    $timer.Restart()
    while ($timer.Elapsed.TotalSeconds -lt 10) {
        Start-Sleep -Milliseconds 500
        $state = Get-CorinaServiceNativeState -Name $Name
        if (-not $state -or $state.StateCode -eq 1) { return }
    }
    throw "Service '$Name' did not stop after its process was terminated."
}

function New-CorinaUpdaterMutex {
    param([Parameter(Mandatory)][string]$Name)
    $security = New-Object Security.AccessControl.MutexSecurity
    $rights = [Security.AccessControl.MutexRights]::FullControl
    foreach ($sidValue in @('S-1-5-18','S-1-5-32-544')) {
        $sid = New-Object Security.Principal.SecurityIdentifier($sidValue)
        $rule = New-Object Security.AccessControl.MutexAccessRule($sid, $rights, [Security.AccessControl.AccessControlType]::Allow)
        $security.AddAccessRule($rule)
    }
    $createdNew = $false
    try {
        $mutexAclType = [type]::GetType('System.Threading.MutexAcl, System.Threading.AccessControl', $false)
        if ($mutexAclType) {
            return [System.Threading.MutexAcl]::Create($false, $Name, [ref]$createdNew, $security)
        }
        # Windows PowerShell 5.1 exposes the ACL-aware constructor directly.
        return New-Object Threading.Mutex($false, $Name, [ref]$createdNew, $security)
    }
    catch [UnauthorizedAccessException] {
        throw "Access to updater mutex '$Name' was denied. Stop the older updater process or reboot once, then retry."
    }
}

function Enter-CorinaUpdaterMutex {
    param([Parameter(Mandatory)][Threading.Mutex]$Mutex, [int]$TimeoutMinutes = 5)
    try { return $Mutex.WaitOne([TimeSpan]::FromMinutes($TimeoutMinutes)) }
    catch [Threading.AbandonedMutexException] { return $true }
}

function Suspend-CorinaUpdaterTaskForUninstall {
    param($Task, [Parameter(Mandatory)][string]$TaskName)
    if (-not $Task) { return $false }
    $wasEnabled = [string]$Task.State -ne 'Disabled'
    if ($wasEnabled) { Disable-ScheduledTask -TaskName $TaskName | Out-Null }
    return $wasEnabled
}

function Restore-CorinaUpdaterTaskAfterFailedUninstall {
    param(
        [Parameter(Mandatory)][bool]$WasEnabled,
        [Parameter(Mandatory)][bool]$ServiceDeleted,
        [Parameter(Mandatory)][string]$TaskName
    )
    if (-not $ServiceDeleted -and $WasEnabled -and (Get-ScheduledTask -TaskName $TaskName -ErrorAction SilentlyContinue)) {
        Enable-ScheduledTask -TaskName $TaskName | Out-Null
    }
}

Write-Host "[*] Uninstalling $serviceName"
$updaterTask = Get-ScheduledTask -TaskName $taskName -ErrorAction SilentlyContinue
$updaterTaskWasEnabled = Suspend-CorinaUpdaterTaskForUninstall -Task $updaterTask -TaskName $taskName
$mutexName = if ($corinaRegistryInstance) { "Global\CorinaStagingUpdater-$corinaRegistryInstance" } else { 'Global\CorinaStagingUpdater' }
$mutex = $null
$mutexAcquired = $false
$serviceDeleted = $false
try {
    $mutex = New-CorinaUpdaterMutex -Name $mutexName
    $mutexAcquired = Enter-CorinaUpdaterMutex -Mutex $mutex
    if (-not $mutexAcquired) {
        throw "Another updater run did not finish within five minutes; uninstall was not started."
    }

    # The mutex proves no updater is in its deployment section. A stale task
    # state can now be cleared without interrupting file copy or rollback.
    if ($updaterTask) { Stop-ScheduledTask -TaskName $taskName -ErrorAction Stop }

    $service = Get-Service -Name $serviceName -ErrorAction SilentlyContinue
    # An updater task is equally invalid when its service was already absent.
    $serviceDeleted = -not [bool]$service
    if ($service) {
        Stop-CorinaServiceSafely -Name $serviceName
        & sc.exe delete $serviceName | Out-Null
        $deleteExitCode = $LASTEXITCODE
        if ($deleteExitCode -notin @(0, 1060, 1072)) {
            throw "sc.exe could not delete '$serviceName' (exit $deleteExitCode)."
        }
        $serviceDeleted = $true
        Write-Host "    -> Windows service $serviceName is absent or marked for deletion"
    }

    if ($updaterTask) {
        Unregister-ScheduledTask -TaskName $taskName -Confirm:$false
        Write-Host "    -> Removed scheduled task $taskName"
    }

    # The signed uninstaller ships inside the tree it deletes, so an administrator
    # who ran it from that folder holds the directory open as their working
    # directory and Remove-Item fails with "because it is in use". Step out first.
    Set-Location -LiteralPath "$env:SystemDrive\"
    if (Test-Path -LiteralPath $installDir) {
        Remove-Item -LiteralPath $installDir -Recurse -Force
        Write-Host "    -> Removed $installDir"
    }
    if (Test-Path -LiteralPath $stateRoot) {
        Remove-Item -LiteralPath $stateRoot -Recurse -Force
        Write-Host "    -> Removed updater cache, logs and rollback data at $stateRoot"
    }

    $legacyShim = if ($corinaRegistryInstance) { "C:\Scripts\$($script:CorinaLegacyShimBaseName)-$corinaRegistryInstance.ps1" } else { "C:\Scripts\$($script:CorinaLegacyShimBaseName).ps1" }
    if (Test-Path -LiteralPath $legacyShim -PathType Leaf) {
        Remove-Item -LiteralPath $legacyShim -Force
        Write-Host "    -> Removed obsolete downloader shim $legacyShim"
    }

    # Registry enrolment/token state is deliberately retained so a reinstall does not
    # silently destroy clinic identity. Remove it only through an explicit data-reset
    # procedure.
    Write-Host "SUCCESS: $serviceName was uninstalled. Registry enrolment state was retained."
}
catch {
    # Once the service is deleted, restoring its updater task would create a
    # broken scheduled task that can no longer update anything.
    try {
        Restore-CorinaUpdaterTaskAfterFailedUninstall `
            -WasEnabled $updaterTaskWasEnabled `
            -ServiceDeleted $serviceDeleted `
            -TaskName $taskName
    } catch { }
    throw
}
finally {
    if ($mutexAcquired) { try { $mutex.ReleaseMutex() } catch { } }
    if ($mutex) { $mutex.Dispose() }
}
