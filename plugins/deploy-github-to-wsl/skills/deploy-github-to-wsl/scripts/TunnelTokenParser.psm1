Set-StrictMode -Version Latest

function Get-CloudflareTunnelToken {
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory = $true)]
        [AllowEmptyString()]
        [string]$ClipboardText
    )

    # Cloudflare 控制台可能复制服务安装命令、带 --token 的命令或纯 Token。
    $patterns = @(
        '(?i)--token(?:=|\s+)["'']?([A-Za-z0-9._~+/=-]{40,})["'']?(?![A-Za-z0-9._~+/=-])',
        '(?i)(?:^|\s)(?:[^\s"'']*[\\/])?cloudflared(?:\.exe)?\s+service\s+install\s+["'']?([A-Za-z0-9._~+/=-]{40,})["'']?(?![A-Za-z0-9._~+/=-])',
        '^\s*([A-Za-z0-9._~+/=-]{40,})\s*$'
    )

    foreach ($pattern in $patterns) {
        if ($ClipboardText -match $pattern) {
            return $Matches[1]
        }
    }

    return $null
}

Export-ModuleMember -Function Get-CloudflareTunnelToken
