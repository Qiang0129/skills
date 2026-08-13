[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
[Console]::OutputEncoding = [System.Text.UTF8Encoding]::new($false)

function Assert-True {
    param(
        [bool]$Condition,
        [string]$Message
    )

    if (-not $Condition) {
        throw $Message
    }
}

$scriptPath = Join-Path (Split-Path -Parent $PSScriptRoot) 'inspect_wsl.ps1'
$jsonText = & $scriptPath -Compact
$exitCode = $LASTEXITCODE
$report = $jsonText | ConvertFrom-Json

Assert-True ($report.schemaVersion -eq '1.0') '环境报告版本不正确。'
Assert-True ($null -ne $report.capturedAt) '环境报告缺少采集时间。'
Assert-True ($report.wsl.installed -eq $true) '当前机器应已安装 WSL。'
Assert-True ($report.wsl.distributions.Count -ge 1) '当前机器应至少存在一个 WSL 发行版。'
Assert-True ($null -ne $report.target) '当前机器应能选中目标发行版。'
Assert-True ($report.target.resources.cpuCount -gt 0) 'CPU 数量应大于零。'
Assert-True ($report.target.resources.memoryTotalBytes -gt 0) '内存容量应大于零。'
Assert-True ($report.target.docker.containers.Count -ge 0) '容器清单字段应存在。'

$serialized = $report | ConvertTo-Json -Depth 15
Assert-True ($serialized -notmatch 'eyJ[a-zA-Z0-9_-]{20,}') '报告疑似包含 Tunnel Token。'
Assert-True ($serialized -notmatch '(?i)TUNNEL_TOKEN\s*=') '报告不得包含 Tunnel Token 环境变量值。'
Assert-True ($serialized -notmatch '-----BEGIN .*PRIVATE KEY-----') '报告不得包含私钥内容。'

if ($exitCode -notin @(0, 2)) {
    throw "环境扫描器返回了未定义退出码：$exitCode"
}

Write-Output 'WSL 环境扫描冒烟测试通过。'
