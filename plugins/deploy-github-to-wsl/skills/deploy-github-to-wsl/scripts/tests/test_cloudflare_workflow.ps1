[CmdletBinding()]
param(
    [string]$Distro = 'Ubuntu'
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
[Console]::OutputEncoding = [Text.UTF8Encoding]::new($false)

Import-Module (Join-Path $PSScriptRoot '..\CloudflareApi.psm1') -Force

function Assert-True {
    param([bool]$Condition, [string]$Message)
    if (-not $Condition) { throw $Message }
}

function Invoke-CloudflareCommand {
    param([string]$Action, [string]$ManifestPath, [string]$Target = 'All')

    $parameters = @{
        Action = $Action
        ManifestPath = $ManifestPath
        CredentialPath = $script:CredentialPath
        AccessCredentialPath = $script:AccessCredentialPath
        ApiBaseUri = $script:ApiBaseUri
        AllowInsecureLoopbackForTest = $true
        Compact = $true
    }
    if ($Action -eq 'Apply') { $parameters.Target = $Target }
    $text = & (Join-Path $PSScriptRoot '..\cloudflare.ps1') @parameters
    Assert-True ($LASTEXITCODE -eq 0) "Cloudflare $Action 应成功；返回：$($text -join '')"
    return ($text -join "`n") | ConvertFrom-Json -Depth 40
}

$testRoot = Join-Path ([IO.Path]::GetTempPath()) ('deploy-github-to-wsl-workflow-' + [Guid]::NewGuid().ToString('N'))
[IO.Directory]::CreateDirectory($testRoot) | Out-Null
$script:CredentialPath = Join-Path $testRoot 'cloudflare-public.bin'
$script:AccessCredentialPath = Join-Path $testRoot 'cloudflare-access.bin'
$fakeToken = 'fake-public-token-for-local-tests-only-1234567890'
$testSlug = 'automation-test'
$testStateDirectory = "/root/.local/state/deploy-github-to-wsl/$testSlug"
$testConfigDirectory = "/root/.config/deploy-github-to-wsl/$testSlug"
$testStatePath = "$testStateDirectory/deployment.json"
$protectedSlug = 'protected-test'
$protectedStateDirectory = "/root/.local/state/deploy-github-to-wsl/$protectedSlug"
$protectedConfigDirectory = "/root/.config/deploy-github-to-wsl/$protectedSlug"
$serverProcess = $null

try {
    & wsl.exe -d $Distro -- test '!' -e $testStateDirectory
    Assert-True ($LASTEXITCODE -eq 0) '测试状态目录已存在，拒绝覆盖。'
    & wsl.exe -d $Distro -- test '!' -e $testConfigDirectory
    Assert-True ($LASTEXITCODE -eq 0) '测试配置目录已存在，拒绝覆盖。'
    foreach ($path in @($protectedStateDirectory, $protectedConfigDirectory)) {
        & wsl.exe -d $Distro -- test '!' -e $path
        Assert-True ($LASTEXITCODE -eq 0) "Access 测试目录已存在，拒绝覆盖：$path"
    }

    $startInfo = [Diagnostics.ProcessStartInfo]::new((Get-Command py -ErrorAction Stop).Source)
    $startInfo.ArgumentList.Add('-3')
    $startInfo.ArgumentList.Add((Join-Path $PSScriptRoot 'mock_cloudflare_api.py'))
    $startInfo.ArgumentList.Add('--seed-fangdai')
    $startInfo.RedirectStandardOutput = $true
    $startInfo.RedirectStandardError = $true
    $startInfo.UseShellExecute = $false
    $startInfo.CreateNoWindow = $true
    $serverProcess = [Diagnostics.Process]::Start($startInfo)
    $port = [int]$serverProcess.StandardOutput.ReadLine()
    $script:ApiBaseUri = [uri]"http://127.0.0.1:$port/client/v4"

    Set-Clipboard -Value $fakeToken
    $initializeParameters = @{
        Action = 'InitializeCredential'
        CredentialPath = $script:CredentialPath
        AccountId = 'a' * 32
        ZoneName = 'scuccs.me'
        ApiBaseUri = $script:ApiBaseUri
        AllowInsecureLoopbackForTest = $true
        Compact = $true
    }
    $initializeText = & (Join-Path $PSScriptRoot '..\cloudflare.ps1') @initializeParameters
    Assert-True ($LASTEXITCODE -eq 0) '公共部署凭据初始化应成功。'
    $initialize = ($initializeText -join "`n") | ConvertFrom-Json
    Assert-True ($initialize.stored -and $initialize.clipboardCleared) '初始化结果应确认 DPAPI 保存和剪贴板清理。'
    Assert-True (-not [string](Get-Clipboard -Raw)) '初始化成功后剪贴板必须为空。'
    Assert-True (-not (($initializeText -join '')).Contains($fakeToken)) '初始化输出不得包含 API Token。'

    Set-Clipboard -Value $fakeToken
    $accessInitializeParameters = @{
        Action = 'InitializeCredential'
        CredentialProfile = 'access'
        CredentialPath = $script:AccessCredentialPath
        AccountId = 'a' * 32
        ApiBaseUri = $script:ApiBaseUri
        AllowInsecureLoopbackForTest = $true
        Compact = $true
    }
    $accessInitializeText = & (Join-Path $PSScriptRoot '..\cloudflare.ps1') @accessInitializeParameters
    Assert-True ($LASTEXITCODE -eq 0) 'Access 凭据应单独初始化。'
    $accessInitialize = ($accessInitializeText -join "`n") | ConvertFrom-Json
    Assert-True ($accessInitialize.credentialProfile -eq 'access') 'Access 凭据必须使用独立 profile。'
    Assert-True ($script:CredentialPath -ne $script:AccessCredentialPath) '公共与 Access 凭据路径必须分离。'
    Assert-True (-not [string](Get-Clipboard -Raw)) 'Access 初始化后剪贴板必须为空。'

    $manifest = [ordered]@{
        schemaVersion = '2.0'
        kind = 'deploy-github-to-wsl/manifest'
        repository = [ordered]@{ canonicalUrl = 'https://github.com/example/automation-test'; ref = 'main'; commit = '1' * 40; slug = $testSlug; sourcePath = "/root/projects/$testSlug" }
        wsl = [ordered]@{ distribution = $Distro }
        compose = [ordered]@{ projectName = "codex-$testSlug"; files = @("/root/projects/$testSlug/.codex-deploy/compose.yaml"); profiles = @('tunnel'); appService = 'app'; tunnelService = 'cloudflared'; internalPort = 8080 }
        cloudflare = [ordered]@{
            credentialProfile = 'public'; accountId = 'a' * 32; zoneId = 'b' * 32; zoneName = 'scuccs.me'
            hostname = "$testSlug.scuccs.me"; tunnelName = "wsl-$testSlug"; service = 'http://app:8080'; accessMode = 'anonymous'
            tunnelTokenPath = "$testConfigDirectory/secrets/tunnel_token"
        }
        state = [ordered]@{ path = $testStatePath }
        riskConfirmations = @()
        approval = [ordered]@{ scope = @('wslWrite', 'containers', 'cloudflareTunnel', 'cloudflareRoute'); planHash = $null }
        deploymentFiles = @()
    }
    $manifestPath = Join-Path $testRoot 'manifest.json'
    [IO.File]::WriteAllText($manifestPath, ($manifest | ConvertTo-Json -Depth 30), [Text.UTF8Encoding]::new($false))

    $state = [ordered]@{
        schemaVersion = '2.0'; planHash = '0' * 64; currentStage = 'tunnel'; completedStages = @()
        objects = [ordered]@{ tunnelId = $null; dnsRecordId = $null }
    }
    $stateScript = 'set -eu; umask 077; install -d -m 700 -- "\$STATE_DIR"; cat > "\$STATE_PATH"; chmod 600 -- "\$STATE_PATH"'
    ($state | ConvertTo-Json -Depth 20) | & wsl.exe -d $Distro -- env "STATE_DIR=$testStateDirectory" "STATE_PATH=$testStatePath" sh -c $stateScript
    Assert-True ($LASTEXITCODE -eq 0) '测试状态应写入 WSL。'

    $initialPlan = Invoke-CloudflareCommand -Action Plan -ManifestPath $manifestPath
    Assert-True ($initialPlan.canApply -and $initialPlan.hasChanges) '新项目计划应允许创建 Tunnel、配置和 DNS。'

    $tunnelApply = Invoke-CloudflareCommand -Action Apply -ManifestPath $manifestPath -Target Tunnel
    Assert-True ($tunnelApply.objects.tunnelId -eq '11111111-2222-4333-8444-555555555555') '应创建确定的模拟 Tunnel。'
    Assert-True (-not (($tunnelApply | ConvertTo-Json -Depth 20)).Contains('fake-runtime-tunnel-token')) 'Apply 输出不得包含 Tunnel Token。'

    $state.objects.tunnelId = $tunnelApply.objects.tunnelId
    $state.currentStage = 'route'
    $state.completedStages = @('tunnel')
    ($state | ConvertTo-Json -Depth 20) | & wsl.exe -d $Distro -- env "STATE_DIR=$testStateDirectory" "STATE_PATH=$testStatePath" sh -c $stateScript

    $routeApply = Invoke-CloudflareCommand -Action Apply -ManifestPath $manifestPath -Target Route
    Assert-True ([bool]$routeApply.objects.dnsRecordId) '应创建模拟 DNS。'
    $state.objects.dnsRecordId = $routeApply.objects.dnsRecordId
    ($state | ConvertTo-Json -Depth 20) | & wsl.exe -d $Distro -- env "STATE_DIR=$testStateDirectory" "STATE_PATH=$testStatePath" sh -c $stateScript

    $secondPlan = Invoke-CloudflareCommand -Action Plan -ManifestPath $manifestPath
    Assert-True ($secondPlan.canApply -and -not $secondPlan.hasChanges) '重复计划不应创建第二个 Tunnel 或 DNS。'

    # 已受管项目的 Maintain 只能更新状态中同 ID 的 Tunnel/DNS，不能创建或接管对象。
    $managedState = [ordered]@{
        schemaVersion = '2.0'; planHash = '0' * 64; currentStage = 'complete'; completedStages = @('tunnel', 'route', 'recorded')
        objects = [ordered]@{ tunnelId = $tunnelApply.objects.tunnelId; dnsRecordId = $routeApply.objects.dnsRecordId; accessApplicationId = $null; accessPolicyId = $null }
    }
    $managedState.project = [ordered]@{ slug = $testSlug; composeProject = "codex-$testSlug" }
    $managedState.repository = [ordered]@{ url = $manifest.repository.canonicalUrl; ref = $manifest.repository.ref; commit = $manifest.repository.commit; sourcePath = $manifest.repository.sourcePath }
    $managedState.cloudflare = [ordered]@{ accountId = $manifest.cloudflare.accountId; zoneId = $manifest.cloudflare.zoneId; zoneName = $manifest.cloudflare.zoneName; hostname = $manifest.cloudflare.hostname; tunnelName = $manifest.cloudflare.tunnelName; service = $manifest.cloudflare.service; accessMode = 'anonymous' }
    ($managedState | ConvertTo-Json -Depth 30) | & wsl.exe -d $Distro -- env "STATE_DIR=$testStateDirectory" "STATE_PATH=$testStatePath" sh -c $stateScript
    $managedManifest = ($manifest | ConvertTo-Json -Depth 30 -Compress) | ConvertFrom-Json -Depth 30
    $managedManifest.cloudflare | Add-Member -NotePropertyName configurationHash -NotePropertyValue ('0' * 64) -Force
    [IO.File]::WriteAllText($manifestPath, ($managedManifest | ConvertTo-Json -Depth 30), [Text.UTF8Encoding]::new($false))
    $managedResult = Invoke-CloudflareCommand -Action Maintain -ManifestPath $manifestPath
    Assert-True ($managedResult.action -eq 'Maintain' -and -not $managedResult.blocked) '受管 Tunnel/DNS 应允许 Maintain。'

    $missingState = ($managedState | ConvertTo-Json -Depth 30 -Compress) | ConvertFrom-Json -Depth 30
    $missingState.objects.tunnelId = '99999999-2222-4333-8444-555555555555'
    ($missingState | ConvertTo-Json -Depth 30) | & wsl.exe -d $Distro -- env "STATE_DIR=$testStateDirectory" "STATE_PATH=$testStatePath" sh -c $stateScript
    $missingText = & (Join-Path $PSScriptRoot '..\cloudflare.ps1') -Action Maintain -ManifestPath $manifestPath -CredentialPath $script:CredentialPath -ApiBaseUri $script:ApiBaseUri -AllowInsecureLoopbackForTest -Compact
    $missingResult = ($missingText -join "`n") | ConvertFrom-Json -Depth 30
    Assert-True ($LASTEXITCODE -ne 0 -and $null -ne $missingResult.error) 'Tunnel ID 漂移时 Maintain 必须阻断。'

    [void](New-CloudflareTunnel -Token $fakeToken -AccountId ('a' * 32) -Name 'wsl-unmanaged-test' -ApiBaseUri $script:ApiBaseUri -AllowInsecureLoopbackForTest)
    $unmanaged = ($manifest | ConvertTo-Json -Depth 30 -Compress) | ConvertFrom-Json -Depth 30
    $unmanaged.repository.slug = 'unmanaged-test'
    $unmanaged.repository.sourcePath = '/root/projects/unmanaged-test'
    $unmanaged.compose.projectName = 'codex-unmanaged-test'
    $unmanaged.compose.files = @('/root/projects/unmanaged-test/.codex-deploy/compose.yaml')
    $unmanaged.cloudflare.hostname = 'unmanaged-test.scuccs.me'
    $unmanaged.cloudflare.tunnelName = 'wsl-unmanaged-test'
    $unmanaged.cloudflare.tunnelTokenPath = '/root/.config/deploy-github-to-wsl/unmanaged-test/secrets/tunnel_token'
    $unmanaged.state.path = '/root/.local/state/deploy-github-to-wsl/unmanaged-test/deployment.json'
    $unmanagedPath = Join-Path $testRoot 'unmanaged.json'
    [IO.File]::WriteAllText($unmanagedPath, ($unmanaged | ConvertTo-Json -Depth 30), [Text.UTF8Encoding]::new($false))
    $unmanagedPlan = Invoke-CloudflareCommand -Action Plan -ManifestPath $unmanagedPath
    Assert-True (-not $unmanagedPlan.canApply) '没有受信任状态的同名 Tunnel 必须阻塞。'
    Assert-True ('unmanaged_tunnel_conflict' -in @($unmanagedPlan.blockers.code)) '应返回非托管 Tunnel 冲突码。'

    $fangdaiManifest = Join-Path $PSScriptRoot 'fixtures\fangdai-v2-plan.json'
    $beforeStateHash = (& wsl.exe -d $Distro -- sha256sum /root/.local/state/deploy-github-to-wsl/fangdai/deployment.json | Out-String).Split(' ')[0]
    $beforeContainers = (& wsl.exe -d $Distro -- docker ps --format '{{.ID}} {{.Names}} {{.Image}}' | Sort-Object) -join "`n"
    $fangdaiPlan = Invoke-CloudflareCommand -Action Plan -ManifestPath $fangdaiManifest
    $afterStateHash = (& wsl.exe -d $Distro -- sha256sum /root/.local/state/deploy-github-to-wsl/fangdai/deployment.json | Out-String).Split(' ')[0]
    $afterContainers = (& wsl.exe -d $Distro -- docker ps --format '{{.ID}} {{.Names}} {{.Image}}' | Sort-Object) -join "`n"
    Assert-True ($fangdaiPlan.canApply -and -not $fangdaiPlan.hasChanges) 'fangdai 只读 Cloudflare Plan 应返回无变更。'
    Assert-True ($beforeStateHash -eq $afterStateHash) 'fangdai 只读 Plan 不得修改部署记录。'
    Assert-True ($beforeContainers -eq $afterContainers) 'fangdai 只读 Plan 不得重启或修改容器。'

    $protected = ($manifest | ConvertTo-Json -Depth 30 -Compress) | ConvertFrom-Json -Depth 30
    $protected.repository.slug = $protectedSlug
    $protected.repository.sourcePath = "/root/projects/$protectedSlug"
    $protected.compose.projectName = "codex-$protectedSlug"
    $protected.compose.files = @("/root/projects/$protectedSlug/.codex-deploy/compose.yaml")
    $protected.cloudflare.hostname = "$protectedSlug.scuccs.me"
    $protected.cloudflare.tunnelName = "wsl-$protectedSlug"
    $protected.cloudflare.tunnelTokenPath = "$protectedConfigDirectory/secrets/tunnel_token"
    $protected.cloudflare.accessMode = 'access'
    $protected.cloudflare | Add-Member -NotePropertyName access -NotePropertyValue ([pscustomobject]@{
        applicationName = 'Protected test app'
        policyName = 'Allow test email'
        sessionDuration = '24h'
        include = @([pscustomobject]@{ email = [pscustomobject]@{ email = 'tester@example.com' } })
    })
    $protected.state.path = "$protectedStateDirectory/deployment.json"
    $protectedPath = Join-Path $testRoot 'protected.json'
    [IO.File]::WriteAllText($protectedPath, ($protected | ConvertTo-Json -Depth 30), [Text.UTF8Encoding]::new($false))
    $protectedState = [ordered]@{
        schemaVersion = '2.0'; planHash = '0' * 64; currentStage = 'tunnel'; completedStages = @()
        objects = [ordered]@{ tunnelId = $null; dnsRecordId = $null; accessApplicationId = $null; accessPolicyId = $null }
    }
    ($protectedState | ConvertTo-Json -Depth 20) | & wsl.exe -d $Distro -- env "STATE_DIR=$protectedStateDirectory" "STATE_PATH=$protectedStateDirectory/deployment.json" sh -c $stateScript
    $protectedPlan = Invoke-CloudflareCommand -Action Plan -ManifestPath $protectedPath
    Assert-True ($protectedPlan.canApply -and 'access_application' -in @($protectedPlan.changes.kind)) '受保护应用应计划独立创建 Access 应用。'
    $protectedTunnel = Invoke-CloudflareCommand -Action Apply -ManifestPath $protectedPath -Target Tunnel
    $protectedState.objects.tunnelId = $protectedTunnel.objects.tunnelId
    ($protectedState | ConvertTo-Json -Depth 20) | & wsl.exe -d $Distro -- env "STATE_DIR=$protectedStateDirectory" "STATE_PATH=$protectedStateDirectory/deployment.json" sh -c $stateScript
    $protectedRoute = Invoke-CloudflareCommand -Action Apply -ManifestPath $protectedPath -Target Route
    Assert-True ([bool]$protectedRoute.objects.accessApplicationId -and [bool]$protectedRoute.objects.accessPolicyId) '受保护路由应创建并记录 Access 应用与 Policy。'
    $protectedState.objects.dnsRecordId = $protectedRoute.objects.dnsRecordId
    $protectedState.objects.accessApplicationId = $protectedRoute.objects.accessApplicationId
    $protectedState.objects.accessPolicyId = $protectedRoute.objects.accessPolicyId
    ($protectedState | ConvertTo-Json -Depth 20) | & wsl.exe -d $Distro -- env "STATE_DIR=$protectedStateDirectory" "STATE_PATH=$protectedStateDirectory/deployment.json" sh -c $stateScript
    $protectedSecondPlan = Invoke-CloudflareCommand -Action Plan -ManifestPath $protectedPath
    Assert-True ($protectedSecondPlan.canApply -and -not $protectedSecondPlan.hasChanges) '受保护应用重复执行不得创建第二个 Access 应用或 Policy。'

    Write-Output 'Cloudflare 双凭据初始化、幂等 Apply、Access、冲突保护和 fangdai 只读演练通过。'
}
finally {
    Set-Clipboard -Value ''
    if ($serverProcess -and -not $serverProcess.HasExited) {
        $serverProcess.Kill($true)
        $serverProcess.WaitForExit()
    }
    foreach ($path in @($testStateDirectory, $testConfigDirectory)) {
        $resolved = (& wsl.exe -d $Distro -- readlink -m -- $path | Out-String).Trim()
        if ($resolved -eq $path -and $path -match '^/root/\.(?:local/state|config)/deploy-github-to-wsl/automation-test$') {
            & wsl.exe -d $Distro -- rm -rf -- $path
        }
    }
    foreach ($path in @('/root/.local/state/deploy-github-to-wsl/protected-test', '/root/.config/deploy-github-to-wsl/protected-test')) {
        $resolved = (& wsl.exe -d $Distro -- readlink -m -- $path | Out-String).Trim()
        if ($resolved -eq $path -and $path -match '^/root/\.(?:local/state|config)/deploy-github-to-wsl/protected-test$') {
            & wsl.exe -d $Distro -- rm -rf -- $path
        }
    }
    if ([IO.Directory]::Exists($testRoot)) {
        $resolved = [IO.Path]::GetFullPath($testRoot)
        if ([IO.Path]::GetFileName($resolved).StartsWith('deploy-github-to-wsl-workflow-')) {
            Remove-Item -LiteralPath $resolved -Recurse -Force
        }
    }
}
