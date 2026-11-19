# Shared scheduled-task helper for Corina Service.
#
# This is a byte-stable, Authenticode-signed release asset. Callers must verify
# its manifest hash and signature before dot-sourcing it. It never downloads or
# generates PowerShell code. The task performs an independent Authenticode,
# thumbprint and CARE AI publisher preflight before invoking the installed updater.

Set-StrictMode -Version Latest

function Ensure-CorinaUpdaterTask {
    [CmdletBinding()]
    param(
        [string]$Instance,
        [Parameter(Mandatory)][string]$TaskName,
        [Parameter(Mandatory)][string]$UpdateRoot,
        [Parameter(Mandatory)][string]$RegistryPath,
        [string[]]$LegacyTaskNames = @(),
        [string[]]$LegacyShimPaths = @(),
        [switch]$ForceRecreate,
        [scriptblock]$Log = { param($Message) Write-Host "    -> $Message" }
    )

    if ($Instance -and $Instance -notmatch '^[A-Za-z0-9](?:[A-Za-z0-9_-]*[A-Za-z0-9])?$') {
        throw "Invalid Corina registry instance '$Instance'."
    }
    if ($TaskName -notmatch '^[A-Za-z][A-Za-z0-9_-]{2,127}$') {
        throw "Unsafe updater task name '$TaskName'."
    }

    $updaterPath = Join-Path $UpdateRoot 'daily-updater.ps1'
    if (-not (Test-Path -LiteralPath $updaterPath -PathType Leaf)) {
        throw "Verified updater script is missing: $updaterPath"
    }
    if (-not (Test-Path -LiteralPath $RegistryPath)) {
        throw "Corina registry path is missing: $RegistryPath"
    }

    foreach ($legacyTaskName in @($LegacyTaskNames | Select-Object -Unique)) {
        if ($legacyTaskName -and $legacyTaskName -ne $TaskName -and (Get-ScheduledTask -TaskName $legacyTaskName -ErrorAction SilentlyContinue)) {
            & $Log "Removing legacy scheduled task: $legacyTaskName"
            Unregister-ScheduledTask -TaskName $legacyTaskName -Confirm:$false
        }
    }

    # The preflight is intentionally part of the task action. It executes before
    # daily-updater.ps1 is loaded, preventing a modified on-disk updater from
    # gaining SYSTEM execution even when the machine execution policy is permissive.
    $quotedUpdater = $updaterPath.Replace("'", "''")
    $quotedRegistry = $RegistryPath.Replace("'", "''")
    $quotedInstance = if ($Instance) { $Instance.Replace("'", "''") } else { $null }
    $instanceInvocation = if ($quotedInstance) { "& `$scriptPath -Instance '$quotedInstance'" } else { '& $scriptPath' }

    $preflight = @"
`$ErrorActionPreference='Stop';
try {
  `$scriptPath='$quotedUpdater';
  `$registryPath='$quotedRegistry';
  `$stored=@((Get-ItemProperty -LiteralPath `$registryPath -Name TrustedSignerThumbprints -ErrorAction Stop).TrustedSignerThumbprints);
  `$allowed=@(`$stored | ForEach-Object { ([string]`$_).Replace(' ','').ToUpperInvariant() } | Where-Object { `$_ -match '^[0-9A-F]{40}$' } | Select-Object -Unique);
  if (`$allowed.Count -eq 0 -or `$allowed.Count -ne `$stored.Count) { throw 'Trusted signer registry state is empty or invalid.' };
  if (-not (Test-Path -LiteralPath `$scriptPath -PathType Leaf)) { throw 'Installed updater is missing.' };
  `$signature=Get-AuthenticodeSignature -FilePath `$scriptPath;
  if (`$signature.Status -ne 'Valid' -or -not `$signature.SignerCertificate) { throw ('Updater signature is not valid: '+`$signature.Status) };
  `$certificate=`$signature.SignerCertificate;
  `$thumbprint=`$certificate.Thumbprint.Replace(' ','').ToUpperInvariant();
  if (`$thumbprint -notin `$allowed) { throw 'Updater signer thumbprint is not trusted.' };
  `$simple=(`$certificate.GetNameInfo([Security.Cryptography.X509Certificates.X509NameType]::SimpleName,`$false) -replace '[^A-Za-z0-9]','').ToUpperInvariant();
  if (`$simple -cne 'CAREAIPTYLTD') { throw 'Updater publisher common name mismatch.' };
  `$subject=(([string]`$certificate.Subject) -replace '[^A-Za-z0-9=,.]','').ToUpperInvariant();
  if (`$subject -notmatch '(?:^|,)O=CAREAIPTYLTD(?:,|$)' -or `$subject -notmatch '(?:^|,)C=AU(?:,|$)' -or `$subject -notmatch '(?:^|,)(?:SERIALNUMBER|OID.2.5.4.5)=38681904512(?:,|$)') { throw 'Updater publisher identity mismatch.' };
  `$codeSigning=`$false; foreach (`$extension in `$certificate.Extensions) { if (`$extension.Oid.Value -eq '2.5.29.37') { `$eku=[Security.Cryptography.X509Certificates.X509EnhancedKeyUsageExtension]`$extension; if (`$eku.EnhancedKeyUsages | Where-Object { `$_.Value -eq '1.3.6.1.5.5.7.3.3' }) { `$codeSigning=`$true } } }; if (-not `$codeSigning) { throw 'Updater certificate lacks the code-signing EKU.' };
  $instanceInvocation;
  if (-not `$?) { throw 'Updater invocation failed.' };
  exit 0;
} catch { [Console]::Error.WriteLine('Corina updater preflight failed: '+`$_); exit 1 }
"@ -replace "[\r\n]+", ' '

    $powershellExe = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
    $taskArgument = "-NoLogo -NoProfile -NonInteractive -Command `"$preflight`""
    $taskAction = New-ScheduledTaskAction -Execute $powershellExe -Argument $taskArgument
    $principal = New-ScheduledTaskPrincipal -UserId SYSTEM -LogonType ServiceAccount -RunLevel Highest
    $settings = New-ScheduledTaskSettingsSet -MultipleInstances IgnoreNew -ExecutionTimeLimit (New-TimeSpan -Minutes 100) -StartWhenAvailable
    $desiredTimes = @('00:00', '07:00', '09:00', '11:00', '13:00', '15:00', '17:00')
    $triggers = @($desiredTimes | ForEach-Object {
        New-ScheduledTaskTrigger -Daily -At ([datetime]::ParseExact($_, 'HH:mm', [Globalization.CultureInfo]::InvariantCulture))
    })

    $existing = Get-ScheduledTask -TaskName $TaskName -ErrorAction SilentlyContinue
    if ($existing -and $ForceRecreate) {
        & $Log "Replacing existing scheduled task: $TaskName"
        Unregister-ScheduledTask -TaskName $TaskName -Confirm:$false
        $existing = $null
    }

    if ($existing) {
        Set-ScheduledTask -TaskName $TaskName -Action $taskAction -Trigger $triggers -Principal $principal -Settings $settings | Out-Null
        & $Log "Scheduled task '$TaskName' action and seven triggers refreshed."
    } else {
        Register-ScheduledTask -TaskName $TaskName -Action $taskAction -Trigger $triggers -Principal $principal -Settings $settings | Out-Null
        & $Log "Scheduled task '$TaskName' created with seven daily triggers."
    }

    foreach ($legacyShimPath in @($LegacyShimPaths | Select-Object -Unique)) {
        if ($legacyShimPath -and (Test-Path -LiteralPath $legacyShimPath -PathType Leaf)) {
            & $Log "Removing obsolete downloader shim: $legacyShimPath"
            Remove-Item -LiteralPath $legacyShimPath -Force -ErrorAction SilentlyContinue
        }
    }
}
