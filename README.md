# Corina Service staging releases

This repository is the publication target for signed Corina staging releases
and contains a reviewable staging mirror of the runtime scripts.

The canonical script source is
`Care-AI-Inc/careai-corina-service-releases`. The protected staging workflow in
`Care-AI-Inc/careai-corina-service` checks out an exact commit from that source,
transforms the approved staging constants, signs the final files, verifies the
complete bundle, and publishes it here under an immutable
`staging-v<version>` tag.

Repository copies are deliberately unsigned. `install.ps1` therefore contains
unresolved release identity placeholders and must not be executed directly from
`main`. Use a signed release asset or
`corina-service-staging-install-script.ps1` with the release's published SHA-256
and trusted signer thumbprint.

`daily-updater.ps1` retains the authenticated one-time legacy migration path so
older staging tasks that download this source file can move to the installed,
signed updater. New tasks execute the signed updater from Program Files and do
not download PowerShell code.

## Staging boundaries

- Service: `CorinaService-Staging[-<instance>]`
- Task: `CorinaStagingDailyUpdater[-<instance>]`
- Files: `C:\Program Files\CorinaService-Staging[\<instance>]`
- State: `C:\ProgramData\CareAI\CorinaService-Staging\...`
- Registry: `HKLM:\SOFTWARE\CareAI\CorinaService-Staging[\<instance>]`
- Backend: `https://backend.staging.caregp.com.au`
- Release repository: `Care-AI-Inc/careai-corina-service-staging-releases`
- Canonical script source: `Care-AI-Inc/careai-corina-service-releases`

## Tests

Run on Windows with Pester:

```powershell
Invoke-Pester -Script .\tests\Security.Tests.ps1
```
