# DEPRECATED compatibility launcher.
#
# New installations do not deploy or schedule this file. The scheduled task
# performs its own preflight and launches the signed updater under Program Files.
# This launcher exists only for administrators migrating an old C:\Scripts task;
# it performs no download and refuses an untrusted installed updater.

[CmdletBinding()]
param(
    [ValidatePattern('^[A-Za-z0-9](?:[A-Za-z0-9_-]*[A-Za-z0-9])?$')]
    [string]$Instance
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# Assign the fallback to a separate variable: writing $null back into the
# [ValidatePattern] parameter variable re-triggers validation and always throws
# on default-instance machines where the environment variable is unset. This is
# the same defect fixed in uninstall.ps1 by 0c955ea, which missed this file.
$corinaRegistryInstance = $Instance
if ([string]::IsNullOrWhiteSpace($corinaRegistryInstance)) { $corinaRegistryInstance = [Environment]::GetEnvironmentVariable('CorinaRegistryInstance', [EnvironmentVariableTarget]::Process) }
if ($corinaRegistryInstance -and $corinaRegistryInstance -notmatch '^[A-Za-z0-9](?:[A-Za-z0-9_-]*[A-Za-z0-9])?$') { throw 'Invalid Corina registry instance.' }
$serviceName = if ($corinaRegistryInstance) { "CorinaService-Staging-$corinaRegistryInstance" } else { 'CorinaService-Staging' }
$registryPath = 'HKLM:\SOFTWARE\CareAI\CorinaService-Staging'
if ($corinaRegistryInstance) { $registryPath = Join-Path $registryPath $corinaRegistryInstance }

$stored = @((Get-ItemProperty -LiteralPath $registryPath -Name TrustedSignerThumbprints -ErrorAction Stop).TrustedSignerThumbprints)
$allowed = @($stored | ForEach-Object { ([string]$_).Replace(' ', '').ToUpperInvariant() } | Where-Object { $_ -match '^[0-9A-F]{40}$' } | Select-Object -Unique)
if ($allowed.Count -eq 0 -or $allowed.Count -ne $stored.Count) { throw 'Trusted signer registry state is empty or invalid.' }

$service = Get-CimInstance Win32_Service -Filter "Name='$serviceName'" -ErrorAction Stop
if (-not $service) { throw "Service '$serviceName' is not installed." }
$match = [regex]::Match([string]$service.PathName, '^[\s"]*(?<exe>[^"\r\n]+?\.exe)')
if (-not $match.Success) { throw 'Could not resolve the Corina install directory.' }
$updaterPath = Join-Path (Join-Path (Split-Path -Parent $match.Groups['exe'].Value.Trim()) 'Update') 'daily-updater.ps1'

$signature = Get-AuthenticodeSignature -FilePath $updaterPath
if ($signature.Status -ne 'Valid' -or -not $signature.SignerCertificate) { throw "Installed updater signature is not valid: $($signature.Status)." }
$certificate = $signature.SignerCertificate
$thumbprint = $certificate.Thumbprint.Replace(' ', '').ToUpperInvariant()
if ($thumbprint -notin $allowed) { throw 'Installed updater signer thumbprint is not trusted.' }
$simpleName = ($certificate.GetNameInfo([Security.Cryptography.X509Certificates.X509NameType]::SimpleName, $false) -replace '[^A-Za-z0-9]', '').ToUpperInvariant()
if ($simpleName -cne 'CAREAIPTYLTD') { throw 'Installed updater publisher common name mismatch.' }
$subject = (([string]$certificate.Subject) -replace '[^A-Za-z0-9=,.]', '').ToUpperInvariant()
if ($subject -notmatch '(?:^|,)O=CAREAIPTYLTD(?:,|$)' -or
    $subject -notmatch '(?:^|,)C=AU(?:,|$)' -or
    $subject -notmatch '(?:^|,)(?:SERIALNUMBER|OID\.2\.5\.4\.5)=38681904512(?:,|$)') {
    throw 'Installed updater publisher identity mismatch.'
}
$hasCodeSigningEku = $false
foreach ($extension in $certificate.Extensions) {
    if ($extension.Oid.Value -eq '2.5.29.37') {
        $eku = [Security.Cryptography.X509Certificates.X509EnhancedKeyUsageExtension]$extension
        if ($eku.EnhancedKeyUsages | Where-Object { $_.Value -eq '1.3.6.1.5.5.7.3.3' }) { $hasCodeSigningEku = $true }
    }
}
if (-not $hasCodeSigningEku) { throw 'Installed updater certificate lacks the code-signing EKU.' }

if ($corinaRegistryInstance) { & $updaterPath -Instance $corinaRegistryInstance } else { & $updaterPath }
