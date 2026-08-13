Set-StrictMode -Version Latest

$script:CredentialEntropy = [Text.Encoding]::UTF8.GetBytes('deploy-github-to-wsl/cloudflare-public/v2')
$script:SensitivePropertyPattern = '(?i)(token|secret|password|credential|authorization|cookie|private.?key)'

function Get-DefaultCloudflareCredentialPath {
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [ValidateSet('public', 'access')]
        [string]$Profile = 'public'
    )

    if (-not $env:LOCALAPPDATA) {
        throw [InvalidOperationException]::new('无法确定 LOCALAPPDATA，不能定位 Cloudflare 凭据。')
    }

    return Join-Path $env:LOCALAPPDATA "deploy-github-to-wsl\credentials\cloudflare-$Profile.bin"
}

function Test-CloudflareApiBaseUri {
    param(
        [Parameter(Mandatory = $true)]
        [uri]$ApiBaseUri,

        [switch]$AllowInsecureLoopbackForTest
    )

    if ($ApiBaseUri.Scheme -eq 'https') {
        return
    }

    if ($AllowInsecureLoopbackForTest -and $ApiBaseUri.Scheme -eq 'http' -and $ApiBaseUri.IsLoopback) {
        return
    }

    throw [InvalidOperationException]::new('Cloudflare API 基址必须使用 HTTPS；仅测试可显式允许回环 HTTP。')
}

function Set-PrivateAcl {
    param(
        [Parameter(Mandatory = $true)]
        [string]$LiteralPath,

        [Parameter(Mandatory = $true)]
        [bool]$IsDirectory
    )

    if (-not $IsWindows) {
        throw [PlatformNotSupportedException]::new('DPAPI 凭据仅支持 Windows 当前用户。')
    }

    $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
    $sid = $identity.User.Value
    if ($IsDirectory) {
        $grant = "*${sid}:(OI)(CI)F"
    }
    else {
        $grant = "*${sid}:F"
    }

    # icacls 不读取或传递任何密钥，只负责设置本地文件 ACL，兼容 PowerShell 7 的 .NET 运行时。
    & icacls.exe $LiteralPath '/inheritance:r' '/grant:r' $grant | Out-Null
    if ($LASTEXITCODE -ne 0) {
        throw [UnauthorizedAccessException]::new('无法收紧 Cloudflare 凭据 ACL。')
    }

    $acl = Get-Acl -LiteralPath $LiteralPath
    $allowedSids = @($acl.Access | Where-Object AccessControlType -eq Allow | ForEach-Object {
        $_.IdentityReference.Translate([Security.Principal.SecurityIdentifier]).Value
    } | Select-Object -Unique)
    if (-not $acl.AreAccessRulesProtected -or $allowedSids.Count -ne 1 -or $allowedSids[0] -ne $sid) {
        throw [UnauthorizedAccessException]::new('Cloudflare 凭据 ACL 验证失败。')
    }
}

function Write-CloudflareCredential {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [ValidateNotNullOrEmpty()]
        [string]$Token,

        [string]$CredentialPath = (Get-DefaultCloudflareCredentialPath),

        [switch]$AllowReplace
    )

    if (-not $IsWindows) {
        throw [PlatformNotSupportedException]::new('DPAPI 凭据仅支持 Windows 当前用户。')
    }
    if ($Token.Length -lt 20 -or $Token -match '[\r\n]') {
        throw [ArgumentException]::new('剪贴板内容不是合法的单行 Cloudflare API Token。')
    }

    $fullPath = [IO.Path]::GetFullPath($CredentialPath)
    $directory = [IO.Path]::GetDirectoryName($fullPath)
    if ([IO.File]::Exists($fullPath) -and -not $AllowReplace) {
        throw [InvalidOperationException]::new('Cloudflare 凭据已存在；轮换凭据需要单独批准。')
    }

    [IO.Directory]::CreateDirectory($directory) | Out-Null
    Set-PrivateAcl -LiteralPath $directory -IsDirectory $true

    $plainBytes = [Text.Encoding]::UTF8.GetBytes($Token)
    $protectedBytes = $null
    $temporaryPath = Join-Path $directory ('.cloudflare-public.{0}.tmp' -f [Guid]::NewGuid().ToString('N'))
    try {
        $protectedBytes = [Security.Cryptography.ProtectedData]::Protect(
            $plainBytes,
            $script:CredentialEntropy,
            [Security.Cryptography.DataProtectionScope]::CurrentUser
        )
        [IO.File]::WriteAllBytes($temporaryPath, $protectedBytes)
        Set-PrivateAcl -LiteralPath $temporaryPath -IsDirectory $false
        [IO.File]::Move($temporaryPath, $fullPath, $AllowReplace)
        Set-PrivateAcl -LiteralPath $fullPath -IsDirectory $false
    }
    finally {
        if ([IO.File]::Exists($temporaryPath)) {
            [IO.File]::Delete($temporaryPath)
        }
        if ($null -ne $plainBytes) {
            [Array]::Clear($plainBytes, 0, $plainBytes.Length)
        }
        if ($null -ne $protectedBytes) {
            [Array]::Clear($protectedBytes, 0, $protectedBytes.Length)
        }
    }

    return [ordered]@{
        stored = $true
        path = $fullPath
        protection = 'DPAPI CurrentUser'
    }
}

function Read-CloudflareCredential {
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [string]$CredentialPath = (Get-DefaultCloudflareCredentialPath)
    )

    if (-not $IsWindows) {
        throw [PlatformNotSupportedException]::new('DPAPI 凭据仅支持 Windows 当前用户。')
    }

    $fullPath = [IO.Path]::GetFullPath($CredentialPath)
    if (-not [IO.File]::Exists($fullPath)) {
        throw [IO.FileNotFoundException]::new('尚未初始化 Cloudflare 公共部署凭据。')
    }

    $protectedBytes = [IO.File]::ReadAllBytes($fullPath)
    $plainBytes = $null
    try {
        $plainBytes = [Security.Cryptography.ProtectedData]::Unprotect(
            $protectedBytes,
            $script:CredentialEntropy,
            [Security.Cryptography.DataProtectionScope]::CurrentUser
        )
        return [Text.Encoding]::UTF8.GetString($plainBytes)
    }
    catch {
        throw [Security.Cryptography.CryptographicException]::new('Cloudflare 凭据解密失败；请由当前 Windows 用户重新初始化。')
    }
    finally {
        if ($null -ne $protectedBytes) {
            [Array]::Clear($protectedBytes, 0, $protectedBytes.Length)
        }
        if ($null -ne $plainBytes) {
            [Array]::Clear($plainBytes, 0, $plainBytes.Length)
        }
    }
}

function ConvertTo-CloudflareSafeObject {
    [CmdletBinding()]
    param(
        [AllowNull()]
        [object]$InputObject
    )

    if ($null -eq $InputObject) {
        return $null
    }
    if ($InputObject -is [string] -or $InputObject.GetType().IsPrimitive) {
        return $InputObject
    }
    if ($InputObject -is [Collections.IDictionary]) {
        $safe = [ordered]@{}
        foreach ($key in $InputObject.Keys) {
            if ([string]$key -match $script:SensitivePropertyPattern) {
                continue
            }
            $safe[[string]$key] = ConvertTo-CloudflareSafeObject -InputObject $InputObject[$key]
        }
        return $safe
    }
    if ($InputObject -is [Collections.IEnumerable]) {
        return @($InputObject | ForEach-Object { ConvertTo-CloudflareSafeObject -InputObject $_ })
    }

    $safeObject = [ordered]@{}
    foreach ($property in $InputObject.PSObject.Properties) {
        if ($property.Name -match $script:SensitivePropertyPattern) {
            continue
        }
        $safeObject[$property.Name] = ConvertTo-CloudflareSafeObject -InputObject $property.Value
    }
    return $safeObject
}

function Get-CloudflareErrorStatusCode {
    param([Management.Automation.ErrorRecord]$ErrorRecord)

    try {
        return [int]$ErrorRecord.Exception.Response.StatusCode
    }
    catch {
        return 0
    }
}

function Invoke-CloudflareApi {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [ValidateSet('GET', 'POST', 'PUT', 'PATCH', 'DELETE')]
        [string]$Method,

        [Parameter(Mandatory = $true)]
        [ValidatePattern('^/')]
        [string]$Path,

        [Parameter(Mandatory = $true)]
        [ValidateNotNullOrEmpty()]
        [string]$Token,

        [AllowNull()]
        [object]$Body,

        [uri]$ApiBaseUri = 'https://api.cloudflare.com/client/v4',

        [ValidateRange(1, 120)]
        [int]$TimeoutSec = 30,

        [ValidateRange(1, 6)]
        [int]$MaxAttempts = 4,

        [switch]$AllowInsecureLoopbackForTest
    )

    Test-CloudflareApiBaseUri -ApiBaseUri $ApiBaseUri -AllowInsecureLoopbackForTest:$AllowInsecureLoopbackForTest
    $uri = '{0}{1}' -f $ApiBaseUri.AbsoluteUri.TrimEnd('/'), $Path
    $headers = @{ Authorization = "Bearer $Token"; Accept = 'application/json' }
    $serializedBody = if ($null -ne $Body) { $Body | ConvertTo-Json -Depth 30 -Compress } else { $null }

    for ($attempt = 1; $attempt -le $MaxAttempts; $attempt++) {
        try {
            $parameters = @{
                Uri = $uri
                Method = $Method
                Headers = $headers
                TimeoutSec = $TimeoutSec
                ErrorAction = 'Stop'
            }
            if ($null -ne $serializedBody) {
                $parameters.ContentType = 'application/json'
                $parameters.Body = $serializedBody
            }
            $response = Invoke-RestMethod @parameters
            if ($null -ne $response.PSObject.Properties['success'] -and -not $response.success) {
                $code = if ($response.errors -and $response.errors[0].code) { [string]$response.errors[0].code } else { 'unknown' }
                throw [InvalidOperationException]::new("Cloudflare API 返回业务错误（cf_api_$code）。")
            }
            if ($null -ne $response.PSObject.Properties['result']) {
                return $response.result
            }
            return $response
        }
        catch {
            $statusCode = Get-CloudflareErrorStatusCode -ErrorRecord $_
            if ($_.Exception.Message -match 'Cloudflare API 返回业务错误（(cf_api_[^)]+)）') {
                throw [InvalidOperationException]::new("Cloudflare API 请求失败（$($Matches[1])）。")
            }
            $retryable = $statusCode -eq 0 -or $statusCode -eq 429 -or $statusCode -ge 500
            if ($retryable -and $attempt -lt $MaxAttempts) {
                $delayMilliseconds = [Math]::Min(4000, 250 * [Math]::Pow(2, $attempt - 1)) + (Get-Random -Minimum 0 -Maximum 150)
                Start-Sleep -Milliseconds $delayMilliseconds
                continue
            }

            $errorCode = if ($statusCode -gt 0) { "cf_http_$statusCode" } else { 'cf_network_error' }
            throw [InvalidOperationException]::new("Cloudflare API 请求失败（$errorCode）。")
        }
        finally {
            $serializedBody = if ($null -ne $serializedBody) { [string]$serializedBody } else { $null }
        }
    }
}

function Get-CloudflareZone {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$Token,
        [Parameter(Mandatory = $true)][string]$AccountId,
        [Parameter(Mandatory = $true)][string]$ZoneName,
        [uri]$ApiBaseUri = 'https://api.cloudflare.com/client/v4',
        [switch]$AllowInsecureLoopbackForTest
    )

    $encodedName = [uri]::EscapeDataString($ZoneName)
    $encodedAccount = [uri]::EscapeDataString($AccountId)
    $zones = @(Invoke-CloudflareApi -Method GET -Path "/zones?name=$encodedName&account.id=$encodedAccount&status=active" -Token $Token -ApiBaseUri $ApiBaseUri -AllowInsecureLoopbackForTest:$AllowInsecureLoopbackForTest)
    if ($zones.Count -ne 1) {
        throw [InvalidOperationException]::new('指定账户中没有找到唯一且已激活的目标 Zone。')
    }
    return $zones[0]
}

function Test-CloudflareCredential {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$Token,
        [Parameter(Mandatory = $true)][string]$AccountId,
        [Parameter(Mandatory = $true)][string]$ZoneName,
        [uri]$ApiBaseUri = 'https://api.cloudflare.com/client/v4',
        [switch]$AllowInsecureLoopbackForTest
    )

    $verification = Invoke-CloudflareApi -Method GET -Path '/user/tokens/verify' -Token $Token -ApiBaseUri $ApiBaseUri -AllowInsecureLoopbackForTest:$AllowInsecureLoopbackForTest
    [void](Invoke-CloudflareApi -Method GET -Path "/accounts/$([uri]::EscapeDataString($AccountId))" -Token $Token -ApiBaseUri $ApiBaseUri -AllowInsecureLoopbackForTest:$AllowInsecureLoopbackForTest)
    $zone = Get-CloudflareZone -Token $Token -AccountId $AccountId -ZoneName $ZoneName -ApiBaseUri $ApiBaseUri -AllowInsecureLoopbackForTest:$AllowInsecureLoopbackForTest

    return [ordered]@{
        valid = ([string]$verification.status -eq 'active')
        accountId = $AccountId
        zoneId = [string]$zone.id
        zoneName = [string]$zone.name
    }
}

function Test-CloudflareAccessCredential {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$Token,
        [Parameter(Mandatory = $true)][string]$AccountId,
        [uri]$ApiBaseUri = 'https://api.cloudflare.com/client/v4',
        [switch]$AllowInsecureLoopbackForTest
    )

    $verification = Invoke-CloudflareApi -Method GET -Path '/user/tokens/verify' -Token $Token -ApiBaseUri $ApiBaseUri -AllowInsecureLoopbackForTest:$AllowInsecureLoopbackForTest
    [void](Invoke-CloudflareApi -Method GET -Path "/accounts/$([uri]::EscapeDataString($AccountId))" -Token $Token -ApiBaseUri $ApiBaseUri -AllowInsecureLoopbackForTest:$AllowInsecureLoopbackForTest)
    return [ordered]@{ valid = ([string]$verification.status -eq 'active'); accountId = $AccountId }
}

function Get-CloudflareAccessApplications {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$Token,
        [Parameter(Mandatory = $true)][string]$AccountId,
        [Parameter(Mandatory = $true)][string]$Hostname,
        [uri]$ApiBaseUri = 'https://api.cloudflare.com/client/v4',
        [switch]$AllowInsecureLoopbackForTest
    )

    $applications = @(Invoke-CloudflareApi -Method GET -Path "/accounts/$AccountId/access/apps?per_page=100" -Token $Token -ApiBaseUri $ApiBaseUri -AllowInsecureLoopbackForTest:$AllowInsecureLoopbackForTest)
    return @($applications | Where-Object { [string]$_.domain -eq $Hostname })
}

function New-CloudflareAccessApplication {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$Token,
        [Parameter(Mandatory = $true)][string]$AccountId,
        [Parameter(Mandatory = $true)][string]$Name,
        [Parameter(Mandatory = $true)][string]$Hostname,
        [ValidatePattern('^[1-9][0-9]*(?:m|h|d)$')][string]$SessionDuration = '24h',
        [uri]$ApiBaseUri = 'https://api.cloudflare.com/client/v4',
        [switch]$AllowInsecureLoopbackForTest
    )

    $body = @{ name = $Name; domain = $Hostname; type = 'self_hosted'; session_duration = $SessionDuration; app_launcher_visible = $false }
    return Invoke-CloudflareApi -Method POST -Path "/accounts/$AccountId/access/apps" -Token $Token -Body $body -ApiBaseUri $ApiBaseUri -AllowInsecureLoopbackForTest:$AllowInsecureLoopbackForTest
}

function Get-CloudflareAccessPolicies {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$Token,
        [Parameter(Mandatory = $true)][string]$AccountId,
        [Parameter(Mandatory = $true)][string]$ApplicationId,
        [uri]$ApiBaseUri = 'https://api.cloudflare.com/client/v4',
        [switch]$AllowInsecureLoopbackForTest
    )

    return @(Invoke-CloudflareApi -Method GET -Path "/accounts/$AccountId/access/apps/$ApplicationId/policies" -Token $Token -ApiBaseUri $ApiBaseUri -AllowInsecureLoopbackForTest:$AllowInsecureLoopbackForTest)
}

function New-CloudflareAccessPolicy {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$Token,
        [Parameter(Mandatory = $true)][string]$AccountId,
        [Parameter(Mandatory = $true)][string]$ApplicationId,
        [Parameter(Mandatory = $true)][string]$Name,
        [Parameter(Mandatory = $true)][object[]]$Include,
        [uri]$ApiBaseUri = 'https://api.cloudflare.com/client/v4',
        [switch]$AllowInsecureLoopbackForTest
    )

    if ($Include.Count -lt 1) {
        throw [InvalidOperationException]::new('Access Allow Policy 至少需要一个 include 规则。')
    }
    $body = @{ name = $Name; decision = 'allow'; precedence = 1; include = $Include }
    return Invoke-CloudflareApi -Method POST -Path "/accounts/$AccountId/access/apps/$ApplicationId/policies" -Token $Token -Body $body -ApiBaseUri $ApiBaseUri -AllowInsecureLoopbackForTest:$AllowInsecureLoopbackForTest
}

function Get-CloudflareTunnelByName {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$Token,
        [Parameter(Mandatory = $true)][string]$AccountId,
        [Parameter(Mandatory = $true)][string]$Name,
        [uri]$ApiBaseUri = 'https://api.cloudflare.com/client/v4',
        [switch]$AllowInsecureLoopbackForTest
    )

    $encodedName = [uri]::EscapeDataString($Name)
    return @(Invoke-CloudflareApi -Method GET -Path "/accounts/$AccountId/cfd_tunnel?name=$encodedName&is_deleted=false" -Token $Token -ApiBaseUri $ApiBaseUri -AllowInsecureLoopbackForTest:$AllowInsecureLoopbackForTest)
}

function New-CloudflareTunnel {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$Token,
        [Parameter(Mandatory = $true)][string]$AccountId,
        [Parameter(Mandatory = $true)][string]$Name,
        [uri]$ApiBaseUri = 'https://api.cloudflare.com/client/v4',
        [switch]$AllowInsecureLoopbackForTest
    )

    return Invoke-CloudflareApi -Method POST -Path "/accounts/$AccountId/cfd_tunnel" -Token $Token -Body @{ name = $Name; config_src = 'cloudflare' } -ApiBaseUri $ApiBaseUri -AllowInsecureLoopbackForTest:$AllowInsecureLoopbackForTest
}

function Get-CloudflareTunnelToken {
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory = $true)][string]$Token,
        [Parameter(Mandatory = $true)][string]$AccountId,
        [Parameter(Mandatory = $true)][string]$TunnelId,
        [uri]$ApiBaseUri = 'https://api.cloudflare.com/client/v4',
        [switch]$AllowInsecureLoopbackForTest
    )

    return [string](Invoke-CloudflareApi -Method GET -Path "/accounts/$AccountId/cfd_tunnel/$TunnelId/token" -Token $Token -ApiBaseUri $ApiBaseUri -AllowInsecureLoopbackForTest:$AllowInsecureLoopbackForTest)
}

function Set-CloudflareTunnelConfiguration {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$Token,
        [Parameter(Mandatory = $true)][string]$AccountId,
        [Parameter(Mandatory = $true)][string]$TunnelId,
        [Parameter(Mandatory = $true)][string]$Hostname,
        [Parameter(Mandatory = $true)][string]$Service,
        [uri]$ApiBaseUri = 'https://api.cloudflare.com/client/v4',
        [switch]$AllowInsecureLoopbackForTest
    )

    $body = @{ config = @{ ingress = @(@{ hostname = $Hostname; service = $Service }, @{ service = 'http_status:404' }); 'warp-routing' = @{ enabled = $false } } }
    return Invoke-CloudflareApi -Method PUT -Path "/accounts/$AccountId/cfd_tunnel/$TunnelId/configurations" -Token $Token -Body $body -ApiBaseUri $ApiBaseUri -AllowInsecureLoopbackForTest:$AllowInsecureLoopbackForTest
}

function Get-CloudflareTunnelConfiguration {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$Token,
        [Parameter(Mandatory = $true)][string]$AccountId,
        [Parameter(Mandatory = $true)][string]$TunnelId,
        [uri]$ApiBaseUri = 'https://api.cloudflare.com/client/v4',
        [switch]$AllowInsecureLoopbackForTest
    )

    return Invoke-CloudflareApi -Method GET -Path "/accounts/$AccountId/cfd_tunnel/$TunnelId/configurations" -Token $Token -ApiBaseUri $ApiBaseUri -AllowInsecureLoopbackForTest:$AllowInsecureLoopbackForTest
}

function Get-CloudflareDnsRecordByName {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$Token,
        [Parameter(Mandatory = $true)][string]$ZoneId,
        [Parameter(Mandatory = $true)][string]$Name,
        [uri]$ApiBaseUri = 'https://api.cloudflare.com/client/v4',
        [switch]$AllowInsecureLoopbackForTest
    )

    $encodedName = [uri]::EscapeDataString($Name)
    return @(Invoke-CloudflareApi -Method GET -Path "/zones/$ZoneId/dns_records?type=CNAME&name=$encodedName" -Token $Token -ApiBaseUri $ApiBaseUri -AllowInsecureLoopbackForTest:$AllowInsecureLoopbackForTest)
}

function New-CloudflareDnsRecord {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$Token,
        [Parameter(Mandatory = $true)][string]$ZoneId,
        [Parameter(Mandatory = $true)][string]$Name,
        [Parameter(Mandatory = $true)][string]$TunnelId,
        [uri]$ApiBaseUri = 'https://api.cloudflare.com/client/v4',
        [switch]$AllowInsecureLoopbackForTest
    )

    $body = @{ type = 'CNAME'; name = $Name; content = "$TunnelId.cfargotunnel.com"; proxied = $true; ttl = 1; comment = 'managed-by:deploy-github-to-wsl' }
    return Invoke-CloudflareApi -Method POST -Path "/zones/$ZoneId/dns_records" -Token $Token -Body $body -ApiBaseUri $ApiBaseUri -AllowInsecureLoopbackForTest:$AllowInsecureLoopbackForTest
}

function Set-CloudflareDnsRecord {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$Token,
        [Parameter(Mandatory = $true)][string]$ZoneId,
        [Parameter(Mandatory = $true)][string]$RecordId,
        [Parameter(Mandatory = $true)][string]$Name,
        [Parameter(Mandatory = $true)][string]$TunnelId,
        [uri]$ApiBaseUri = 'https://api.cloudflare.com/client/v4',
        [switch]$AllowInsecureLoopbackForTest
    )

    $body = @{ type = 'CNAME'; name = $Name; content = "$TunnelId.cfargotunnel.com"; proxied = $true; ttl = 1; comment = 'managed-by:deploy-github-to-wsl' }
    return Invoke-CloudflareApi -Method PUT -Path "/zones/$ZoneId/dns_records/$RecordId" -Token $Token -Body $body -ApiBaseUri $ApiBaseUri -AllowInsecureLoopbackForTest:$AllowInsecureLoopbackForTest
}

Export-ModuleMember -Function @(
    'Get-DefaultCloudflareCredentialPath',
    'Write-CloudflareCredential',
    'Read-CloudflareCredential',
    'ConvertTo-CloudflareSafeObject',
    'Invoke-CloudflareApi',
    'Get-CloudflareZone',
    'Test-CloudflareCredential',
    'Test-CloudflareAccessCredential',
    'Get-CloudflareAccessApplications',
    'New-CloudflareAccessApplication',
    'Get-CloudflareAccessPolicies',
    'New-CloudflareAccessPolicy',
    'Get-CloudflareTunnelByName',
    'New-CloudflareTunnel',
    'Get-CloudflareTunnelToken',
    'Get-CloudflareTunnelConfiguration',
    'Set-CloudflareTunnelConfiguration',
    'Get-CloudflareDnsRecordByName',
    'New-CloudflareDnsRecord',
    'Set-CloudflareDnsRecord'
)
