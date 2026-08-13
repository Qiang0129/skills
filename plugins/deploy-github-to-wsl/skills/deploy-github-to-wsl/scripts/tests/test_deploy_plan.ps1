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

$testRoot = Join-Path ([IO.Path]::GetTempPath()) ('deploy-github-to-wsl-plan-' + [Guid]::NewGuid().ToString('N'))
[IO.Directory]::CreateDirectory($testRoot) | Out-Null
$credentialPath = Join-Path $testRoot 'cloudflare-public.bin'
$serverProcess = $null

try {
    [void](Write-CloudflareCredential -Token 'fake-public-token-for-local-tests-only-1234567890' -CredentialPath $credentialPath)
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

    $manifestPath = Join-Path $PSScriptRoot 'fixtures\fangdai-v2-plan.json'
    $statePath = '/root/.local/state/deploy-github-to-wsl/fangdai/deployment.json'
    $beforeStateHash = (& wsl.exe -d $Distro -- sha256sum $statePath | Out-String).Split(' ')[0]
    $beforeContainers = (& wsl.exe -d $Distro -- docker ps --format '{{.ID}} {{.Names}} {{.Image}}' | Sort-Object) -join "`n"
    $beforeGit = (& wsl.exe -d $Distro -- git -C /root/projects/fangdai status --porcelain | Out-String)

    $parameters = @{
        Mode = 'Plan'
        ManifestPath = $manifestPath
        CredentialPath = $credentialPath
        ApiBaseUri = [uri]"http://127.0.0.1:$port/client/v4"
        AllowInsecureLoopbackForTest = $true
        Compact = $true
    }
    $text = & (Join-Path $PSScriptRoot '..\deploy.ps1') @parameters
    Assert-True ($LASTEXITCODE -eq 0) "deploy.ps1 Plan 应成功；返回：$($text -join '')"
    $plan = ($text -join "`n") | ConvertFrom-Json -Depth 50

    Assert-True $plan.readOnly 'Plan 必须声明只读。'
    Assert-True (-not $plan.canApply) 'fangdai 远端 main 已漂移时只读计划应阻止执行。'
    Assert-True ('repository_commit_drift' -in @($plan.blockers.code)) '只读计划应精确报告 fangdai 提交漂移。'
    Assert-True ($plan.planHash -match '^[a-f0-9]{64}$') 'Plan 必须输出 SHA-256 计划哈希。'
    Assert-True ($plan.deploymentManifest.approval.planHash -eq $plan.planHash) '输出清单必须绑定同一计划哈希。'
    Assert-True ('tunnel' -in @($plan.deploymentManifest.compose.profiles)) '计划必须保留 Tunnel profile。'
    Assert-True (@($plan.checks.cloudflare.changes).Count -eq 0) 'fangdai 模拟 Cloudflare 对象应无差异。'

    $afterStateHash = (& wsl.exe -d $Distro -- sha256sum $statePath | Out-String).Split(' ')[0]
    $afterContainers = (& wsl.exe -d $Distro -- docker ps --format '{{.ID}} {{.Names}} {{.Image}}' | Sort-Object) -join "`n"
    $afterGit = (& wsl.exe -d $Distro -- git -C /root/projects/fangdai status --porcelain | Out-String)
    Assert-True ($beforeStateHash -eq $afterStateHash) 'Plan 不得写入 WSL 部署状态。'
    Assert-True ($beforeContainers -eq $afterContainers) 'Plan 不得修改 Compose 容器。'
    Assert-True ($beforeGit -eq $afterGit) 'Plan 不得修改源码工作树。'

    Write-Output '部署清单哈希、并行只读预检、profiles 和 fangdai 零写入测试通过。'
}
finally {
    if ($serverProcess -and -not $serverProcess.HasExited) {
        $serverProcess.Kill($true)
        $serverProcess.WaitForExit()
    }
    if ([IO.Directory]::Exists($testRoot)) {
        $resolved = [IO.Path]::GetFullPath($testRoot)
        if ([IO.Path]::GetFileName($resolved).StartsWith('deploy-github-to-wsl-plan-')) {
            Remove-Item -LiteralPath $resolved -Recurse -Force
        }
    }
}
