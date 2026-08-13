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

$slug = 'automation-resume-test'
$sourcePath = "/root/projects/$slug"
$stateDirectory = "/root/.local/state/deploy-github-to-wsl/$slug"
$statePath = "$stateDirectory/deployment.json"
$configDirectory = "/root/.config/deploy-github-to-wsl/$slug"
$composePath = "$sourcePath/.codex-deploy/compose.yaml"
$testRoot = Join-Path ([IO.Path]::GetTempPath()) ('deploy-github-to-wsl-resume-' + [Guid]::NewGuid().ToString('N'))
[IO.Directory]::CreateDirectory($testRoot) | Out-Null
$credentialPath = Join-Path $testRoot 'cloudflare-public.bin'
$serverProcess = $null

$composeText = @'
services:
  app:
    image: nginx:alpine
    restart: unless-stopped
    expose:
      - "80"
    healthcheck:
      test: ["CMD-SHELL", "wget -q -O /dev/null http://127.0.0.1/"]
      interval: 2s
      timeout: 2s
      retries: 15
  cloudflared:
    image: alpine:3.20
    profiles: ["tunnel"]
    command: ["sh", "-c", "while true; do sleep 3600; done"]
    restart: unless-stopped
    depends_on:
      app:
        condition: service_healthy
    healthcheck:
      test: ["CMD", "true"]
      interval: 2s
      timeout: 2s
      retries: 5
'@

try {
    foreach ($path in @($sourcePath, $stateDirectory, $configDirectory)) {
        & wsl.exe -d $Distro -- test '!' -e $path
        Assert-True ($LASTEXITCODE -eq 0) "测试路径已存在，拒绝覆盖：$path"
    }

    $remoteLine = (& wsl.exe -d $Distro -- git ls-remote --refs https://github.com/Qiang0129/fangdai refs/heads/main | Out-String).Trim()
    $commit = ($remoteLine -split '\s+', 2)[0]
    Assert-True ($commit -match '^[a-f0-9]{40}$') '测试仓库提交解析失败。'

    & wsl.exe -d $Distro -- git -c core.hooksPath=/dev/null clone --no-checkout --no-recurse-submodules --filter=blob:none https://github.com/Qiang0129/fangdai $sourcePath | Out-Null
    Assert-True ($LASTEXITCODE -eq 0) '测试源码只读分析副本创建失败。'
    & wsl.exe -d $Distro -- env GIT_LFS_SKIP_SMUDGE=1 git -C $sourcePath -c core.hooksPath=/dev/null checkout --detach $commit | Out-Null
    Assert-True ($LASTEXITCODE -eq 0) '测试源码固定提交失败。'
    $writeComposeScript = 'set -eu; install -d -m 755 -- "\$(dirname "\$COMPOSE_PATH")"; cat > "\$COMPOSE_PATH"; printf ''%s\n'' ''.codex-deploy/'' >> "\$SOURCE_PATH/.git/info/exclude"'
    $composeText | & wsl.exe -d $Distro -- env "COMPOSE_PATH=$composePath" "SOURCE_PATH=$sourcePath" sh -c $writeComposeScript
    Assert-True ($LASTEXITCODE -eq 0) '测试 Compose 文件写入失败。'

    [void](Write-CloudflareCredential -Token 'fake-public-token-for-local-tests-only-1234567890' -CredentialPath $credentialPath)
    $startInfo = [Diagnostics.ProcessStartInfo]::new((Get-Command py -ErrorAction Stop).Source)
    $startInfo.ArgumentList.Add('-3')
    $startInfo.ArgumentList.Add((Join-Path $PSScriptRoot 'mock_cloudflare_api.py'))
    $startInfo.ArgumentList.Add('--fail-token-requests')
    $startInfo.ArgumentList.Add('4')
    $startInfo.RedirectStandardOutput = $true
    $startInfo.RedirectStandardError = $true
    $startInfo.UseShellExecute = $false
    $startInfo.CreateNoWindow = $true
    $serverProcess = [Diagnostics.Process]::Start($startInfo)
    $port = [int]$serverProcess.StandardOutput.ReadLine()
    $apiBaseUri = [uri]"http://127.0.0.1:$port/client/v4"

    $composeBytes = [Text.Encoding]::UTF8.GetBytes($composeText)
    $composeHash = ([Convert]::ToHexString([Security.Cryptography.SHA256]::HashData($composeBytes))).ToLowerInvariant()
    $manifest = [ordered]@{
        schemaVersion = '2.0'
        kind = 'deploy-github-to-wsl/manifest'
        repository = [ordered]@{ canonicalUrl = 'https://github.com/Qiang0129/fangdai'; ref = 'refs/heads/main'; commit = $commit; slug = $slug; sourcePath = $sourcePath }
        wsl = [ordered]@{ distribution = $Distro }
        compose = [ordered]@{ projectName = "codex-$slug"; files = @($composePath); profiles = @('tunnel'); appService = 'app'; tunnelService = 'cloudflared'; internalPort = 80; pull = $true; build = $false }
        cloudflare = [ordered]@{
            credentialProfile = 'public'; accountId = 'a' * 32; zoneId = 'b' * 32; zoneName = 'scuccs.me'
            hostname = "$slug.scuccs.me"; tunnelName = "wsl-$slug"; service = 'http://app:80'; accessMode = 'anonymous'
            tunnelTokenPath = "$configDirectory/secrets/tunnel_token"
            configurationHash = 'c' * 64
        }
        state = [ordered]@{ path = $statePath }
        acceptance = [ordered]@{ url = "http://127.0.0.1:$port/health" }
        riskConfirmations = @()
        approval = [ordered]@{ scope = @('wslWrite', 'containers', 'cloudflareTunnel', 'cloudflareRoute'); planHash = $null }
        deploymentFiles = @([ordered]@{ path = '.codex-deploy/compose.yaml'; contentBase64 = [Convert]::ToBase64String($composeBytes); sha256 = $composeHash })
    }
    $manifestPath = Join-Path $testRoot 'manifest.json'
    [IO.File]::WriteAllText($manifestPath, ($manifest | ConvertTo-Json -Depth 40), [Text.UTF8Encoding]::new($false))

    $common = @{
        ManifestPath = $manifestPath
        CredentialPath = $credentialPath
        ApiBaseUri = $apiBaseUri
        AllowInsecureLoopbackForTest = $true
        Compact = $true
    }
    $planText = & (Join-Path $PSScriptRoot '..\deploy.ps1') -Mode Plan @common
    Assert-True ($LASTEXITCODE -eq 0) "测试 Plan 应成功；返回：$($planText -join '')"
    $plan = ($planText -join "`n") | ConvertFrom-Json -Depth 50
    Assert-True $plan.canApply "测试 Plan 应可执行；阻塞项：$($plan.blockers | ConvertTo-Json -Depth 20 -Compress)"

    $applyText = & (Join-Path $PSScriptRoot '..\deploy.ps1') -Mode Apply -ApprovedPlanHash $plan.planHash @common
    Assert-True ($LASTEXITCODE -eq 2) '首次 Apply 应在模拟 Token 响应故障处中断。'
    $applyResult = ($applyText -join "`n") | ConvertFrom-Json -Depth 50
    Assert-True ($applyResult.error.message -match "阶段 'tunnel' 中断") "首次 Apply 应精确记录 tunnel 阶段失败；返回：$($applyText -join '')"

    $failedState = ((& wsl.exe -d $Distro -- cat $statePath) -join "`n") | ConvertFrom-Json -Depth 50
    Assert-True ($failedState.currentStage -eq 'tunnel') '失败状态应停留在 tunnel。'
    Assert-True ('app' -in @($failedState.completedStages)) '失败前完成的 app 阶段应被保留。'
    Assert-True ([bool]$failedState.objects.tunnelId) '响应故障后仍必须保留已创建 Tunnel 的对象 ID。'
    Assert-True ($failedState.lastError.code -eq 'tunnel_failed') '失败状态应使用脱敏错误码。'

    $resumeText = & (Join-Path $PSScriptRoot '..\deploy.ps1') -Mode Resume -ApprovedPlanHash $plan.planHash @common
    Assert-True ($LASTEXITCODE -eq 0) "Resume 应从 tunnel 继续并完成；返回：$($resumeText -join '')"
    $resume = ($resumeText -join "`n") | ConvertFrom-Json -Depth 50
    Assert-True $resume.completed 'Resume 应完成全部阶段。'
    Assert-True ($resume.state.currentStage -eq 'complete') '最终状态机应收口为 complete。'
    Assert-True ([bool]$resume.state.objects.dnsRecordId) 'Resume 应创建并记录 DNS ID。'
    Assert-True ($resume.state.acceptance.publicHttpStatus -eq 200) '测试验收应返回 HTTP 200。'

    $finalPlanText = & (Join-Path $PSScriptRoot '..\deploy.ps1') -Mode Plan @common
    $finalPlan = ($finalPlanText -join "`n") | ConvertFrom-Json -Depth 50
    Assert-True (@($finalPlan.checks.cloudflare.changes).Count -eq 0) '完成后重复 Plan 不得计划第二个 Tunnel 或 DNS。'

    Write-Output 'Apply 故障记录、对象所有权持久化、Resume 续跑和幂等验收通过。'
}
finally {
    if ($serverProcess -and -not $serverProcess.HasExited) {
        $serverProcess.Kill($true)
        $serverProcess.WaitForExit()
    }
    & wsl.exe -d $Distro -- docker compose -p "codex-$slug" -f $composePath --profile tunnel down --remove-orphans 2>$null | Out-Null
    foreach ($path in @($sourcePath, $stateDirectory, $configDirectory)) {
        $resolved = (& wsl.exe -d $Distro -- readlink -m -- $path | Out-String).Trim()
        if ($resolved -eq $path -and $path -match '^/root/(?:projects|\.local/state/deploy-github-to-wsl|\.config/deploy-github-to-wsl)/automation-resume-test$') {
            & wsl.exe -d $Distro -- rm -rf -- $path
        }
    }
    if ([IO.Directory]::Exists($testRoot)) {
        $resolved = [IO.Path]::GetFullPath($testRoot)
        if ([IO.Path]::GetFileName($resolved).StartsWith('deploy-github-to-wsl-resume-')) {
            Remove-Item -LiteralPath $resolved -Recurse -Force
        }
    }
}
