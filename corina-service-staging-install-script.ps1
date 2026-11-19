# Secure staging bootstrap template.
#
# Supply the immutable staging release version, the published SHA-256 for its
# install.ps1 asset, and the trusted CARE AI signing-certificate thumbprint.
# Clinic-specific enrolment values are written only after the installer has
# been authenticated. No network-delivered script is evaluated in memory.

[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [ValidatePattern('^(0|[1-9]\d*)\.(0|[1-9]\d*)\.(0|[1-9]\d*)$')]
    [string]$Version,

    [Parameter(Mandatory)]
    [ValidatePattern('^[0-9A-Fa-f]{64}$')]
    [string]$InstallerSha256,

    [Parameter(Mandatory)]
    [ValidatePattern('^[0-9A-Fa-f ]{40,79}$')]
    [string[]]$TrustedSignerThumbprints,

    [ValidatePattern('^[A-Za-z0-9](?:[A-Za-z0-9_-]*[A-Za-z0-9])?$')]
    [string]$Instance,

    [string]$HaloGuid,
    [string]$CorinaAgentToken
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$principal = [Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()
if (-not $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    throw 'You must run this staging bootstrap as Administrator.'
}

[Net.ServicePointManager]::SecurityProtocol =
    [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12

$normalizedTrusted = @($TrustedSignerThumbprints | ForEach-Object {
    ([string]$_).Replace(' ', '').ToUpperInvariant()
})
if ($normalizedTrusted.Count -eq 0 -or @($normalizedTrusted | Where-Object { $_ -notmatch '^[0-9A-F]{40}$' }).Count -gt 0) {
    throw 'Trusted signer thumbprints are empty or invalid.'
}
$trusted = @($normalizedTrusted | Select-Object -Unique)

$downloadRoot = Join-Path ([IO.Path]::GetTempPath()) ('corina-staging-bootstrap-' + [guid]::NewGuid().ToString('N'))
$installerPath = Join-Path $downloadRoot 'install.ps1'
$installerUri = "https://github.com/Care-AI-Inc/careai-corina-service-staging-releases/releases/download/staging-v$Version/install.ps1"
try {
    New-Item -ItemType Directory -Path $downloadRoot -Force | Out-Null
    Invoke-WebRequest -Uri $installerUri -OutFile $installerPath -UseBasicParsing

    $actualHash = (Get-FileHash -LiteralPath $installerPath -Algorithm SHA256).Hash.ToUpperInvariant()
    if ($actualHash -cne $InstallerSha256.ToUpperInvariant()) {
        throw "Installer SHA-256 '$actualHash' does not match the published value."
    }

    $signature = Get-AuthenticodeSignature -FilePath $installerPath
    if ($signature.Status -ne 'Valid' -or -not $signature.SignerCertificate) {
        throw "Installer Authenticode signature is not valid: $($signature.Status)."
    }
    $signerThumbprint = $signature.SignerCertificate.Thumbprint.Replace(' ', '').ToUpperInvariant()
    if ($signerThumbprint -notin $trusted) {
        throw "Installer signer thumbprint '$signerThumbprint' is not trusted."
    }

    $registryPath = 'HKLM:\SOFTWARE\CareAI\CorinaService-Staging'
    if ($Instance) { $registryPath = Join-Path $registryPath $Instance }
    if (-not (Test-Path -LiteralPath $registryPath)) {
        New-Item -Path $registryPath -Force | Out-Null
    }

    New-ItemProperty -Path $registryPath -Name DOTNET_ENVIRONMENT -PropertyType String -Value 'Staging' -Force | Out-Null
    New-ItemProperty -Path $registryPath -Name SamanthaBaseUrl -PropertyType String -Value 'https://backend.staging.caregp.com.au' -Force | Out-Null
    New-ItemProperty -Path $registryPath -Name SamanthaUrl -PropertyType String -Value 'https://backend.staging.caregp.com.au/corina/analyse-with-gemini-for-corina-service' -Force | Out-Null
    if (-not [string]::IsNullOrWhiteSpace($HaloGuid)) {
        New-ItemProperty -Path $registryPath -Name HaloGuid -PropertyType String -Value $HaloGuid -Force | Out-Null
    }
    if (-not [string]::IsNullOrWhiteSpace($CorinaAgentToken)) {
        New-ItemProperty -Path $registryPath -Name CorinaAgentToken -PropertyType String -Value $CorinaAgentToken -Force | Out-Null
    }
    if ($Instance) {
        New-ItemProperty -Path $registryPath -Name ClinicTag -PropertyType String -Value $Instance -Force | Out-Null
    }

    foreach ($legacySecretName in @(
            'SupabaseUrl',
            'SupabaseServiceKey',
            'SupabaseRealtimeUrl',
            'AWS_LOG_BUCKET',
            'AWS_ACCESS_KEY_ID',
            'AWS_SECRET_ACCESS_KEY',
            'AWS_REGION'
        )) {
        Remove-ItemProperty -LiteralPath $registryPath -Name $legacySecretName -ErrorAction SilentlyContinue
    }

    $env:DOTNET_ENVIRONMENT = 'Staging'
    if ($Instance) { $env:CorinaRegistryInstance = $Instance }
    if ($Instance) {
        & $installerPath -Instance $Instance -TrustedSignerThumbprints $trusted
    } else {
        & $installerPath -TrustedSignerThumbprints $trusted
    }
}
finally {
    Remove-Item -LiteralPath $downloadRoot -Recurse -Force -ErrorAction SilentlyContinue
}
