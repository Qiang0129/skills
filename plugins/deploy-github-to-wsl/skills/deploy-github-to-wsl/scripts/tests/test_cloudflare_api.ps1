[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
[Console]::OutputEncoding = [Text.UTF8Encoding]::new($false)

Import-Module (Join-Path $PSScriptRoot '..\CloudflareApi.psm1') -Force

function Assert-True {
    param([bool]$Condition, [string]$Message)
    if (-not $Condition) { throw $Message }
}

$testRoot = Join-Path ([IO.Path]::GetTempPath()) ('deploy-github-to-wsl-test-' + [Guid]::NewGuid().ToString('N'))
$credentialPath = Join-Path $testRoot 'credentials\cloudflare-public.bin'
$fakeToken = 'fake-public-token-for-local-tests-only-1234567890'
$serverProcess = $null

try {
    $stored = Write-CloudflareCredential -Token $fakeToken -CredentialPath $credentialPath
    Assert-True $stored.stored 'DPAPI 凭据应写入成功。'
    $cipherText = [Convert]::ToBase64String([IO.File]::ReadAllBytes($credentialPath))
    Assert-True (-not $cipherText.Contains($fakeToken)) 'DPAPI 密文不得包含明文 Token。'
    Assert-True ((Read-CloudflareCredential -CredentialPath $credentialPath) -eq $fakeToken) '当前用户应能解密假 Token。'

    $acl = Get-Acl -LiteralPath $credentialPath
    Assert-True $acl.AreAccessRulesProtected '凭据文件必须禁用继承 ACL。'
    $currentSid = [Security.Principal.WindowsIdentity]::GetCurrent().User.Value
    $allowedSids = @($acl.Access | Where-Object AccessControlType -eq Allow | ForEach-Object { $_.IdentityReference.Translate([Security.Principal.SecurityIdentifier]).Value } | Select-Object -Unique)
    Assert-True ($allowedSids.Count -eq 1 -and $allowedSids[0] -eq $currentSid) '凭据文件只应授权当前 Windows 用户。'

    $python = (Get-Command py -ErrorAction Stop).Source
    $startInfo = [Diagnostics.ProcessStartInfo]::new($python)
    $startInfo.ArgumentList.Add('-3')
    $startInfo.ArgumentList.Add((Join-Path $PSScriptRoot 'mock_cloudflare_api.py'))
    $startInfo.RedirectStandardOutput = $true
    $startInfo.RedirectStandardError = $true
    $startInfo.UseShellExecute = $false
    $startInfo.CreateNoWindow = $true
    $serverProcess = [Diagnostics.Process]::Start($startInfo)
    $port = [int]$serverProcess.StandardOutput.ReadLine()
    $apiBaseUri = [uri]"http://127.0.0.1:$port/client/v4"

    $verification = Test-CloudflareCredential -Token $fakeToken -AccountId ('a' * 32) -ZoneName 'scuccs.me' -ApiBaseUri $apiBaseUri -AllowInsecureLoopbackForTest
    Assert-True $verification.valid '假 Token 应通过模拟 API 验证。'
    Assert-True ($verification.zoneId -eq ('b' * 32)) '应发现目标 Zone。'

    $retry = Invoke-CloudflareApi -Method GET -Path '/test/retry' -Token $fakeToken -ApiBaseUri $apiBaseUri -AllowInsecureLoopbackForTest -MaxAttempts 4
    Assert-True ($retry.attempt -eq 3) '429 应按退避策略重试。'

    foreach ($status in @(401, 403, 409, 500)) {
        try {
            [void](Invoke-CloudflareApi -Method GET -Path "/test/status/$status" -Token $fakeToken -ApiBaseUri $apiBaseUri -AllowInsecureLoopbackForTest -MaxAttempts 1)
            throw "状态码 $status 应失败。"
        }
        catch {
            Assert-True (-not $_.Exception.Message.Contains($fakeToken)) "状态码 $status 的异常不得泄露 Token。"
            Assert-True ($_.Exception.Message.Contains("cf_http_$status")) "状态码 $status 应返回脱敏错误码。"
        }
    }

    foreach ($path in @('/test/timeout', '/test/drop')) {
        try {
            [void](Invoke-CloudflareApi -Method GET -Path $path -Token $fakeToken -ApiBaseUri $apiBaseUri -AllowInsecureLoopbackForTest -TimeoutSec 1 -MaxAttempts 1)
            throw "$path 应失败。"
        }
        catch {
            Assert-True (-not $_.Exception.Message.Contains($fakeToken)) "$path 的异常不得泄露 Token。"
            Assert-True ($_.Exception.Message.Contains('cf_network_error')) "$path 应归一化为脱敏网络错误码。"
        }
    }

    $safe = ConvertTo-CloudflareSafeObject ([pscustomobject]@{ id = 'x'; token = $fakeToken; nested = @{ password = 'hidden'; name = 'safe' } })
    $safeJson = $safe | ConvertTo-Json -Depth 10 -Compress
    Assert-True (-not $safeJson.Contains($fakeToken)) '响应脱敏必须删除 Token 字段。'
    Assert-True ($safeJson.Contains('safe')) '响应脱敏应保留非敏感字段。'

    Write-Output 'Cloudflare API、DPAPI、ACL、退避与脱敏测试通过。'
}
finally {
    if ($serverProcess -and -not $serverProcess.HasExited) {
        $serverProcess.Kill($true)
        $serverProcess.WaitForExit()
    }
    if ([IO.Directory]::Exists($testRoot)) {
        $resolved = [IO.Path]::GetFullPath($testRoot)
        $expectedPrefix = [IO.Path]::GetFullPath([IO.Path]::GetTempPath())
        if ($resolved.StartsWith($expectedPrefix, [StringComparison]::OrdinalIgnoreCase) -and [IO.Path]::GetFileName($resolved).StartsWith('deploy-github-to-wsl-test-')) {
            Remove-Item -LiteralPath $resolved -Recurse -Force
        }
    }
}
