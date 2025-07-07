# daily-updater.ps1 — for staging
# Ensure Admin (optional but helpful in case script is manually run)
if (-not ([Security.Principal.WindowsPrincipal] `
    [Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole(`
    [Security.Principal.WindowsBuiltInRole] "Administrator")) {
    Write-Error "❌ You must run this script as Administrator."
    exit 1
}

# Logging
$logPath = "C:\Scripts\corina-update-log.txt"
"[$(Get-Date)] Running daily updater..." | Out-File -Append $logPath

try {
    irm https://raw.githubusercontent.com/Care-AI-Inc/careai-corina-service-staging-releases/main/install.ps1 | iex
    "[$(Get-Date)] ✅ Update succeeded" | Out-File -Append $logPath
} catch {
    "[$(Get-Date)] ❌ Update failed: $_" | Out-File -Append $logPath
}
