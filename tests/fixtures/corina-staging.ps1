@{
    SchemaVersion = 1
    Channel = 'staging'
    Repository = 'Care-AI-Inc/careai-corina-service-staging-releases'
    ReleaseVersion = '9.8.7'
    Sequence = 987L
    PublishedUtc = '2026-07-22T00:00:00.000Z'
    Source = @{
        Repository = 'Care-AI-Inc/careai-corina-service'
        Commit = '1111111111111111111111111111111111111111'
        Ref = 'refs/tags/staging-v9.8.7'
        ScriptsRepository = 'Care-AI-Inc/careai-corina-service-releases'
        ScriptsCommit = '2222222222222222222222222222222222222222'
    }
    Signer = @{
        Subject = 'CN=CARE AI PTY LTD, SERIALNUMBER=38 681 904 512, O=CARE AI PTY LTD, C=AU'
        CertificateThumbprint = 'AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA'
        TimestampRequired = $true
    }
    NextSignerThumbprints = @(
        'BBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBB'
    )
    Assets = @{
        ServicePackage = @{
            FileName = 'corina-9.8.7-win-x64.zip'
            Url = 'https://github.com/Care-AI-Inc/careai-corina-service-staging-releases/releases/download/staging-v9.8.7/corina-9.8.7-win-x64.zip'
            Sha256 = 'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa'
            Size = 100000L
        }
        InstallerScript = @{
            FileName = 'install.ps1'
            Url = 'https://github.com/Care-AI-Inc/careai-corina-service-staging-releases/releases/download/staging-v9.8.7/install.ps1'
            Sha256 = 'bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb'
            Size = 1000L
        }
        UpdaterScript = @{
            FileName = 'daily-updater.ps1'
            Url = 'https://github.com/Care-AI-Inc/careai-corina-service-staging-releases/releases/download/staging-v9.8.7/daily-updater.ps1'
            Sha256 = 'cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc'
            Size = 2000L
        }
        TaskHelperScript = @{
            FileName = 'ensure-updater-task.ps1'
            Url = 'https://github.com/Care-AI-Inc/careai-corina-service-staging-releases/releases/download/staging-v9.8.7/ensure-updater-task.ps1'
            Sha256 = 'dddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddd'
            Size = 3000L
        }
        UninstallerScript = @{
            FileName = 'uninstall.ps1'
            Url = 'https://github.com/Care-AI-Inc/careai-corina-service-staging-releases/releases/download/staging-v9.8.7/uninstall.ps1'
            Sha256 = 'eeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeee'
            Size = 4000L
        }
    }
}
