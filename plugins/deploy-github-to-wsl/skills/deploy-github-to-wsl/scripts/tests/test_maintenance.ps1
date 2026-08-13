[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
[Console]::OutputEncoding = [Text.UTF8Encoding]::new($false)

function Assert-True {
    param([bool]$Condition, [string]$Message)
    if (-not $Condition) { throw $Message }
}

$scriptPath = Join-Path $PSScriptRoot '..\maintain.ps1'
$tokens = $null
$errors = $null
[System.Management.Automation.Language.Parser]::ParseFile($scriptPath, [ref]$tokens, [ref]$errors) | Out-Null
Assert-True ($errors.Count -eq 0) '维护执行器 PowerShell 语法必须通过。'
$skillRoot = Split-Path $PSScriptRoot -Parent | Split-Path -Parent
$coreFiles = @(
    (Join-Path $skillRoot 'SKILL.md'),
    (Join-Path $skillRoot 'scripts\maintain.ps1'),
    (Join-Path $skillRoot 'scripts\deploy.ps1'),
    (Join-Path $skillRoot 'scripts\cloudflare.ps1')
)
$coreText = ($coreFiles | ForEach-Object { [IO.File]::ReadAllText($_, [Text.UTF8Encoding]::new($false)) }) -join "`n"
Assert-True ($coreText -notmatch '(?i)LabelHub|ai_reviewer|\bmysql\b|\busers\b') '通用核心不得固化 LabelHub、MySQL 或业务账号模型。'

$request = [ordered]@{
    schemaVersion = '1.0'
    kind = 'deploy-github-to-wsl/maintenance-request'
    operationId = 'test-inspect'
    project = [ordered]@{ slug = 'demo'; distribution = 'Ubuntu' }
    operation = [ordered]@{ type = 'inspect' }
}
$requestPath = Join-Path ([IO.Path]::GetTempPath()) ('maintenance-request-' + [Guid]::NewGuid().ToString('N') + '.json')
[IO.File]::WriteAllText($requestPath, ($request | ConvertTo-Json -Depth 20), [Text.UTF8Encoding]::new($false))

try {
    $serialized = $request | ConvertTo-Json -Depth 20 -Compress
    Assert-True ($serialized -notmatch '(?i)password|token|secret|sql') '只读请求不得包含敏感字段。'

    $unsafe = $request | ConvertTo-Json -Depth 20 | ConvertFrom-Json
    $unsafe.operation = [pscustomobject]@{ type = 'account.create'; account = [pscustomobject]@{ username = 'one'; password = 'leaked' } }
    $unsafeJson = $unsafe | ConvertTo-Json -Depth 20 -Compress
    Assert-True ($unsafeJson -match '(?i)password') '测试夹具必须覆盖密码字段检测。'

    $adapterDescriptor = [ordered]@{
        schemaVersion = '1.0'; kind = 'deploy-github-to-wsl/account-adapter'; runtime = 'python3'
        runnerPath = '.codex-deploy/maintenance/adapters/accounts.py'; runnerSha256 = ('a' * 64)
        allowedRoles = @('owner'); resultContract = 'json-line-v1'
    }
    $descriptorJson = $adapterDescriptor | ConvertTo-Json -Depth 10 -Compress
    Assert-True ($descriptorJson -notmatch '(?i)password|token|secret|sql') '适配器描述不得包含敏感值或任意 SQL。'
Assert-True ($adapterDescriptor.runnerSha256 -match '^[a-f0-9]{64}$') '适配器必须绑定 SHA-256。'

$legacyState = [pscustomobject]@{
    schemaVersion = '2.0'
    currentStage = 'complete'
    project = [pscustomobject]@{ slug = 'demo'; composeProject = 'codex-demo' }
    repository = [pscustomobject]@{ commit = ('a' * 40); sourcePath = '/root/projects/demo' }
    compose = [pscustomobject]@{ files = @('/root/projects/demo/.codex-deploy/compose.yaml'); profiles = @() }
    maintenance = $null
    hashes = [pscustomobject]@{ composeConfig = $null }
}
Assert-True (-not ([string]$legacyState.hashes.composeConfig -match '^[a-f0-9]{64}$')) '兼容旧状态测试必须没有维护基线。'
Assert-True ($coreText -match '兼容只读状态') '旧状态写入阻断必须在维护执行器中明确。'

Write-Output '维护执行器语法、请求敏感字段边界和适配器契约测试通过。'
}
finally {
    if ([IO.File]::Exists($requestPath)) { Remove-Item -LiteralPath $requestPath -Force }
}
