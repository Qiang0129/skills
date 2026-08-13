[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [ValidatePattern('^[A-Za-z0-9][A-Za-z0-9-]{0,62}$')]
    [string]$ProjectSlug,

    [Parameter(Mandatory = $true)]
    [string]$Distro,

    [Parameter(Mandatory = $true)]
    [switch]$ConfirmClipboardClear
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
[Console]::OutputEncoding = [System.Text.UTF8Encoding]::new($false)
$OutputEncoding = [System.Text.UTF8Encoding]::new($false)

Import-Module (Join-Path $PSScriptRoot 'TunnelTokenParser.psm1') -Force

if (-not $ConfirmClipboardClear) {
    throw '必须在用户明确同意清空剪贴板后提供 -ConfirmClipboardClear。'
}

if (-not (Get-Command Get-Clipboard -ErrorAction SilentlyContinue)) {
    throw '当前 PowerShell 不支持读取剪贴板。'
}

$clipboardText = [string](Get-Clipboard -Raw)
$token = $null

try {
    $token = Get-CloudflareTunnelToken -ClipboardText $clipboardText

    if (-not $token) {
        throw '剪贴板中没有找到合法的 Cloudflare Tunnel Token 或安装命令。'
    }

    $secretDirectory = "/root/.config/deploy-github-to-wsl/$ProjectSlug/secrets"
    $secretPath = "$secretDirectory/tunnel_token"
    # 路径不属于密钥，通过环境变量传递可避免 wsl.exe 丢失 Bash 位置参数。
    $writeScript = 'set -eu; umask 077; install -d -m 700 -- "\$SECRET_DIRECTORY"; cat > "\$SECRET_PATH"; chmod 600 -- "\$SECRET_PATH"'

    $token | & wsl.exe -d $Distro -- env "SECRET_DIRECTORY=$secretDirectory" "SECRET_PATH=$secretPath" bash -c $writeScript
    if ($LASTEXITCODE -ne 0) {
        throw 'Tunnel Token 写入 WSL 失败。'
    }

    $permission = (& wsl.exe -d $Distro -- stat -c '%a' $secretPath 2>$null | Out-String).Trim()
    if ($LASTEXITCODE -ne 0 -or $permission -ne '600') {
        throw 'Tunnel Token 文件权限验证失败。'
    }

    [ordered]@{
        stored           = $true
        path             = $secretPath
        permission       = $permission
        clipboardCleared = $true
    } | ConvertTo-Json -Compress
}
finally {
    $token = $null
    $clipboardText = $null
    Set-Clipboard -Value ''
}
