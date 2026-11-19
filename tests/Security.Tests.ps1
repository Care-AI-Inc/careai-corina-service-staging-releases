Describe 'Corina release script static security policy' {
    BeforeAll {
        $repoRoot = Split-Path -Parent $PSScriptRoot
        $runtimeScripts = @(
            'install.ps1',
            'daily-updater.ps1',
            'ensure-updater-task.ps1',
            'uninstall.ps1',
            'run-daily-updater-staging.ps1',
            'corina-service-staging-install-script.ps1'
        )

        function Assert-CorinaEqual {
            param($Actual, $Expected)
            if ($Actual -ne $Expected) {
                throw "Expected '$Expected', got '$Actual'."
            }
        }

        function Assert-CorinaMatch {
            param([AllowNull()]$Actual, [string] $Pattern)
            if ([string]$Actual -notmatch $Pattern) {
                throw "Expected content to match '$Pattern'."
            }
        }

        function Assert-CorinaNotMatch {
            param([AllowNull()]$Actual, [string] $Pattern)
            if ([string]$Actual -match $Pattern) {
                throw "Expected content not to match '$Pattern'."
            }
        }
    }

    foreach ($scriptName in @(
            'install.ps1',
            'daily-updater.ps1',
            'ensure-updater-task.ps1',
            'uninstall.ps1',
            'run-daily-updater-staging.ps1',
            'corina-service-staging-install-script.ps1'
        )) {
        It "$scriptName parses without errors" -TestCases @{ ScriptName = $scriptName } {
            param($ScriptName)
            $tokens = $null
            $errors = $null
            [void][Management.Automation.Language.Parser]::ParseFile((Join-Path $repoRoot $ScriptName), [ref]$tokens, [ref]$errors)
            Assert-CorinaEqual -Actual $errors.Count -Expected 0
        }
    }

    It 'contains no network-to-expression or execution-policy bypass flow' {
        $all = ($runtimeScripts | ForEach-Object { Get-Content -LiteralPath (Join-Path $repoRoot $_) -Raw }) -join "`n"
        Assert-CorinaNotMatch -Actual $all -Pattern '(?i)raw\.githubusercontent\.com'
        Assert-CorinaNotMatch -Actual $all -Pattern '(?i)Invoke-Expression'
        Assert-CorinaNotMatch -Actual $all -Pattern '(?i)-ExecutionPolicy\s+Bypass'
        Assert-CorinaNotMatch -Actual $all -Pattern '(?i)Add-MpPreference|Unblock-File|CORINA_DISABLE_CRL'
        Assert-CorinaNotMatch -Actual $all -Pattern '(?i)api\.github\.com/.*/releases/latest'
    }

    It 'contains only staging deployment constants while retaining the canonical script source' {
        $all = ($runtimeScripts | ForEach-Object { Get-Content -LiteralPath (Join-Path $repoRoot $_) -Raw }) -join "`n"
        foreach ($required in @(
            "CorinaReleaseChannel = 'staging'",
            "CorinaReleaseRepository = 'Care-AI-Inc/careai-corina-service-staging-releases'",
            "CorinaScriptsSourceRepository = 'Care-AI-Inc/careai-corina-service-releases'",
            "CorinaServiceBaseName = 'CorinaService-Staging'",
            "CorinaTaskBaseName = 'CorinaStagingDailyUpdater'",
            "CorinaProgramFilesLeaf = 'CorinaService-Staging'",
            "CorinaProgramDataRoot = 'CareAI\CorinaService-Staging'",
            "CorinaRegistryRoot = 'HKLM:\SOFTWARE\CareAI\CorinaService-Staging'",
            "CorinaBackendBaseUrl = 'https://backend.staging.caregp.com.au'",
            "CorinaDotNetEnvironment = 'Staging'",
            "CorinaLegacyShimBaseName = 'run-daily-updater-staging'"
        )) {
            if (-not $all.Contains($required)) { throw "Required staging constant is missing: $required" }
        }
        foreach ($forbidden in @(
            "CorinaReleaseChannel = 'production'",
            "CorinaServiceBaseName = 'CorinaService'",
            "CorinaTaskBaseName = 'CorinaProdDailyUpdater'",
            "CorinaProgramFilesLeaf = 'CorinaService'",
            "CorinaProgramDataRoot = 'CareAI\CorinaService'",
            "CorinaRegistryRoot = 'HKLM:\SOFTWARE\CareAI\CorinaService'",
            "CorinaBackendBaseUrl = 'https://backend.agent.caregp.com.au'",
            "CorinaDotNetEnvironment = 'Production'",
            "CorinaLegacyShimBaseName = 'run-daily-updater-prod'"
        )) {
            if ($all.Contains($forbidden)) { throw "Production deployment constant remains in staging scripts: $forbidden" }
        }
    }

    It 'uses a staging-only updater mutex at every lifecycle lock point' {
        $lifecycleScripts = @('install.ps1', 'daily-updater.ps1', 'uninstall.ps1')
        $all = ($lifecycleScripts | ForEach-Object { Get-Content -LiteralPath (Join-Path $repoRoot $_) -Raw }) -join "`n"
        Assert-CorinaNotMatch -Actual $all -Pattern 'Global\\CorinaDailyUpdater'

        $lockAssignments = [regex]::Matches(
            $all,
            '(?m)^\s*\$(?:migrationMutexName|mutexName)\s*=.*Global\\CorinaStagingUpdater.*$'
        ).Count
        Assert-CorinaEqual -Actual $lockAssignments -Expected 4
    }

    It 'pins installer discovery and limits mutable discovery to the updater' {
        $installer = Get-Content -LiteralPath (Join-Path $repoRoot 'install.ps1') -Raw
        $updater = Get-Content -LiteralPath (Join-Path $repoRoot 'daily-updater.ps1') -Raw
        Assert-CorinaNotMatch -Actual $installer -Pattern 'releases/latest/download'
        Assert-CorinaMatch -Actual $installer -Pattern 'CorinaInstallerReleaseVersion'
        Assert-CorinaMatch -Actual $installer -Pattern 'ExpectedSequence'
        Assert-CorinaMatch -Actual $updater -Pattern 'releases/latest/download/.*ManifestFileName'
        Assert-CorinaMatch -Actual $installer -Pattern 'SafeGetValue'
        Assert-CorinaMatch -Actual $updater -Pattern 'SafeGetValue'
        Assert-CorinaMatch -Actual $installer -Pattern 'Get-AuthenticodeSignature'
        Assert-CorinaMatch -Actual $updater -Pattern 'Get-FileHash'
    }

    It 'authenticates the immutable staging bootstrap before writing enrollment values' {
        $bootstrap = Get-Content -LiteralPath (Join-Path $repoRoot 'corina-service-staging-install-script.ps1') -Raw
        Assert-CorinaMatch -Actual $bootstrap -Pattern '/releases/download/staging-v\$Version/install\.ps1'
        Assert-CorinaMatch -Actual $bootstrap -Pattern 'Get-FileHash'
        Assert-CorinaMatch -Actual $bootstrap -Pattern 'Get-AuthenticodeSignature'

        $signatureIndex = $bootstrap.IndexOf('Get-AuthenticodeSignature')
        $registryWriteIndex = $bootstrap.IndexOf('New-ItemProperty')
        $executeIndex = $bootstrap.IndexOf('& $installerPath')
        if ($signatureIndex -lt 0 -or $registryWriteIndex -le $signatureIndex -or $executeIndex -le $registryWriteIndex) {
            throw 'The staging bootstrap must authenticate, then enroll, then execute the installer.'
        }

        foreach ($requiredSetting in @('ClinicTag', 'SamanthaBaseUrl', 'SamanthaUrl', 'DOTNET_ENVIRONMENT')) {
            Assert-CorinaMatch -Actual $bootstrap -Pattern ("-Name " + [regex]::Escape($requiredSetting))
        }
        foreach ($legacySecret in @('SupabaseServiceKey', 'AWS_SECRET_ACCESS_KEY')) {
            Assert-CorinaMatch -Actual $bootstrap -Pattern ([regex]::Escape($legacySecret))
        }
        Assert-CorinaMatch -Actual $bootstrap -Pattern 'Remove-ItemProperty'
        Assert-CorinaMatch -Actual $bootstrap -Pattern '\$trusted = @\(\$normalizedTrusted \| Select-Object -Unique\)'
        Assert-CorinaNotMatch -Actual $bootstrap -Pattern '\$trusted\.Count -ne \$TrustedSignerThumbprints\.Count'
    }

    It 'migrates the legacy updater through authenticated release assets before signed self-validation' {
        $installer = Get-Content -LiteralPath (Join-Path $repoRoot 'install.ps1') -Raw
        $updaterPath = Join-Path $repoRoot 'daily-updater.ps1'
        $updater = Get-Content -LiteralPath $updaterPath -Raw
        $migrationIndex = $updater.IndexOf('if ($script:IsLegacyUnsignedBootstrap -and')
        $signedSelfValidationIndex = $updater.IndexOf('$null = Assert-CorinaSignedFile -Path $PSCommandPath')

        if ($migrationIndex -lt 0 -or $signedSelfValidationIndex -lt 0 -or $migrationIndex -gt $signedSelfValidationIndex) {
            throw 'Legacy migration must run before the signed updater self-validation path.'
        }

        # Walk executable top-level statements so TLS set up inside a function,
        # a comment, or after the migration conditional cannot satisfy the order.
        $tokens = $null
        $parseErrors = $null
        $updaterAst = [Management.Automation.Language.Parser]::ParseFile($updaterPath, [ref]$tokens, [ref]$parseErrors)
        $topLevelStatements = @($updaterAst.EndBlock.Statements)
        $tlsStatementIndex = -1
        $migrationStatementIndex = -1
        for ($i = 0; $i -lt $topLevelStatements.Count; $i++) {
            $statement = $topLevelStatements[$i]
            # Accept the assignment directly at top level or as a direct statement of a top-level try body.
            $candidates = if ($statement -is [Management.Automation.Language.TryStatementAst]) { @($statement.Body.Statements) } else { @($statement) }
            $tlsAssignments = @($candidates | Where-Object {
                $_ -is [Management.Automation.Language.AssignmentStatementAst] -and
                $_.Left.Extent.Text -ceq '[Net.ServicePointManager]::SecurityProtocol' -and
                $_.Right.Extent.Text -match '^\[Net\.ServicePointManager\]::SecurityProtocol\s+-bor\s+\[Net\.SecurityProtocolType\]::Tls12$'
            })
            if ($tlsStatementIndex -lt 0 -and $tlsAssignments.Count -gt 0) { $tlsStatementIndex = $i }
            if ($migrationStatementIndex -lt 0 -and
                $statement -is [Management.Automation.Language.IfStatementAst] -and
                $statement.Extent.Text.StartsWith('if ($script:IsLegacyUnsignedBootstrap -and')) {
                $migrationStatementIndex = $i
            }
        }
        if ($migrationStatementIndex -lt 0) {
            throw 'The legacy migration conditional must be a top-level updater statement.'
        }
        if ($tlsStatementIndex -lt 0 -or $tlsStatementIndex -gt $migrationStatementIndex) {
            throw 'TLS 1.2 must be enabled by a top-level statement before legacy migration can download its manifest.'
        }
        Assert-CorinaMatch -Actual $updater -Pattern 'LegacyBootstrapMinimumSequence\s*=\s*\[UInt64\]1000003000004'
        Assert-CorinaMatch -Actual $updater -Pattern "LegacySignerPlaceholder = '__CORINA_RELEASE_' \+ 'SIGNER_THUMBPRINTS__'"
        Assert-CorinaMatch -Actual $updater -Pattern 'SignatureStatus\]::NotSigned'
        Assert-CorinaMatch -Actual $updater -Pattern 'Read-CorinaReleaseManifest'
        Assert-CorinaMatch -Actual $updater -Pattern 'Receive-CorinaAsset'
        Assert-CorinaMatch -Actual $updater -Pattern 'RequireAuthenticode'
        Assert-CorinaMatch -Actual $updater -Pattern 'CorinaAgentToken is missing; the running service was not changed'
        Assert-CorinaMatch -Actual $updater -Pattern '\[IO\.FileShare\]::Read'
        Assert-CorinaNotMatch -Actual $installer -Pattern 'Ensure-CorinaUpdaterTask[^\r\n]+-ForceRecreate'
    }

    It 'never destroys existing registry enrolment state' {
        $installer = Get-Content -LiteralPath (Join-Path $repoRoot 'install.ps1') -Raw
        # Registry-provider New-Item -Force REPLACES an existing key, wiping
        # CorinaAgentToken/HaloGuid and every per-instance subkey. Creation of
        # the enrolment key must always be guarded by an existence check, and
        # exactly one (guarded) creation site may exist.
        Assert-CorinaMatch -Actual $installer -Pattern '(?s)if \(-not \(Test-Path -LiteralPath \$regPath\)\) \{\s*New-Item -Path \$regPath -Force'
        $creationSites = [regex]::Matches($installer, 'New-Item -Path \$regPath -Force').Count
        Assert-CorinaEqual -Actual $creationSites -Expected 1
    }

    It 'preserves the existing service account on reinstall and migration' {
        $installer = Get-Content -LiteralPath (Join-Path $repoRoot 'install.ps1') -Raw
        # Clinics with credentialed SMB/NAS shares run the service as a
        # per-site user; only a brand-new service may default to LocalSystem.
        Assert-CorinaMatch -Actual $installer -Pattern 'sc\.exe create [^\r\n]*obj= LocalSystem'
        Assert-CorinaNotMatch -Actual $installer -Pattern 'sc\.exe config [^\r\n]*obj='
    }

    It 'never reassigns a validated Instance parameter variable' {
        # Assigning $null back into a [ValidatePattern] parameter re-triggers
        # validation and throws on every default-instance machine. This list
        # previously omitted run-daily-updater-staging.ps1, which is exactly how
        # that file kept the defect after 0c955ea fixed it everywhere else:
        # it must cover EVERY runtime script that declares an $Instance param.
        foreach ($name in $runtimeScripts) {
            $content = Get-Content -LiteralPath (Join-Path $repoRoot $name) -Raw
            Assert-CorinaNotMatch -Actual $content -Pattern '(?m)^\s*\$Instance\s*='
        }
    }

    It 'never treats a bare @() wrap of a nullable value as a countable list' {
        # @($x) is not a safe array-wrap in this codebase. An untyped $null wraps
        # to a ONE-element array holding $null (so 'Count -eq 0' fallbacks never
        # fire), and an unbound typed [string[]] parameter wraps to $null itself
        # (so '.Count' throws outright under Set-StrictMode). Every nullable
        # source must be filtered through the pipeline before it is counted.
        foreach ($name in $runtimeScripts) {
            $content = Get-Content -LiteralPath (Join-Path $repoRoot $name) -Raw
            Assert-CorinaNotMatch -Actual $content -Pattern '@\(\$TrustedSignerThumbprints\)'
            Assert-CorinaNotMatch -Actual $content -Pattern '@\(\(Get-CorinaRegistryValue[^|\r\n]*\)\)'
            Assert-CorinaNotMatch -Actual $content -Pattern '(?<!@)\(Get-ChildItem[^\r\n]*\)\.Count'
        }
    }

    It 'reaches the trust fallbacks when no thumbprints are supplied' {
        # The uninstaller crashed at its first .Count before the registry and
        # built-in fallbacks could be consulted, so a bare `.\uninstall.ps1`
        # could never succeed on any clinic.
        $uninstaller = Get-Content -LiteralPath (Join-Path $repoRoot 'uninstall.ps1') -Raw
        Assert-CorinaMatch -Actual $uninstaller -Pattern '(?s)if \(\$null -ne \$TrustedSignerThumbprints\)[^\r\n]*\r?\n[^\r\n]*Where-Object'
        $updater = Get-Content -LiteralPath (Join-Path $repoRoot 'daily-updater.ps1') -Raw
        Assert-CorinaMatch -Actual $updater -Pattern 'storedTrusted[^\r\n]*Where-Object \{ -not \[string\]::IsNullOrWhiteSpace'
        Assert-CorinaMatch -Actual $updater -Pattern 'if \(\$storedTrusted\.Count -eq 0\) \{ \$storedTrusted = \$script:BuiltInTrustedSignerThumbprints \}'
    }

    It 'steps out of the install tree before deleting it' {
        # The signed uninstaller ships inside the directory it removes; an
        # administrator running it from that folder holds it open and the
        # delete fails with "because it is in use".
        $uninstaller = Get-Content -LiteralPath (Join-Path $repoRoot 'uninstall.ps1') -Raw
        $stepOutIndex = $uninstaller.IndexOf('Set-Location -LiteralPath "$env:SystemDrive\')
        $removeIndex = $uninstaller.IndexOf('Remove-Item -LiteralPath $installDir')
        if ($stepOutIndex -lt 0 -or $removeIndex -lt 0 -or $stepOutIndex -gt $removeIndex) {
            throw 'uninstall.ps1 must leave the install tree before removing it.'
        }
    }

    It 'recycles the service at local midnight only when already current' {
        $updater = Get-Content -LiteralPath (Join-Path $repoRoot 'daily-updater.ps1') -Raw
        $alreadyCurrentIndex = $updater.IndexOf('Already on authenticated release')
        $midnightIndex = $updater.IndexOf('(Get-Date).Hour -eq 0')
        $hygieneCallIndex = $updater.IndexOf('Restart-CorinaServiceForHygiene -Name $serviceName')
        $downloadIndex = $updater.IndexOf("foreach (`$role in @('InstallerScript','UpdaterScript','TaskHelperScript','UninstallerScript'))")
        if ($alreadyCurrentIndex -lt 0 -or $midnightIndex -lt 0 -or $hygieneCallIndex -lt 0) {
            throw 'Already-current midnight recycle path is missing.'
        }
        if ($midnightIndex -lt $alreadyCurrentIndex -or $hygieneCallIndex -lt $midnightIndex -or $downloadIndex -lt $hygieneCallIndex) {
            throw 'Midnight recycle must run only on the already-current path, before asset download.'
        }
        Assert-CorinaMatch -Actual $updater -Pattern 'StartWhenAvailable can fire hours later'
        Assert-CorinaMatch -Actual $updater -Pattern 'midnight recycle health check'
    }

    It 'preflights the updater before the SYSTEM task invokes it' {
        $helper = Get-Content -LiteralPath (Join-Path $repoRoot 'ensure-updater-task.ps1') -Raw
        Assert-CorinaMatch -Actual $helper -Pattern 'Get-AuthenticodeSignature'
        Assert-CorinaMatch -Actual $helper -Pattern 'TrustedSignerThumbprints'
        Assert-CorinaMatch -Actual $helper -Pattern 'CAREAIPTYLTD'
        Assert-CorinaNotMatch -Actual $helper -Pattern 'ExecutionPolicy'
        Assert-CorinaNotMatch -Actual $helper -Pattern 'Invoke-WebRequest|Invoke-RestMethod'
    }

    It 'uses bounded signer rotation rather than accumulating historical trust' {
        foreach ($name in @('install.ps1','daily-updater.ps1')) {
            $content = Get-Content -LiteralPath (Join-Path $repoRoot $name) -Raw
            # The merge must start from the signer that actually authenticated
            # this manifest, never from the previously trusted set.
            Assert-CorinaMatch -Actual $content -Pattern '@\(@\(\$manifest\._VerifiedSignerThumbprint\) \+ @\(\$manifest\.NextSignerThumbprints\)\)'
            Assert-CorinaNotMatch -Actual $content -Pattern '\$trusted \+ @\(\$manifest\.NextSignerThumbprints\)'
            # The earlier revision of this test pinned the unwrapped left operand
            # verbatim, which locked in a '[string] + [string[]]' concatenation
            # that fuses two thumbprints into one 80-character value. Assert the
            # broken shape can never come back.
            Assert-CorinaNotMatch -Actual $content -Pattern '@\(\$manifest\._VerifiedSignerThumbprint \+ '
        }
    }

    It 'merges the current and successor signers into separate thumbprints' {
        # Behavioural guard for the concatenation defect above: with a successor
        # announced, the merge must yield TWO 40-hex entries, not one 80-char one.
        $current = 'AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA'
        $successors = [string[]]@('BBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBB')
        $merged = @(@($current) + @($successors))
        Assert-CorinaEqual -Actual $merged.Count -Expected 2
        Assert-CorinaEqual -Actual $merged[0] -Expected $current
        Assert-CorinaEqual -Actual $merged[1] -Expected $successors[0]
        foreach ($entry in $merged) {
            if ($entry -notmatch '^[0-9A-F]{40}$') { throw "Merged trust entry '$entry' is not a single 40-hex thumbprint." }
        }
    }

    It 'limits ZIP entry count and expanded size before extraction' {
        foreach ($name in @('install.ps1','daily-updater.ps1')) {
            $content = Get-Content -LiteralPath (Join-Path $repoRoot $name) -Raw
            Assert-CorinaMatch -Actual $content -Pattern 'Entries.Count -gt 20000'
            Assert-CorinaMatch -Actual $content -Pattern '4294967296L'
            Assert-CorinaMatch -Actual $content -Pattern 'duplicate path'
        }
    }

    It 'keeps repository sources unsigned for final build-time signing' {
        foreach ($name in @('install.ps1','daily-updater.ps1','ensure-updater-task.ps1','uninstall.ps1')) {
            Assert-CorinaNotMatch `
                -Actual (Get-Content -LiteralPath (Join-Path $repoRoot $name) -Raw) `
                -Pattern '# SIG # Begin signature block'
        }
    }

    It 'uses a bounded native service stop instead of blocking Stop-Service' {
        foreach ($name in @('install.ps1','daily-updater.ps1','uninstall.ps1')) {
            $content = Get-Content -LiteralPath (Join-Path $repoRoot $name) -Raw
            Assert-CorinaNotMatch -Actual $content -Pattern '\bStop-Service\b'
            Assert-CorinaMatch -Actual $content -Pattern 'function Stop-CorinaServiceSafely'
            Assert-CorinaMatch -Actual $content -Pattern 'WaitForExit\(5000\)'
            Assert-CorinaNotMatch -Actual $content -Pattern 'WaitForExit\(\)'
            Assert-CorinaMatch -Actual $content -Pattern 'Stop-Process -Id \$state\.ProcessId -Force'
            Assert-CorinaMatch -Actual $content -Pattern 'Process exit can race Stop-Process'
        }
        foreach ($name in @('install.ps1','daily-updater.ps1')) {
            $content = Get-Content -LiteralPath (Join-Path $repoRoot $name) -Raw
            Assert-CorinaNotMatch -Actual $content -Pattern '\bStart-Service\b'
            Assert-CorinaMatch -Actual $content -Pattern 'function Start-CorinaServiceSafely'
        }
        $installer = Get-Content -LiteralPath (Join-Path $repoRoot 'install.ps1') -Raw
        $updater = Get-Content -LiteralPath (Join-Path $repoRoot 'daily-updater.ps1') -Raw
        $uninstaller = Get-Content -LiteralPath (Join-Path $repoRoot 'uninstall.ps1') -Raw
        Assert-CorinaMatch -Actual $installer -Pattern 'attempting restore: \$_" \}\s+Copy-CorinaTree'
        Assert-CorinaMatch -Actual $updater -Pattern 'attempting restore: \$_" WARN \}\s+Copy-CorinaTree'
        Assert-CorinaMatch -Actual $installer -Pattern 'failed new service before cleanup: \$_" \}\s+try \{\s+& sc\.exe delete'
        $disableIndex = $uninstaller.IndexOf('$updaterTaskWasEnabled = Suspend-CorinaUpdaterTaskForUninstall')
        $mutexIndex = $uninstaller.IndexOf('$mutexAcquired = Enter-CorinaUpdaterMutex -Mutex $mutex')
        $stopTaskIndex = $uninstaller.IndexOf('Stop-ScheduledTask -TaskName $taskName')
        $serviceRemovalIndex = $uninstaller.LastIndexOf('Stop-CorinaServiceSafely -Name $serviceName')
        $taskRemovalIndex = $uninstaller.IndexOf('Unregister-ScheduledTask -TaskName $taskName')
        if ($disableIndex -lt 0 -or $mutexIndex -lt $disableIndex -or $stopTaskIndex -lt $mutexIndex -or
            $serviceRemovalIndex -lt $stopTaskIndex -or $taskRemovalIndex -lt $serviceRemovalIndex) {
            throw 'Uninstall must disable the task, acquire the updater mutex, stop the task, then remove the service and task.'
        }
        Assert-CorinaMatch -Actual $uninstaller -Pattern '(?s)Restore-CorinaUpdaterTaskAfterFailedUninstall.*-WasEnabled \$updaterTaskWasEnabled.*-ServiceDeleted \$serviceDeleted'
        Assert-CorinaMatch -Actual $uninstaller -Pattern '(?s)\$service = Get-Service[^\r\n]+\r?\n\s*# An updater task is equally invalid when its service was already absent\.\r?\n\s*\$serviceDeleted = -not \[bool\]\$service'
        Assert-CorinaMatch -Actual $uninstaller -Pattern 'Stop-ScheduledTask -TaskName \$taskName -ErrorAction Stop'
        Assert-CorinaMatch -Actual $uninstaller -Pattern '\$deleteExitCode -notin @\(0, 1060, 1072\)'
        foreach ($content in @($installer, $updater, $uninstaller)) {
            Assert-CorinaMatch -Actual $content -Pattern 'Security\.AccessControl\.MutexSecurity'
            Assert-CorinaMatch -Actual $content -Pattern "S-1-5-18'.*'S-1-5-32-544"
        }
        $legacyMigrationIndex = $updater.LastIndexOf('Invoke-CorinaLegacySignedMigration')
        $legacyMutexIndex = $updater.IndexOf('Enter-CorinaUpdaterMutex -Mutex $migrationMutex')
        if ($legacyMutexIndex -lt 0 -or $legacyMigrationIndex -lt $legacyMutexIndex) {
            throw 'Legacy updater migration must acquire the shared updater mutex before running the installer.'
        }
    }
}

Describe 'Corina native service query parsing' {
    BeforeAll {
        $repoRoot = Split-Path -Parent $PSScriptRoot
        $parserModules = @{}
        foreach ($name in @('install.ps1','daily-updater.ps1','uninstall.ps1')) {
            $tokens = $null
            $errors = $null
            $ast = [Management.Automation.Language.Parser]::ParseFile((Join-Path $repoRoot $name), [ref]$tokens, [ref]$errors)
            $definitions = foreach ($functionName in @('ConvertFrom-CorinaServiceQueryOutput','Get-CorinaServiceNativeState')) {
                $node = $ast.Find({ param($n) $n -is [Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -eq $functionName }, $true)
                if (-not $node) { throw "Missing $functionName in $name." }
                $node.Extent.Text
            }
            $parserModules[$name] = New-Module -ScriptBlock ([scriptblock]::Create($definitions -join "`n"))
        }
        $runningQueryOutput = @(
            '',
            'SERVICE_NAME: CorinaService',
            '        TYPE               : 10  WIN32_OWN_PROCESS',
            '        STATE              : 4  RUNNING',
            '                                (STOPPABLE, NOT_PAUSABLE, ACCEPTS_SHUTDOWN)',
            '        WIN32_EXIT_CODE    : 0  (0x0)',
            '        SERVICE_EXIT_CODE  : 0  (0x0)',
            '        CHECKPOINT         : 0x0',
            '        WAIT_HINT          : 0x0',
            '        PID                : 3180',
            '        FLAGS              :'
        )
    }

    foreach ($name in @('install.ps1','daily-updater.ps1','uninstall.ps1')) {
        It "$name parses real sc.exe queryex output" -TestCases @{ ScriptName = $name } {
            param($ScriptName)
            $state = & $parserModules[$ScriptName] {
                param($Fixture)
                ConvertFrom-CorinaServiceQueryOutput -Output $Fixture -ExitCode 0 -Name 'CorinaService'
            } (,$runningQueryOutput)
            if ($state.StateCode -ne 4 -or $state.State -ne 'RUNNING' -or $state.ProcessId -ne 3180) {
                throw 'The native service query fixture was parsed incorrectly.'
            }
        }

        It "$name treats sc.exe exit 1060 as a missing service" -TestCases @{ ScriptName = $name } {
            param($ScriptName)
            $state = & $parserModules[$ScriptName] {
                ConvertFrom-CorinaServiceQueryOutput -Output @('[SC] OpenService FAILED 1060:') -ExitCode 1060 -Name 'CorinaService'
            }
            if ($null -ne $state) { throw 'A missing service was not returned as null.' }
        }

        It "$name treats sc.exe exit 1072 as a service already marked for deletion" -TestCases @{ ScriptName = $name } {
            param($ScriptName)
            $state = & $parserModules[$ScriptName] {
                ConvertFrom-CorinaServiceQueryOutput -Output @('[SC] OpenService FAILED 1072:') -ExitCode 1072 -Name 'CorinaService'
            }
            if ($null -ne $state) { throw 'A service marked for deletion was not returned as null.' }
        }

        It "$name rejects malformed successful query output" -TestCases @{ ScriptName = $name } {
            param($ScriptName)
            $thrown = $false
            try {
                & $parserModules[$ScriptName] {
                    ConvertFrom-CorinaServiceQueryOutput -Output @('unexpected output') -ExitCode 0 -Name 'CorinaService'
                }
            }
            catch { $thrown = $true }
            if (-not $thrown) { throw 'Malformed sc.exe output was accepted.' }
        }

        It "$name parses a live built-in Windows service query" -TestCases @{ ScriptName = $name } {
            param($ScriptName)
            if ([Environment]::OSVersion.Platform -ne [PlatformID]::Win32NT) { return }
            $state = & $parserModules[$ScriptName] { Get-CorinaServiceNativeState -Name 'EventLog' }
            if (-not $state -or $state.StateCode -notin 1..7 -or $state.ProcessId -lt 0) {
                throw 'The real sc.exe queryex output was not parsed into a valid service state.'
            }
            $missing = & $parserModules[$ScriptName] { Get-CorinaServiceNativeState -Name 'CorinaDefinitelyMissingService' }
            if ($null -ne $missing) { throw 'A real missing-service query did not return null.' }
        }
    }
}

Describe 'Corina duplicated helper consistency' {
    BeforeAll {
        $repoRoot = Split-Path -Parent $PSScriptRoot

        function Get-CorinaFunctionText {
            param([string]$ScriptName, [string]$FunctionName)
            $tokens = $null
            $errors = $null
            $ast = [Management.Automation.Language.Parser]::ParseFile((Join-Path $repoRoot $ScriptName), [ref]$tokens, [ref]$errors)
            $node = $ast.Find({ param($n) $n -is [Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -eq $FunctionName }, $true)
            if (-not $node) { throw "Missing $FunctionName in $ScriptName." }
            return ($node.Extent.Text -replace '\r\n', "`n").Trim()
        }

        $mutexFunctionText = foreach ($functionName in @('New-CorinaUpdaterMutex','Enter-CorinaUpdaterMutex')) {
            Get-CorinaFunctionText -ScriptName 'daily-updater.ps1' -FunctionName $functionName
        }
        $mutexModule = New-Module -ScriptBlock ([scriptblock]::Create($mutexFunctionText -join "`n"))
    }

    It 'keeps shared service helpers identical across all lifecycle scripts' {
        foreach ($functionName in @('ConvertFrom-CorinaServiceQueryOutput','Get-CorinaServiceNativeState','Stop-CorinaServiceSafely')) {
            $expected = Get-CorinaFunctionText -ScriptName 'install.ps1' -FunctionName $functionName
            foreach ($scriptName in @('daily-updater.ps1','uninstall.ps1')) {
                $actual = Get-CorinaFunctionText -ScriptName $scriptName -FunctionName $functionName
                if ($actual -cne $expected) { throw "$functionName differs between install.ps1 and $scriptName." }
            }
        }
    }

    It 'keeps the bounded start helper identical in installer and updater' {
        $installerText = Get-CorinaFunctionText -ScriptName 'install.ps1' -FunctionName 'Start-CorinaServiceSafely'
        $updaterText = Get-CorinaFunctionText -ScriptName 'daily-updater.ps1' -FunctionName 'Start-CorinaServiceSafely'
        if ($installerText -cne $updaterText) { throw 'Start-CorinaServiceSafely differs between installer and updater.' }
    }

    It 'keeps updater mutex helpers identical in all lifecycle scripts' {
        foreach ($functionName in @('New-CorinaUpdaterMutex','Enter-CorinaUpdaterMutex')) {
            $updaterText = Get-CorinaFunctionText -ScriptName 'daily-updater.ps1' -FunctionName $functionName
            foreach ($scriptName in @('install.ps1','uninstall.ps1')) {
                $actualText = Get-CorinaFunctionText -ScriptName $scriptName -FunctionName $functionName
                if ($updaterText -cne $actualText) { throw "$functionName differs between updater and $scriptName." }
            }
        }
    }

    It 'serializes installer mutation with update and uninstall' {
        $installer = Get-Content -LiteralPath (Join-Path $repoRoot 'install.ps1') -Raw
        $acquireIndex = $installer.IndexOf('$mutexAcquired = Enter-CorinaUpdaterMutex -Mutex $mutex')
        $serviceSnapshotIndex = $installer.IndexOf('$existingService = [bool](Get-Service -Name $serviceName')
        $releaseIndex = $installer.LastIndexOf('$mutex.ReleaseMutex()')
        if ($acquireIndex -lt 0 -or $serviceSnapshotIndex -lt $acquireIndex -or $releaseIndex -lt $serviceSnapshotIndex) {
            throw 'Installer must hold the shared mutex before reading or mutating service state.'
        }
    }

    It 'creates and acquires the ACL-aware mutex on the current PowerShell runtime' {
        $acquired = & $mutexModule {
            $mutexName = 'Local\CorinaUpdaterTest-' + [guid]::NewGuid().ToString('N')
            $mutex = New-CorinaUpdaterMutex -Name $mutexName
            try {
                $entered = Enter-CorinaUpdaterMutex -Mutex $mutex -TimeoutMinutes 0
                if ($entered) { $mutex.ReleaseMutex() }
                return $entered
            }
            finally { $mutex.Dispose() }
        }
        if (-not $acquired) { throw 'The ACL-aware updater mutex could not be acquired.' }
    }
}

Describe 'Corina uninstall updater task state behavior' {
    BeforeAll {
        $repoRoot = Split-Path -Parent $PSScriptRoot
        $tokens = $null
        $errors = $null
        $ast = [Management.Automation.Language.Parser]::ParseFile((Join-Path $repoRoot 'uninstall.ps1'), [ref]$tokens, [ref]$errors)
        $functionText = foreach ($functionName in @('Suspend-CorinaUpdaterTaskForUninstall','Restore-CorinaUpdaterTaskAfterFailedUninstall')) {
            $node = $ast.Find({ param($n) $n -is [Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -eq $functionName }, $true)
            if (-not $node) { throw "Missing $functionName in uninstall.ps1." }
            $node.Extent.Text
        }
        $taskModule = New-Module -ScriptBlock ([scriptblock]::Create($functionText -join "`n"))
    }

    It 'does not re-enable a task that was disabled before uninstall' {
        $result = & $taskModule {
            $script:disableCalls = 0
            $script:enableCalls = 0
            function Disable-ScheduledTask { param($TaskName) $script:disableCalls++ }
            function Enable-ScheduledTask { param($TaskName) $script:enableCalls++ }
            function Get-ScheduledTask { param($TaskName, $ErrorAction) return [pscustomobject]@{ State = 'Disabled' } }
            $wasEnabled = Suspend-CorinaUpdaterTaskForUninstall -Task ([pscustomobject]@{ State = 'Disabled' }) -TaskName 'Corina Daily Updater'
            Restore-CorinaUpdaterTaskAfterFailedUninstall -WasEnabled $wasEnabled -ServiceDeleted $false -TaskName 'Corina Daily Updater'
            return [pscustomobject]@{ WasEnabled = $wasEnabled; DisableCalls = $script:disableCalls; EnableCalls = $script:enableCalls }
        }
        if ($result.WasEnabled -or $result.DisableCalls -ne 0 -or $result.EnableCalls -ne 0) {
            throw 'A previously disabled updater task was changed.'
        }
    }

    It 'restores a task that uninstall temporarily disabled' {
        $result = & $taskModule {
            $script:disableCalls = 0
            $script:enableCalls = 0
            function Disable-ScheduledTask { param($TaskName) $script:disableCalls++ }
            function Enable-ScheduledTask { param($TaskName) $script:enableCalls++ }
            function Get-ScheduledTask { param($TaskName, $ErrorAction) return [pscustomobject]@{ State = 'Disabled' } }
            $wasEnabled = Suspend-CorinaUpdaterTaskForUninstall -Task ([pscustomobject]@{ State = 'Ready' }) -TaskName 'Corina Daily Updater'
            Restore-CorinaUpdaterTaskAfterFailedUninstall -WasEnabled $wasEnabled -ServiceDeleted $false -TaskName 'Corina Daily Updater'
            return [pscustomobject]@{ WasEnabled = $wasEnabled; DisableCalls = $script:disableCalls; EnableCalls = $script:enableCalls }
        }
        if (-not $result.WasEnabled -or $result.DisableCalls -ne 1 -or $result.EnableCalls -ne 1) {
            throw 'A temporarily disabled updater task was not restored.'
        }
    }

    It 'does not restore the updater task after service deletion succeeds' {
        $enableCalls = & $taskModule {
            $script:enableCalls = 0
            function Enable-ScheduledTask { param($TaskName) $script:enableCalls++ }
            function Get-ScheduledTask { param($TaskName, $ErrorAction) return [pscustomobject]@{ State = 'Disabled' } }
            Restore-CorinaUpdaterTaskAfterFailedUninstall `
                -WasEnabled $true `
                -ServiceDeleted $true `
                -TaskName 'Corina Daily Updater'
            return $script:enableCalls
        }
        if ($enableCalls -ne 0) { throw 'The updater task was restored after its service was deleted.' }
    }
}

Describe 'Corina bounded service stop behavior' {
    BeforeAll {
        $repoRoot = Split-Path -Parent $PSScriptRoot
        $stopModules = @{}
        foreach ($name in @('install.ps1','daily-updater.ps1','uninstall.ps1')) {
            $tokens = $null
            $errors = $null
            $ast = [Management.Automation.Language.Parser]::ParseFile((Join-Path $repoRoot $name), [ref]$tokens, [ref]$errors)
            $node = $ast.Find({ param($n) $n -is [Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -eq 'Stop-CorinaServiceSafely' }, $true)
            if (-not $node) { throw "Missing Stop-CorinaServiceSafely in $name." }
            $stopModules[$name] = New-Module -ScriptBlock ([scriptblock]::Create($node.Extent.Text))
        }
    }

    foreach ($name in @('install.ps1','daily-updater.ps1','uninstall.ps1')) {
        It "$name tolerates the service exiting as Stop-Process runs" -TestCases @{ ScriptName = $name } {
            param($ScriptName)
            $running = [pscustomobject]@{ StateCode = 3; State = 'STOP_PENDING'; ProcessId = 4242 }
            $stopped = [pscustomobject]@{ StateCode = 1; State = 'STOPPED'; ProcessId = 0 }
            $stopWasAttempted = & $stopModules[$ScriptName] {
                param($StateSequence)
                $script:states = [Collections.Queue]::new()
                foreach ($state in $StateSequence) { $script:states.Enqueue($state) }
                $script:stopWasAttempted = $false
                function Get-CorinaServiceNativeState { param($Name) return $script:states.Dequeue() }
                function Start-Process {
                    param($FilePath, $ArgumentList, [switch]$PassThru, $WindowStyle)
                    $process = [pscustomobject]@{}
                    $process | Add-Member -MemberType NoteProperty -Name ExitCode -Value 0
                    $process | Add-Member -MemberType ScriptMethod -Name WaitForExit -Value { param($Milliseconds) return $true }
                    return $process
                }
                function Start-Sleep { param($Milliseconds) }
                function Stop-Process {
                    param($Id, [switch]$Force, $ErrorAction)
                    $script:stopWasAttempted = $true
                    throw 'The process has already exited.'
                }
                Stop-CorinaServiceSafely -Name 'CorinaService' -GraceSeconds 0 -Log { param($Message) }
                return $script:stopWasAttempted
            } @(,$running, $running, $stopped)
            if (-not $stopWasAttempted) { throw 'The forced-stop race path was not exercised.' }
        }

        It "$name reports a failed native stop request" -TestCases @{ ScriptName = $name } {
            param($ScriptName)
            $running = [pscustomobject]@{ StateCode = 4; State = 'RUNNING'; ProcessId = 4242 }
            $stopped = [pscustomobject]@{ StateCode = 1; State = 'STOPPED'; ProcessId = 0 }
            $messages = & $stopModules[$ScriptName] {
                param($StateSequence)
                $script:states = [Collections.Queue]::new()
                foreach ($state in $StateSequence) { $script:states.Enqueue($state) }
                $script:messages = @()
                function Get-CorinaServiceNativeState { param($Name) return $script:states.Dequeue() }
                function Start-Process {
                    param($FilePath, $ArgumentList, [switch]$PassThru, $WindowStyle)
                    $process = [pscustomobject]@{ ExitCode = 1061 }
                    $process | Add-Member -MemberType ScriptMethod -Name WaitForExit -Value { param($Milliseconds) return $true }
                    return $process
                }
                $log = { param($Message) $script:messages += $Message }
                Stop-CorinaServiceSafely -Name 'CorinaService' -GraceSeconds 0 -Log $log
                return $script:messages
            } @(,$running, $stopped)
            if (($messages -join "`n") -notlike '*exit 1061*') { throw 'The native stop failure was not reported.' }
        }

        It "$name tolerates sc.exe exiting while its timed-out stop request is killed" -TestCases @{ ScriptName = $name } {
            param($ScriptName)
            $running = [pscustomobject]@{ StateCode = 4; State = 'RUNNING'; ProcessId = 4242 }
            $stopped = [pscustomobject]@{ StateCode = 1; State = 'STOPPED'; ProcessId = 0 }
            $completed = & $stopModules[$ScriptName] {
                param($StateSequence)
                $script:states = [Collections.Queue]::new()
                foreach ($state in $StateSequence) { $script:states.Enqueue($state) }
                function Get-CorinaServiceNativeState { param($Name) return $script:states.Dequeue() }
                function Start-Process {
                    param($FilePath, $ArgumentList, [switch]$PassThru, $WindowStyle)
                    $process = [pscustomobject]@{ WaitCalls = 0 }
                    $process | Add-Member -MemberType ScriptMethod -Name WaitForExit -Value {
                        param($Milliseconds)
                        $this.WaitCalls++
                        return $this.WaitCalls -gt 1
                    }
                    $process | Add-Member -MemberType ScriptMethod -Name Kill -Value { throw 'The process has already exited.' }
                    return $process
                }
                Stop-CorinaServiceSafely -Name 'CorinaService' -GraceSeconds 0 -Log { param($Message) }
                return $true
            } @(,$running, $stopped)
            if (-not $completed) { throw 'The timed-out sc.exe exit race was not tolerated.' }
        }

        It "$name waits for delayed SCM convergence after Stop-Process fails" -TestCases @{ ScriptName = $name } {
            param($ScriptName)
            $running = [pscustomobject]@{ StateCode = 4; State = 'RUNNING'; ProcessId = 4242 }
            $pending = [pscustomobject]@{ StateCode = 3; State = 'STOP_PENDING'; ProcessId = 4242 }
            $stopped = [pscustomobject]@{ StateCode = 1; State = 'STOPPED'; ProcessId = 0 }
            $completed = & $stopModules[$ScriptName] {
                param($StateSequence)
                $script:states = [Collections.Queue]::new()
                foreach ($state in $StateSequence) { $script:states.Enqueue($state) }
                function Get-CorinaServiceNativeState { param($Name) return $script:states.Dequeue() }
                function Start-Process {
                    param($FilePath, $ArgumentList, [switch]$PassThru, $WindowStyle)
                    $process = [pscustomobject]@{ ExitCode = 0 }
                    $process | Add-Member -MemberType ScriptMethod -Name WaitForExit -Value { param($Milliseconds) return $true }
                    return $process
                }
                function Start-Sleep { param($Milliseconds) }
                function Stop-Process { param($Id, [switch]$Force, $ErrorAction) throw 'Transient process lookup failure.' }
                Stop-CorinaServiceSafely -Name 'CorinaService' -GraceSeconds 0 -Log { param($Message) }
                return $true
            } @(,$running, $running, $pending, $pending, $stopped)
            if (-not $completed) { throw 'The helper did not wait for SCM to converge to STOPPED.' }
        }
    }
}

Describe 'Corina bounded service start behavior' {
    BeforeAll {
        $repoRoot = Split-Path -Parent $PSScriptRoot
        $startModules = @{}
        foreach ($name in @('install.ps1','daily-updater.ps1')) {
            $tokens = $null
            $errors = $null
            $ast = [Management.Automation.Language.Parser]::ParseFile((Join-Path $repoRoot $name), [ref]$tokens, [ref]$errors)
            $node = $ast.Find({ param($n) $n -is [Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -eq 'Start-CorinaServiceSafely' }, $true)
            if (-not $node) { throw "Missing Start-CorinaServiceSafely in $name." }
            $startModules[$name] = New-Module -ScriptBlock ([scriptblock]::Create($node.Extent.Text))
        }
    }

    foreach ($name in @('install.ps1','daily-updater.ps1')) {
        It "$name starts through a bounded native request" -TestCases @{ ScriptName = $name } {
            param($ScriptName)
            $stopped = [pscustomobject]@{ StateCode = 1; State = 'STOPPED'; ProcessId = 0 }
            $running = [pscustomobject]@{ StateCode = 4; State = 'RUNNING'; ProcessId = 4242 }
            $started = & $startModules[$ScriptName] {
                param($StateSequence)
                $script:states = [Collections.Queue]::new()
                foreach ($state in $StateSequence) { $script:states.Enqueue($state) }
                function Get-CorinaServiceNativeState { param($Name) return $script:states.Dequeue() }
                function Start-Process {
                    param($FilePath, $ArgumentList, [switch]$PassThru, $WindowStyle)
                    $process = [pscustomobject]@{ ExitCode = 0 }
                    $process | Add-Member -MemberType ScriptMethod -Name WaitForExit -Value { param($Milliseconds) return $true }
                    return $process
                }
                function Start-Sleep { param($Milliseconds) }
                Start-CorinaServiceSafely -Name 'CorinaService' -TimeoutSeconds 1
                return $true
            } @(,$stopped, $running)
            if (-not $started) { throw 'The bounded start path did not complete.' }
        }

        It "$name terminates a hung native start request" -TestCases @{ ScriptName = $name } {
            param($ScriptName)
            $stopped = [pscustomobject]@{ StateCode = 1; State = 'STOPPED'; ProcessId = 0 }
            $thrown = $false
            try {
                & $startModules[$ScriptName] {
                    param($State)
                    function Get-CorinaServiceNativeState { param($Name) return $State }
                    function Start-Process {
                        param($FilePath, $ArgumentList, [switch]$PassThru, $WindowStyle)
                        $process = [pscustomobject]@{ WasKilled = $false }
                        $process | Add-Member -MemberType ScriptMethod -Name WaitForExit -Value { param($Milliseconds) return $false }
                        $process | Add-Member -MemberType ScriptMethod -Name Kill -Value { $this.WasKilled = $true }
                        return $process
                    }
                    Start-CorinaServiceSafely -Name 'CorinaService' -TimeoutSeconds 0
                } $stopped
            }
            catch {
                if ($_.Exception.Message -notlike '*start request*timed out*') { throw }
                $thrown = $true
            }
            if (-not $thrown) { throw 'A hung native start request was accepted.' }
        }

        It "$name fails promptly when the service stops after a successful start request" -TestCases @{ ScriptName = $name } {
            param($ScriptName)
            $stopped = [pscustomobject]@{ StateCode = 1; State = 'STOPPED'; ProcessId = 0 }
            $thrown = $false
            try {
                & $startModules[$ScriptName] {
                    param($State)
                    function Get-CorinaServiceNativeState { param($Name) return $State }
                    function Start-Process {
                        param($FilePath, $ArgumentList, [switch]$PassThru, $WindowStyle)
                        $process = [pscustomobject]@{ ExitCode = 0 }
                        $process | Add-Member -MemberType ScriptMethod -Name WaitForExit -Value { param($Milliseconds) return $true }
                        return $process
                    }
                    function Start-Sleep { param($Milliseconds) }
                    Start-CorinaServiceSafely -Name 'CorinaService' -TimeoutSeconds 30
                } $stopped
            }
            catch {
                if ($_.Exception.Message -notlike '*stopped immediately*') { throw }
                $thrown = $true
            }
            if (-not $thrown) { throw 'An immediate post-start service crash was accepted.' }
        }
    }
}

Describe 'Corina deployment copy and repair' {
    BeforeAll {
        $repoRoot = Split-Path -Parent $PSScriptRoot
        $copyModules = @{}
        foreach ($name in @('install.ps1', 'daily-updater.ps1')) {
            $tokens = $null
            $errors = $null
            $ast = [Management.Automation.Language.Parser]::ParseFile((Join-Path $repoRoot $name), [ref]$tokens, [ref]$errors)
            $definitions = foreach ($functionName in @('Copy-CorinaTree', 'Get-CorinaSha256', 'Test-CorinaServiceVersion')) {
                $node = $ast.Find({ param($n) $n -is [Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -eq $functionName }, $true)
                if (-not $node) { throw "Missing $functionName in $name." }
                $node.Extent.Text
            }
            if ($name -eq 'daily-updater.ps1') {
                $gate = $ast.Find({ param($n) $n -is [Management.Automation.Language.IfStatementAst] -and $n.Extent.Text.StartsWith('if ([UInt64]$manifest.Sequence -eq $minimumSequence') }, $true)
                if (-not $gate) { throw 'Could not locate the same-release deployment gate.' }
                $definitions += 'function Invoke-TestUpdateGate { param($installDir, $manifest, $minimumSequence, $installedVersionText, $Hour = 12) function Write-CorinaLog {} function Get-Date { [pscustomobject]@{ Hour = $Hour } } function Restart-CorinaServiceForHygiene { param($Name) "recycle" } ' + $gate.Extent.Text + '; return "deploy" }'
            }
            $copyModules[$name] = New-Module -ScriptBlock ([scriptblock]::Create(($definitions -join "`n")))
        }
        $versionFixture = Join-Path $TestDrive 'version-fixture.dll'
        # Add-Type does not emit a Windows file-version resource on every
        # supported PowerShell runtime, so use a runtime DLL with a four-part
        # version ending in zero as the portable fixture.
        $versionFixtureSource = Get-ChildItem -LiteralPath $PSHOME -Filter '*.dll' -File | Where-Object {
            [Diagnostics.FileVersionInfo]::GetVersionInfo($_.FullName).FileVersion -match '^\d+\.\d+\.\d+\.0$'
        } | Select-Object -First 1
        if ($versionFixtureSource) {
            Copy-Item -LiteralPath $versionFixtureSource.FullName -Destination $versionFixture
        } else {
            # Windows PowerShell 5.1 has no suitable runtime DLL in $PSHOME,
            # but its Add-Type compiler emits the required file-version resource.
            $fixtureType = 'CorinaVersionFixture' + [guid]::NewGuid().ToString('N')
            $fixtureSource = '[assembly: System.Reflection.AssemblyFileVersion("1.4.4.0")] public class ' + $fixtureType + ' {}'
            Add-Type -TypeDefinition $fixtureSource -OutputAssembly $versionFixture
        }
        $fixtureFileVersion = [Diagnostics.FileVersionInfo]::GetVersionInfo($versionFixture).FileVersion
        if ($fixtureFileVersion -notmatch '^\d+\.\d+\.\d+\.0$') {
            throw "Versioned DLL test fixture has unsupported file version '$fixtureFileVersion'."
        }
        $fixtureReleaseVersion = $fixtureFileVersion.Substring(0, $fixtureFileVersion.Length - 2)
        $staleReleaseVersion = '999.999.999'
    }

    foreach ($name in @('install.ps1', 'daily-updater.ps1')) {
        It "$name replaces equal-size equal-time files with differing attributes" -TestCases @{ ScriptName = $name } {
            param($ScriptName)
            $source = Join-Path $TestDrive ($ScriptName + '-source')
            $destination = Join-Path $TestDrive ($ScriptName + '-destination')
            New-Item -ItemType Directory -Path $source, $destination -Force | Out-Null
            foreach ($file in @('.version', 'careai-corina-service.exe', 'careai-corina-service.dll', 'dependency.dll')) {
                $sourcePath = Join-Path $source $file
                $destinationPath = Join-Path $destination $file
                [IO.File]::WriteAllText($sourcePath, 'NEW')
                [IO.File]::WriteAllText($destinationPath, 'OLD')
                [IO.File]::SetLastWriteTimeUtc($sourcePath, [datetime]'1980-01-01')
                [IO.File]::SetLastWriteTimeUtc($destinationPath, [datetime]'1980-01-01')
                [IO.File]::SetAttributes($sourcePath, [IO.FileAttributes]::Archive)
                [IO.File]::SetAttributes($destinationPath, [IO.FileAttributes]::Normal)
            }
            & $copyModules[$ScriptName] { param($s, $d) Copy-CorinaTree -Source $s -Destination $d -Mirror -VerifyContents } $source $destination
            foreach ($file in @('.version', 'careai-corina-service.exe', 'careai-corina-service.dll', 'dependency.dll')) {
                if ([IO.File]::ReadAllText((Join-Path $destination $file)) -cne 'NEW') { throw "$file was left stale." }
            }
        }

        It "$name rejects a DLL copy whose bytes do not match" -TestCases @{ ScriptName = $name } {
            param($ScriptName)
            $source = Join-Path $TestDrive ($ScriptName + '-hash-source')
            $destination = Join-Path $TestDrive ($ScriptName + '-hash-destination')
            New-Item -ItemType Directory -Path $source, $destination -Force | Out-Null
            [IO.File]::WriteAllText((Join-Path $source 'careai-corina-service.dll'), 'NEW')
            $thrown = $false
            try {
                & $copyModules[$ScriptName] {
                    param($s, $d)
                    # Simulate a copy operation returning success without replacing the DLL.
                    function robocopy { $global:LASTEXITCODE = 0 }
                    function Copy-Item { param($LiteralPath, $Destination, [switch]$Force, $ErrorAction) [IO.File]::WriteAllText($Destination, 'OLD') }
                    Copy-CorinaTree -Source $s -Destination $d -Mirror -VerifyContents
                } $source $destination
            } catch {
                if ($_.Exception.Message -notlike '*post-copy hash check*') { throw }
                $thrown = $true
            }
            if (-not $thrown) { throw 'A corrupted DLL copy was accepted.' }
        }

        It "$name detects a stale DLL despite a current version marker" -TestCases @{ ScriptName = $name } {
            param($ScriptName)
            $directory = Join-Path $TestDrive ($ScriptName + '-version')
            New-Item -ItemType Directory -Path $directory -Force | Out-Null
            Copy-Item -LiteralPath $versionFixture -Destination (Join-Path $directory 'careai-corina-service.dll')
            [IO.File]::WriteAllText((Join-Path $directory '.version'), $staleReleaseVersion)
            $matches = & $copyModules[$ScriptName] { param($d, $v) Test-CorinaServiceVersion -Directory $d -ReleaseVersion $v } $directory $staleReleaseVersion
            if ($matches) { throw 'A stale DLL was accepted because its marker was current.' }
            $matches = & $copyModules[$ScriptName] { param($d, $v) Test-CorinaServiceVersion -Directory $d -ReleaseVersion $v } $directory $fixtureReleaseVersion
            if (-not $matches) { throw 'A matching DLL version was rejected.' }
            if ($ScriptName -eq 'daily-updater.ps1') {
                $decision = & $copyModules[$ScriptName] { param($d, $v) Invoke-TestUpdateGate $d @{ ReleaseVersion = $v; Sequence = 5 } 5 $v } $directory $staleReleaseVersion
                if ($decision -cne 'deploy') { throw 'The updater skipped a same-release repair.' }
                $decision = & $copyModules[$ScriptName] { param($d, $v) Invoke-TestUpdateGate $d @{ ReleaseVersion = $v; Sequence = 4 } 4 $v } $directory $fixtureReleaseVersion
                if ($null -ne $decision) { throw 'The updater redeployed an already matching release.' }
                $decision = & $copyModules[$ScriptName] { param($d, $stale, $current) Invoke-TestUpdateGate $d @{ ReleaseVersion = $stale; Sequence = 5 } 4 $current } $directory $staleReleaseVersion $fixtureReleaseVersion
                if ($decision -cne 'deploy') { throw 'The updater skipped a newer release.' }
                $decision = & $copyModules[$ScriptName] { param($d, $v) Invoke-TestUpdateGate $d @{ ReleaseVersion = $v; Sequence = 4 } 4 $v 0 } $directory $fixtureReleaseVersion
                if ($decision -cne 'recycle') { throw 'A current service skipped its midnight restart.' }
                $decision = & $copyModules[$ScriptName] { param($d, $v) Invoke-TestUpdateGate $d @{ ReleaseVersion = $v; Sequence = 5 } 5 $v 0 } $directory $staleReleaseVersion
                if ($decision -cne 'deploy') { throw 'A stale service restarted instead of repairing at midnight.' }
            }
        }

        It "$name requires repair when the DLL is missing or has no version" -TestCases @{ ScriptName = $name } {
            param($ScriptName)
            $directory = Join-Path $TestDrive ($ScriptName + '-missing')
            New-Item -ItemType Directory -Path $directory -Force | Out-Null
            $matches = & $copyModules[$ScriptName] { param($d) Test-CorinaServiceVersion -Directory $d -ReleaseVersion '1.4.4' } $directory
            if ($matches) { throw 'A missing DLL was accepted.' }
            [IO.File]::WriteAllText((Join-Path $directory 'careai-corina-service.dll'), 'invalid')
            $matches = & $copyModules[$ScriptName] { param($d) Test-CorinaServiceVersion -Directory $d -ReleaseVersion '1.4.4' } $directory
            if ($matches) { throw 'An unversioned DLL was accepted.' }
        }
    }
}

Describe 'Signed data-only manifest contract' {
    BeforeAll {
        $repoRoot = Split-Path -Parent $PSScriptRoot

        function Assert-CorinaEqual {
            param($Actual, $Expected)
            if ($Actual -ne $Expected) {
                throw "Expected '$Expected', got '$Actual'."
            }
        }

        function Assert-CorinaThrows {
            param([scriptblock] $Action)
            try {
                & $Action
            }
            catch {
                return
            }
            throw 'Expected the action to throw, but it completed successfully.'
        }

        $installerPath = Join-Path $repoRoot 'install.ps1'
        $tokens = $null
        $errors = $null
        $installerAst = [Management.Automation.Language.Parser]::ParseFile($installerPath, [ref]$tokens, [ref]$errors)
        $functionNames = @('ConvertTo-CorinaThumbprintList','Get-CorinaCertificateSubjectAttribute','ConvertTo-CorinaIdentityValue','Assert-CorinaAssetDefinition','Read-CorinaReleaseManifest')
        $definitions = foreach ($functionName in $functionNames) {
            $node = $installerAst.Find({ param($ast) $ast -is [Management.Automation.Language.FunctionDefinitionAst] -and $ast.Name -eq $functionName }, $true)
            if (-not $node) { throw "Test could not locate $functionName in install.ps1." }
            $node.Extent.Text
        }
        $moduleText = @"
`$script:CorinaReleaseChannel = 'staging'
`$script:CorinaReleaseRepository = 'Care-AI-Inc/careai-corina-service-staging-releases'
`$script:CorinaServiceSourceRepository = 'Care-AI-Inc/careai-corina-service'
`$script:CorinaScriptsSourceRepository = 'Care-AI-Inc/careai-corina-service-releases'
function Assert-CorinaSignedFile {
    param([string]`$Path,[string[]]`$AllowedThumbprints)
    `$certificate = [pscustomobject]@{
        Subject = 'CN=CARE AI PTY LTD, SERIALNUMBER=38 681 904 512, O=CARE AI PTY LTD, C=AU'
        Thumbprint = 'AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA'
    }
    return [pscustomobject]@{ SignerCertificate = `$certificate; TimeStamperCertificate = [object]::new() }
}
$($definitions -join "`n")
Export-ModuleMember -Function Read-CorinaReleaseManifest,Get-CorinaCertificateSubjectAttribute,ConvertTo-CorinaIdentityValue
"@
        $contractModule = New-Module -ScriptBlock ([scriptblock]::Create($moduleText))
        Import-Module $contractModule -Force
        $fixture = Join-Path $PSScriptRoot 'fixtures\corina-staging.ps1'
    }

    AfterAll {
        if ($contractModule) { Remove-Module $contractModule -Force -ErrorAction SilentlyContinue }
    }

    It 'accepts the build-pipeline schema fixture' {
        $manifest = Read-CorinaReleaseManifest -Path $fixture -AllowedThumbprints @('AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA') -MinimumSequence 1
        Assert-CorinaEqual -Actual $manifest.ReleaseVersion -Expected '9.8.7'
        Assert-CorinaEqual -Actual $manifest.Assets.Count -Expected 5
        Assert-CorinaEqual -Actual $manifest.NextSignerThumbprints[0] -Expected 'BBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBB'
        Assert-CorinaEqual -Actual $manifest._VerifiedSignerThumbprint -Expected 'AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA'
    }

    It 'rejects an executable manifest even after the signature stub succeeds' {
        $badPath = Join-Path $TestDrive 'executable-manifest.ps1'
        "Get-Process`n" | Set-Content -LiteralPath $badPath
        Assert-CorinaThrows -Action {
            Read-CorinaReleaseManifest -Path $badPath -AllowedThumbprints @('AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA') -MinimumSequence 1
        }
    }

    It 'rejects an asset URL outside the exact immutable release tag' {
        $badPath = Join-Path $TestDrive 'mutable-url.ps1'
        (Get-Content -LiteralPath $fixture -Raw).Replace('/releases/download/staging-v9.8.7/install.ps1', '/raw/main/install.ps1') | Set-Content -LiteralPath $badPath
        Assert-CorinaThrows -Action {
            Read-CorinaReleaseManifest -Path $badPath -AllowedThumbprints @('AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA') -MinimumSequence 1
        }
    }

    It 'rejects rollback sequences' {
        Assert-CorinaThrows -Action {
            Read-CorinaReleaseManifest -Path $fixture -AllowedThumbprints @('AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA') -MinimumSequence 988
        }
    }

    It 'normalizes the real SSL.com CARE AI X.500 subject rendering' {
        $realSubject = (Get-Content -LiteralPath (Join-Path $PSScriptRoot 'fixtures\care-ai-real-subject.txt') -Raw).Trim()
        Assert-CorinaEqual `
            -Actual (ConvertTo-CorinaIdentityValue (Get-CorinaCertificateSubjectAttribute -Subject $realSubject -Names @('O'))) `
            -Expected 'CAREAIPTYLTD'
        Assert-CorinaEqual `
            -Actual (ConvertTo-CorinaIdentityValue (Get-CorinaCertificateSubjectAttribute -Subject $realSubject -Names @('C'))) `
            -Expected 'AU'
        Assert-CorinaEqual `
            -Actual (ConvertTo-CorinaIdentityValue (Get-CorinaCertificateSubjectAttribute -Subject $realSubject -Names @('SERIALNUMBER','OID.2.5.4.5'))) `
            -Expected '38681904512'
    }
}
