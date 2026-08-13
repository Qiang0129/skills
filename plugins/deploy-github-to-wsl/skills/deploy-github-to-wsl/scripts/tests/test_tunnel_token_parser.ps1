Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

Import-Module (Join-Path $PSScriptRoot '..\TunnelTokenParser.psm1') -Force

function Assert-Equal {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Expected,

        [AllowNull()]
        [string]$Actual,

        [Parameter(Mandatory = $true)]
        [string]$Message
    )

    if ($Expected -ne $Actual) {
        throw "$Message；期望值与实际值不一致。"
    }
}

function Assert-Null {
    param(
        [AllowNull()]
        [object]$Actual,

        [Parameter(Mandatory = $true)]
        [string]$Message
    )

    if ($null -ne $Actual) {
        throw "$Message；实际值应为空。"
    }
}

$token = 'abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789._~+/=-'

Assert-Equal $token (Get-CloudflareTunnelToken -ClipboardText "cloudflared.exe service install $token") '应解析 Windows 服务安装命令'
Assert-Equal $token (Get-CloudflareTunnelToken -ClipboardText "sudo cloudflared service install '$token'") '应解析 Linux 服务安装命令'
Assert-Equal $token (Get-CloudflareTunnelToken -ClipboardText "cloudflared tunnel run --token $token") '应解析空格形式的 --token 参数'
Assert-Equal $token (Get-CloudflareTunnelToken -ClipboardText "cloudflared tunnel run --token=`"$token`"") '应解析等号形式的 --token 参数'
Assert-Equal $token (Get-CloudflareTunnelToken -ClipboardText "  $token  ") '应解析纯 Token'
Assert-Null -Actual (Get-CloudflareTunnelToken -ClipboardText 'cloudflared.exe service install too-short') -Message '应拒绝过短 Token'
Assert-Null -Actual (Get-CloudflareTunnelToken -ClipboardText "other-tool service install $token") -Message '应拒绝其他程序的安装命令'
Assert-Null -Actual (Get-CloudflareTunnelToken -ClipboardText '') -Message '应拒绝空剪贴板'

Write-Output 'Tunnel Token 解析器测试通过。'
