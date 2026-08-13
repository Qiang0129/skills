[CmdletBinding()]
param(
    [string]$Distro = 'Ubuntu'
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$projectSlug = 'codex-token-writer-test'
$projectDirectory = "/root/.config/deploy-github-to-wsl/$projectSlug"
$secretPath = "$projectDirectory/secrets/tunnel_token"
$expectedPath = '/root/.config/deploy-github-to-wsl/codex-token-writer-test'
$fakeToken = 'abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789._~+/=-'
$scriptPath = Join-Path $PSScriptRoot '..\store_tunnel_token.ps1'
$createdByTest = $false

try {
    & wsl.exe -d $Distro -- test '!' -e $projectDirectory
    if ($LASTEXITCODE -ne 0) {
        throw "测试目录已存在，拒绝覆盖：$projectDirectory"
    }

    Set-Clipboard -Value "cloudflared.exe service install $fakeToken"
    $result = & $scriptPath -ProjectSlug $projectSlug -Distro $Distro -ConfirmClipboardClear | ConvertFrom-Json
    $createdByTest = $true

    if (-not $result.stored -or $result.path -ne $secretPath -or $result.permission -ne '600' -or -not $result.clipboardCleared) {
        throw 'Token 写入脚本返回的安全状态不符合契约。'
    }

    $storedToken = (& wsl.exe -d $Distro -- cat $secretPath | Out-String).Trim()
    if ($storedToken -ne $fakeToken) {
        throw '写入的假 Token 内容不一致。'
    }

    if ([string](Get-Clipboard -Raw)) {
        throw '测试完成后剪贴板未清空。'
    }

    Write-Output 'Tunnel Token 写入端到端测试通过。'
}
finally {
    Set-Clipboard -Value ''
    if ($createdByTest) {
        $resolvedPath = (& wsl.exe -d $Distro -- readlink -m -- $projectDirectory | Out-String).Trim()
        if ($resolvedPath -eq $expectedPath) {
            & wsl.exe -d $Distro -- rm -rf -- $projectDirectory
        }
        else {
            Write-Warning '测试目录解析结果异常，未自动清理。'
        }
    }
}
