[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [ValidateSet('InitializeCredential', 'Plan', 'Apply', 'Maintain', 'Status')]
    [string]$Action,

    [string]$ManifestPath,

    [string]$CredentialPath,

    [string]$AccessCredentialPath,

    [ValidateSet('public', 'access')]
    [string]$CredentialProfile = 'public',

    [string]$AccountId,

    [string]$ZoneName = 'scuccs.me',

    [ValidateSet('Tunnel', 'Route', 'All')]
    [string]$Target = 'All',

    [switch]$ConfirmCredentialRotation,

    [uri]$ApiBaseUri = 'https://api.cloudflare.com/client/v4',

    [switch]$AllowInsecureLoopbackForTest,

    [switch]$Compact
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
[Console]::OutputEncoding = [Text.UTF8Encoding]::new($false)
$OutputEncoding = [Text.UTF8Encoding]::new($false)

Import-Module (Join-Path $PSScriptRoot 'CloudflareApi.psm1') -Force

function Get-ObjectProperty {
    param(
        [AllowNull()][object]$InputObject,
        [Parameter(Mandatory = $true)][string]$Name,
        [AllowNull()][object]$Default = $null
    )

    if ($null -eq $InputObject) {
        return $Default
    }
    $property = $InputObject.PSObject.Properties[$Name]
    if ($null -eq $property) {
        return $Default
    }
    return $property.Value
}

function ConvertFrom-JsonFile {
    param([Parameter(Mandatory = $true)][string]$LiteralPath)

    $fullPath = [IO.Path]::GetFullPath($LiteralPath)
    if (-not [IO.File]::Exists($fullPath)) {
        throw [IO.FileNotFoundException]::new("找不到部署清单：$fullPath")
    }
    try {
        return [IO.File]::ReadAllText($fullPath, [Text.UTF8Encoding]::new($false)) | ConvertFrom-Json -Depth 40
    }
    catch {
        throw [InvalidOperationException]::new('部署清单不是有效的 UTF-8 JSON。')
    }
}

function Assert-ManifestForCloudflare {
    param([Parameter(Mandatory = $true)][object]$Manifest)

    if ([string](Get-ObjectProperty $Manifest 'schemaVersion') -ne '2.0') {
        throw [InvalidOperationException]::new('Cloudflare 自动化只接受 schemaVersion 2.0 部署清单。')
    }

    $cloudflare = Get-ObjectProperty $Manifest 'cloudflare'
    $wsl = Get-ObjectProperty $Manifest 'wsl'
    $repository = Get-ObjectProperty $Manifest 'repository'
    $required = @{
        accountId = [string](Get-ObjectProperty $cloudflare 'accountId')
        zoneId = [string](Get-ObjectProperty $cloudflare 'zoneId')
        zoneName = [string](Get-ObjectProperty $cloudflare 'zoneName')
        hostname = [string](Get-ObjectProperty $cloudflare 'hostname')
        tunnelName = [string](Get-ObjectProperty $cloudflare 'tunnelName')
        service = [string](Get-ObjectProperty $cloudflare 'service')
        distribution = [string](Get-ObjectProperty $wsl 'distribution')
        slug = [string](Get-ObjectProperty $repository 'slug')
    }
    foreach ($entry in $required.GetEnumerator()) {
        if ([string]::IsNullOrWhiteSpace($entry.Value)) {
            throw [InvalidOperationException]::new("部署清单缺少 Cloudflare 必需字段：$($entry.Key)")
        }
    }

    if ($required.accountId -notmatch '^[a-fA-F0-9]{32}$' -or $required.zoneId -notmatch '^[a-fA-F0-9]{32}$') {
        throw [InvalidOperationException]::new('Cloudflare accountId 或 zoneId 格式不正确。')
    }
    if ($required.zoneName -ne 'scuccs.me') {
        throw [InvalidOperationException]::new('当前 Skill 只允许 scuccs.me Zone。')
    }
    if ($required.hostname -notmatch '^[a-z0-9](?:[a-z0-9-]{0,61}[a-z0-9])?\.scuccs\.me$') {
        throw [InvalidOperationException]::new('公网 hostname 必须是 scuccs.me 下的规范化单级子域名。')
    }
    if ($required.tunnelName -notmatch '^wsl-[a-z0-9](?:[a-z0-9-]{0,58}[a-z0-9])?$') {
        throw [InvalidOperationException]::new('Tunnel 名称不符合 wsl-<slug> 约束。')
    }
    if ($required.service -notmatch '^https?://[a-z0-9](?:[a-z0-9-]{0,62})(?::(?:[1-9][0-9]{0,4}))?$') {
        throw [InvalidOperationException]::new('Cloudflare Service 必须是 Compose 内部 HTTP(S) 服务地址。')
    }
    if ($required.distribution -notmatch '^[A-Za-z0-9][A-Za-z0-9._ -]{0,127}$') {
        throw [InvalidOperationException]::new('WSL 发行版注册名格式不正确。')
    }
    if ($required.slug -notmatch '^[a-z0-9][a-z0-9-]{0,62}$') {
        throw [InvalidOperationException]::new('项目 slug 格式不正确。')
    }

    $serialized = $Manifest | ConvertTo-Json -Depth 40 -Compress
    if ($serialized -match '(?i)"(?:token|password|secret|privateKey)"\s*:') {
        throw [InvalidOperationException]::new('部署清单不得包含密钥字段。')
    }
}

function Get-DeploymentState {
    param([Parameter(Mandatory = $true)][object]$Manifest)

    $state = Get-ObjectProperty $Manifest 'state'
    $statePath = [string](Get-ObjectProperty $state 'path')
    $distribution = [string](Get-ObjectProperty (Get-ObjectProperty $Manifest 'wsl') 'distribution')
    if (-not $statePath) {
        return $null
    }
    if ($statePath -notmatch '^/root/\.local/state/deploy-github-to-wsl/[a-z0-9][a-z0-9-]{0,62}/deployment\.json$') {
        throw [InvalidOperationException]::new('部署状态路径不符合固定 root-only 目录约束。')
    }

    $json = (& wsl.exe -d $distribution -- cat -- $statePath 2>$null | Out-String).Trim()
    if ($LASTEXITCODE -ne 0 -or -not $json) {
        return $null
    }
    try {
        return $json | ConvertFrom-Json -Depth 40
    }
    catch {
        throw [InvalidOperationException]::new('已有部署状态不是有效 JSON，拒绝推断对象所有权。')
    }
}

function Set-DeploymentObjectId {
    param(
        [Parameter(Mandatory = $true)][object]$Manifest,
        [Parameter(Mandatory = $true)][ValidateSet('tunnelId', 'dnsRecordId', 'accessApplicationId', 'accessPolicyId')][string]$ObjectType,
        [Parameter(Mandatory = $true)][string]$ObjectId
    )

    $state = Get-DeploymentState -Manifest $Manifest
    if (-not $state -or [string](Get-ObjectProperty $state 'schemaVersion') -ne '2.0') {
        throw [InvalidOperationException]::new('Cloudflare 创建对象后无法更新受信任的 v2 部署状态。')
    }
    $objects = Get-ObjectProperty $state 'objects'
    if (-not $objects) {
        $state | Add-Member -NotePropertyName objects -NotePropertyValue ([pscustomobject]@{ tunnelId = $null; dnsRecordId = $null; accessApplicationId = $null; accessPolicyId = $null })
        $objects = $state.objects
    }
    if ($objects.PSObject.Properties[$ObjectType]) {
        $objects.$ObjectType = $ObjectId
    }
    else {
        $objects | Add-Member -NotePropertyName $ObjectType -NotePropertyValue $ObjectId
    }
    if ($state.PSObject.Properties['updatedAt']) {
        $state.updatedAt = [DateTimeOffset]::Now.ToString('o')
    }

    $json = $state | ConvertTo-Json -Depth 50
    $statePath = [string]$Manifest.state.path
    $distribution = [string]$Manifest.wsl.distribution
    $writeScript = 'set -eu; umask 077; state_path="\$STATE_PATH"; state_dir="\$(dirname "\$state_path")"; install -d -m 700 -- "\$state_dir"; temporary="\$(mktemp "\$state_dir/.cloudflare-state.XXXXXX")"; trap ''rm -f -- "\$temporary"'' EXIT; cat > "\$temporary"; chmod 600 -- "\$temporary"; mv -f -- "\$temporary" "\$state_path"; trap - EXIT'
    $json | & wsl.exe -d $distribution -- env "STATE_PATH=$statePath" sh -c $writeScript 2>$null
    if ($LASTEXITCODE -ne 0) {
        throw [InvalidOperationException]::new('Cloudflare 对象所有权状态写入失败。')
    }
}

function Get-KnownObjectIds {
    param(
        [AllowNull()][object]$State,
        [Parameter(Mandatory = $true)][object]$Manifest
    )

    $known = [ordered]@{ tunnelId = $null; dnsRecordId = $null; accessApplicationId = $null; accessPolicyId = $null; trustedLegacyDns = $false }
    if ($null -eq $State) {
        return $known
    }

    $objects = Get-ObjectProperty $State 'objects'
    if ($objects) {
        $known.tunnelId = [string](Get-ObjectProperty $objects 'tunnelId')
        $known.dnsRecordId = [string](Get-ObjectProperty $objects 'dnsRecordId')
        $known.accessApplicationId = [string](Get-ObjectProperty $objects 'accessApplicationId')
        $known.accessPolicyId = [string](Get-ObjectProperty $objects 'accessPolicyId')
        return $known
    }

    # v1 部署记录由本 Skill 生成，可只读迁移其 Tunnel 所有权证据。
    $legacy = Get-ObjectProperty $State 'cloudflare'
    $target = Get-ObjectProperty $Manifest 'cloudflare'
    if ($legacy -and
        [string](Get-ObjectProperty $legacy 'tunnel_name') -eq [string](Get-ObjectProperty $target 'tunnelName') -and
        [string](Get-ObjectProperty $legacy 'hostname') -eq [string](Get-ObjectProperty $target 'hostname')) {
        $known.tunnelId = [string](Get-ObjectProperty $legacy 'tunnel_id')
        $known.trustedLegacyDns = [bool](Get-ObjectProperty $legacy 'dns_created' $false)
    }
    return $known
}

function Test-ExpectedIngress {
    param(
        [AllowNull()][object]$Configuration,
        [Parameter(Mandatory = $true)][string]$Hostname,
        [Parameter(Mandatory = $true)][string]$Service
    )

    if ($null -eq $Configuration) {
        return $false
    }
    $config = Get-ObjectProperty $Configuration 'config' $Configuration
    $ingress = @(Get-ObjectProperty $config 'ingress' @())
    if ($ingress.Count -ne 2) {
        return $false
    }
    return (
        [string](Get-ObjectProperty $ingress[0] 'hostname') -eq $Hostname -and
        [string](Get-ObjectProperty $ingress[0] 'service') -eq $Service -and
        [string](Get-ObjectProperty $ingress[1] 'service') -eq 'http_status:404'
    )
}

function Get-CloudflareDeploymentPlan {
    param(
        [Parameter(Mandatory = $true)][object]$Manifest,
        [Parameter(Mandatory = $true)][string]$Token
    )

    Assert-ManifestForCloudflare -Manifest $Manifest
    $cloudflare = $Manifest.cloudflare
    $credential = Test-CloudflareCredential -Token $Token -AccountId $cloudflare.accountId -ZoneName $cloudflare.zoneName -ApiBaseUri $ApiBaseUri -AllowInsecureLoopbackForTest:$AllowInsecureLoopbackForTest
    if ([string]$credential.zoneId -ne [string]$cloudflare.zoneId) {
        throw [InvalidOperationException]::new('凭据发现到的 Zone ID 与部署清单不一致。')
    }

    $state = Get-DeploymentState -Manifest $Manifest
    $known = Get-KnownObjectIds -State $state -Manifest $Manifest
    $changes = [Collections.Generic.List[object]]::new()
    $blockers = [Collections.Generic.List[object]]::new()
    $tunnels = @(Get-CloudflareTunnelByName -Token $Token -AccountId $cloudflare.accountId -Name $cloudflare.tunnelName -ApiBaseUri $ApiBaseUri -AllowInsecureLoopbackForTest:$AllowInsecureLoopbackForTest)
    $tunnelId = $null

    if ($tunnels.Count -gt 1) {
        $blockers.Add([ordered]@{ code = 'duplicate_tunnel_name'; object = $cloudflare.tunnelName })
    }
    elseif ($tunnels.Count -eq 1) {
        $tunnelId = [string]$tunnels[0].id
        if (-not $known.tunnelId -or $known.tunnelId -ne $tunnelId) {
            $blockers.Add([ordered]@{ code = 'unmanaged_tunnel_conflict'; object = $cloudflare.tunnelName })
        }
        else {
            $configuration = Get-CloudflareTunnelConfiguration -Token $Token -AccountId $cloudflare.accountId -TunnelId $tunnelId -ApiBaseUri $ApiBaseUri -AllowInsecureLoopbackForTest:$AllowInsecureLoopbackForTest
            if (-not (Test-ExpectedIngress -Configuration $configuration -Hostname $cloudflare.hostname -Service $cloudflare.service)) {
                $changes.Add([ordered]@{ action = 'update'; kind = 'tunnel_configuration'; id = $tunnelId; name = $cloudflare.tunnelName })
            }
        }
    }
    elseif ($known.tunnelId) {
        $blockers.Add([ordered]@{ code = 'managed_tunnel_missing'; object = $cloudflare.tunnelName })
    }
    else {
        $changes.Add([ordered]@{ action = 'create'; kind = 'tunnel'; name = $cloudflare.tunnelName })
        $changes.Add([ordered]@{ action = 'create'; kind = 'tunnel_configuration'; name = $cloudflare.tunnelName })
    }

    $records = @(Get-CloudflareDnsRecordByName -Token $Token -ZoneId $cloudflare.zoneId -Name $cloudflare.hostname -ApiBaseUri $ApiBaseUri -AllowInsecureLoopbackForTest:$AllowInsecureLoopbackForTest)
    $dnsRecordId = $null
    if ($records.Count -gt 1) {
        $blockers.Add([ordered]@{ code = 'duplicate_dns_name'; object = $cloudflare.hostname })
    }
    elseif ($records.Count -eq 1) {
        $dnsRecordId = [string]$records[0].id
        $trusted = ($known.dnsRecordId -and $known.dnsRecordId -eq $dnsRecordId) -or $known.trustedLegacyDns
        if (-not $trusted) {
            $blockers.Add([ordered]@{ code = 'unmanaged_dns_conflict'; object = $cloudflare.hostname })
        }
        elseif ($tunnelId -and (
            [string]$records[0].content -ne "$tunnelId.cfargotunnel.com" -or
            -not [bool]$records[0].proxied
        )) {
            $changes.Add([ordered]@{ action = 'update'; kind = 'dns_record'; id = $dnsRecordId; name = $cloudflare.hostname })
        }
    }
    elseif ($known.dnsRecordId) {
        $blockers.Add([ordered]@{ code = 'managed_dns_missing'; object = $cloudflare.hostname })
    }
    else {
        $changes.Add([ordered]@{ action = 'create'; kind = 'dns_record'; name = $cloudflare.hostname })
    }

    $accessApplicationId = $null
    $accessPolicyId = $null
    $accessMode = [string](Get-ObjectProperty $cloudflare 'accessMode' 'anonymous')
    if ($accessMode -eq 'access') {
        $access = Get-ObjectProperty $cloudflare 'access'
        $applicationName = [string](Get-ObjectProperty $access 'applicationName')
        $policyName = [string](Get-ObjectProperty $access 'policyName')
        $includeRules = @(Get-ObjectProperty $access 'include' @())
        $sessionDuration = [string](Get-ObjectProperty $access 'sessionDuration' '24h')
        if ($applicationName -notmatch '^[A-Za-z0-9][A-Za-z0-9 _.-]{0,99}$' -or
            $policyName -notmatch '^[A-Za-z0-9][A-Za-z0-9 _.-]{0,99}$' -or
            $sessionDuration -notmatch '^[1-9][0-9]*(?:m|h|d)$' -or
            $includeRules.Count -lt 1) {
            $blockers.Add([ordered]@{ code = 'access_decision_incomplete'; object = $cloudflare.hostname })
        }
        else {
            $resolvedAccessCredentialPath = if ($AccessCredentialPath) { $AccessCredentialPath } else { Get-DefaultCloudflareCredentialPath -Profile access }
            if (-not [IO.File]::Exists([IO.Path]::GetFullPath($resolvedAccessCredentialPath))) {
                $blockers.Add([ordered]@{ code = 'access_credential_required'; object = $cloudflare.hostname })
            }
            else {
                $accessToken = $null
                try {
                    $accessToken = Read-CloudflareCredential -CredentialPath $resolvedAccessCredentialPath
                    $accessVerification = Test-CloudflareAccessCredential -Token $accessToken -AccountId $cloudflare.accountId -ApiBaseUri $ApiBaseUri -AllowInsecureLoopbackForTest:$AllowInsecureLoopbackForTest
                    if (-not $accessVerification.valid) {
                        $blockers.Add([ordered]@{ code = 'access_credential_invalid'; object = $cloudflare.hostname })
                    }
                    else {
                        $applications = @(Get-CloudflareAccessApplications -Token $accessToken -AccountId $cloudflare.accountId -Hostname $cloudflare.hostname -ApiBaseUri $ApiBaseUri -AllowInsecureLoopbackForTest:$AllowInsecureLoopbackForTest)
                        if ($applications.Count -gt 1) {
                            $blockers.Add([ordered]@{ code = 'duplicate_access_application'; object = $cloudflare.hostname })
                        }
                        elseif ($applications.Count -eq 1) {
                            $accessApplicationId = [string]$applications[0].id
                            if (-not $known.accessApplicationId -or $known.accessApplicationId -ne $accessApplicationId) {
                                $blockers.Add([ordered]@{ code = 'unmanaged_access_application_conflict'; object = $cloudflare.hostname })
                            }
                            else {
                                $policies = @(Get-CloudflareAccessPolicies -Token $accessToken -AccountId $cloudflare.accountId -ApplicationId $accessApplicationId -ApiBaseUri $ApiBaseUri -AllowInsecureLoopbackForTest:$AllowInsecureLoopbackForTest)
                                $managedPolicy = @($policies | Where-Object { [string]$_.id -eq $known.accessPolicyId })
                                if ($managedPolicy.Count -eq 1) {
                                    $accessPolicyId = [string]$managedPolicy[0].id
                                }
                                elseif ($known.accessPolicyId) {
                                    $blockers.Add([ordered]@{ code = 'managed_access_policy_missing'; object = $policyName })
                                }
                                else {
                                    $changes.Add([ordered]@{ action = 'create'; kind = 'access_policy'; name = $policyName })
                                }
                            }
                        }
                        elseif ($known.accessApplicationId) {
                            $blockers.Add([ordered]@{ code = 'managed_access_application_missing'; object = $cloudflare.hostname })
                        }
                        else {
                            $changes.Add([ordered]@{ action = 'create'; kind = 'access_application'; name = $applicationName })
                            $changes.Add([ordered]@{ action = 'create'; kind = 'access_policy'; name = $policyName })
                        }
                    }
                }
                finally {
                    $accessToken = $null
                }
            }
        }
    }

    return [ordered]@{
        schemaVersion = '2.0'
        action = 'Plan'
        readOnly = $true
        accountId = $cloudflare.accountId
        zoneId = $cloudflare.zoneId
        zoneName = $cloudflare.zoneName
        hostname = $cloudflare.hostname
        tunnelName = $cloudflare.tunnelName
        objects = [ordered]@{ tunnelId = $tunnelId; dnsRecordId = $dnsRecordId; accessApplicationId = $accessApplicationId; accessPolicyId = $accessPolicyId }
        changes = @($changes)
        blockers = @($blockers)
        hasChanges = $changes.Count -gt 0
        canApply = $blockers.Count -eq 0
    }
}

function Write-TunnelTokenToWsl {
    param(
        [Parameter(Mandatory = $true)][string]$Token,
        [Parameter(Mandatory = $true)][object]$Manifest
    )

    $slug = [string]$Manifest.repository.slug
    $distribution = [string]$Manifest.wsl.distribution
    $defaultPath = "/root/.config/deploy-github-to-wsl/$slug/secrets/tunnel_token"
    $tokenPath = [string](Get-ObjectProperty $Manifest.cloudflare 'tunnelTokenPath' $defaultPath)
    if ($tokenPath -ne $defaultPath) {
        throw [InvalidOperationException]::new('Tunnel Token 路径必须使用项目固定的 root-only 目录。')
    }

    $writeScript = 'set -eu; umask 077; token_path="\$TOKEN_PATH"; token_dir="\$(dirname "\$token_path")"; install -d -m 700 -- "\$token_dir"; temporary="\$(mktemp "\$token_dir/.tunnel_token.XXXXXX")"; trap ''rm -f -- "\$temporary"'' EXIT; cat > "\$temporary"; chmod 600 -- "\$temporary"; mv -f -- "\$temporary" "\$token_path"; trap - EXIT'
    $Token | & wsl.exe -d $distribution -- env "TOKEN_PATH=$tokenPath" sh -c $writeScript 2>$null
    if ($LASTEXITCODE -ne 0) {
        throw [InvalidOperationException]::new('Tunnel Token 通过标准输入写入 WSL 失败。')
    }
    $permission = (& wsl.exe -d $distribution -- stat -c '%a' -- $tokenPath 2>$null | Out-String).Trim()
    if ($LASTEXITCODE -ne 0 -or $permission -ne '600') {
        throw [InvalidOperationException]::new('Tunnel Token 文件权限验证失败。')
    }
    return [ordered]@{ stored = $true; path = $tokenPath; permission = $permission }
}

function Invoke-CloudflareDeploymentApply {
    param(
        [Parameter(Mandatory = $true)][object]$Manifest,
        [Parameter(Mandatory = $true)][string]$Token
    )

    $plan = Get-CloudflareDeploymentPlan -Manifest $Manifest -Token $Token
    if (-not $plan.canApply) {
        throw [InvalidOperationException]::new('Cloudflare 预检发现冲突或权限边界，未执行任何写操作。')
    }

    $cloudflare = $Manifest.cloudflare
    $tunnelId = [string]$plan.objects.tunnelId
    $dnsRecordId = [string]$plan.objects.dnsRecordId
    $accessApplicationId = [string]$plan.objects.accessApplicationId
    $accessPolicyId = [string]$plan.objects.accessPolicyId
    $created = [Collections.Generic.List[object]]::new()
    $updated = [Collections.Generic.List[object]]::new()
    $tokenFile = $null

    if ($Target -in @('Tunnel', 'All')) {
        if (-not $tunnelId) {
            $tunnel = New-CloudflareTunnel -Token $Token -AccountId $cloudflare.accountId -Name $cloudflare.tunnelName -ApiBaseUri $ApiBaseUri -AllowInsecureLoopbackForTest:$AllowInsecureLoopbackForTest
            $tunnelId = [string]$tunnel.id
            Set-DeploymentObjectId -Manifest $Manifest -ObjectType tunnelId -ObjectId $tunnelId
            $created.Add([ordered]@{ kind = 'tunnel'; id = $tunnelId; name = $cloudflare.tunnelName })
        }
        if (-not $tunnelId) {
            throw [InvalidOperationException]::new('Cloudflare 未返回 Tunnel ID，停止后续写入。')
        }

        $needsConfiguration = -not $plan.objects.tunnelId -or @($plan.changes | Where-Object { $_.kind -eq 'tunnel_configuration' }).Count -gt 0
        if ($needsConfiguration) {
            [void](Set-CloudflareTunnelConfiguration -Token $Token -AccountId $cloudflare.accountId -TunnelId $tunnelId -Hostname $cloudflare.hostname -Service $cloudflare.service -ApiBaseUri $ApiBaseUri -AllowInsecureLoopbackForTest:$AllowInsecureLoopbackForTest)
            $updated.Add([ordered]@{ kind = 'tunnel_configuration'; id = $tunnelId; name = $cloudflare.tunnelName })
        }

        $runtimeToken = $null
        try {
            $runtimeToken = Get-CloudflareTunnelToken -Token $Token -AccountId $cloudflare.accountId -TunnelId $tunnelId -ApiBaseUri $ApiBaseUri -AllowInsecureLoopbackForTest:$AllowInsecureLoopbackForTest
            $tokenFile = Write-TunnelTokenToWsl -Token $runtimeToken -Manifest $Manifest
        }
        finally {
            $runtimeToken = $null
        }
    }

    if ($Target -in @('Route', 'All')) {
        if (-not $tunnelId) {
            $state = Get-DeploymentState -Manifest $Manifest
            $known = Get-KnownObjectIds -State $state -Manifest $Manifest
            $tunnelId = [string]$known.tunnelId
        }
        if (-not $tunnelId) {
            throw [InvalidOperationException]::new('创建 DNS 前必须有受信任的 Tunnel ID。')
        }

        if ([string](Get-ObjectProperty $cloudflare 'accessMode' 'anonymous') -eq 'access') {
            $access = $cloudflare.access
            $resolvedAccessCredentialPath = if ($AccessCredentialPath) { $AccessCredentialPath } else { Get-DefaultCloudflareCredentialPath -Profile access }
            $accessToken = $null
            try {
                $accessToken = Read-CloudflareCredential -CredentialPath $resolvedAccessCredentialPath
                if (-not $accessApplicationId) {
                    $application = New-CloudflareAccessApplication -Token $accessToken -AccountId $cloudflare.accountId -Name $access.applicationName -Hostname $cloudflare.hostname -SessionDuration ([string](Get-ObjectProperty $access 'sessionDuration' '24h')) -ApiBaseUri $ApiBaseUri -AllowInsecureLoopbackForTest:$AllowInsecureLoopbackForTest
                    $accessApplicationId = [string]$application.id
                    Set-DeploymentObjectId -Manifest $Manifest -ObjectType accessApplicationId -ObjectId $accessApplicationId
                    $created.Add([ordered]@{ kind = 'access_application'; id = $accessApplicationId; name = $access.applicationName })
                }
                if (-not $accessPolicyId) {
                    $policy = New-CloudflareAccessPolicy -Token $accessToken -AccountId $cloudflare.accountId -ApplicationId $accessApplicationId -Name $access.policyName -Include @($access.include) -ApiBaseUri $ApiBaseUri -AllowInsecureLoopbackForTest:$AllowInsecureLoopbackForTest
                    $accessPolicyId = [string]$policy.id
                    Set-DeploymentObjectId -Manifest $Manifest -ObjectType accessPolicyId -ObjectId $accessPolicyId
                    $created.Add([ordered]@{ kind = 'access_policy'; id = $accessPolicyId; name = $access.policyName })
                }
            }
            finally {
                $accessToken = $null
            }
        }

        if (-not $dnsRecordId) {
            $record = New-CloudflareDnsRecord -Token $Token -ZoneId $cloudflare.zoneId -Name $cloudflare.hostname -TunnelId $tunnelId -ApiBaseUri $ApiBaseUri -AllowInsecureLoopbackForTest:$AllowInsecureLoopbackForTest
            $dnsRecordId = [string]$record.id
            Set-DeploymentObjectId -Manifest $Manifest -ObjectType dnsRecordId -ObjectId $dnsRecordId
            $created.Add([ordered]@{ kind = 'dns_record'; id = $dnsRecordId; name = $cloudflare.hostname })
        }
        elseif (@($plan.changes | Where-Object { $_.kind -eq 'dns_record' }).Count -gt 0) {
            [void](Set-CloudflareDnsRecord -Token $Token -ZoneId $cloudflare.zoneId -RecordId $dnsRecordId -Name $cloudflare.hostname -TunnelId $tunnelId -ApiBaseUri $ApiBaseUri -AllowInsecureLoopbackForTest:$AllowInsecureLoopbackForTest)
            $updated.Add([ordered]@{ kind = 'dns_record'; id = $dnsRecordId; name = $cloudflare.hostname })
        }
    }

    return [ordered]@{
        schemaVersion = '2.0'
        action = 'Apply'
        target = $Target
        objects = [ordered]@{ tunnelId = $tunnelId; dnsRecordId = $dnsRecordId; accessApplicationId = $accessApplicationId; accessPolicyId = $accessPolicyId }
        created = @($created)
        updated = @($updated)
        tokenFile = $tokenFile
    }
}

function Invoke-CloudflareManagedMaintenance {
    param(
        [Parameter(Mandatory = $true)][object]$Manifest,
        [Parameter(Mandatory = $true)][string]$Token
    )

    Assert-ManifestForCloudflare -Manifest $Manifest
    $state = Get-DeploymentState -Manifest $Manifest
    if (-not $state -or [string](Get-ObjectProperty $state 'schemaVersion') -ne '2.0' -or [string](Get-ObjectProperty $state 'currentStage') -ne 'complete') {
        throw [InvalidOperationException]::new('Cloudflare 维护仅允许已完成的受管 v2 部署。')
    }

    $cloudflare = $Manifest.cloudflare
    $known = Get-KnownObjectIds -State $state -Manifest $Manifest
    if (-not $known.tunnelId -or -not $known.dnsRecordId) {
        throw [InvalidOperationException]::new('Cloudflare 维护缺少受管 Tunnel 或 DNS 所有权证据。')
    }
    if ([string](Get-ObjectProperty $cloudflare 'accessMode' 'anonymous') -ne 'anonymous' -or $known.accessApplicationId -or $known.accessPolicyId) {
        throw [InvalidOperationException]::new('Access 对象不属于自治 Cloudflare 维护范围。')
    }

    $plan = Get-CloudflareDeploymentPlan -Manifest $Manifest -Token $Token
    if (-not $plan.canApply) {
        throw [InvalidOperationException]::new('Cloudflare 维护预检发现冲突或对象漂移。')
    }
    if ([string]$plan.objects.tunnelId -ne [string]$known.tunnelId -or [string]$plan.objects.dnsRecordId -ne [string]$known.dnsRecordId) {
        throw [InvalidOperationException]::new('Cloudflare 维护对象 ID 与部署状态不一致。')
    }

    $allowedKinds = @('tunnel_configuration', 'dns_record')
    foreach ($change in @($plan.changes)) {
        if ([string](Get-ObjectProperty $change 'action') -ne 'update' -or [string](Get-ObjectProperty $change 'kind') -notin $allowedKinds) {
            throw [InvalidOperationException]::new('Cloudflare 维护请求包含创建、接管或未受支持的对象变更。')
        }
    }

    $updated = [Collections.Generic.List[object]]::new()
    foreach ($change in @($plan.changes)) {
        if ([string]$change.kind -eq 'tunnel_configuration') {
            [void](Set-CloudflareTunnelConfiguration -Token $Token -AccountId $cloudflare.accountId -TunnelId $known.tunnelId -Hostname $cloudflare.hostname -Service $cloudflare.service -ApiBaseUri $ApiBaseUri -AllowInsecureLoopbackForTest:$AllowInsecureLoopbackForTest)
        }
        elseif ([string]$change.kind -eq 'dns_record') {
            [void](Set-CloudflareDnsRecord -Token $Token -ZoneId $cloudflare.zoneId -RecordId $known.dnsRecordId -Name $cloudflare.hostname -TunnelId $known.tunnelId -ApiBaseUri $ApiBaseUri -AllowInsecureLoopbackForTest:$AllowInsecureLoopbackForTest)
        }
        $updated.Add([ordered]@{ kind = [string]$change.kind; id = [string]$change.id; name = [string]$change.name })
    }

    return [ordered]@{
        schemaVersion = '2.0'
        action = 'Maintain'
        objects = [ordered]@{ tunnelId = [string]$known.tunnelId; dnsRecordId = [string]$known.dnsRecordId }
        updated = @($updated)
        blocked = $false
    }
}

function Write-JsonResult {
    param([Parameter(Mandatory = $true)][object]$Value)

    if ($Compact) {
        $Value | ConvertTo-Json -Depth 40 -Compress
    }
    else {
        $Value | ConvertTo-Json -Depth 40
    }
}

$apiToken = $null
$clipboardText = $null
try {
    if (-not $CredentialPath) {
        $CredentialPath = Get-DefaultCloudflareCredentialPath -Profile $CredentialProfile
    }

    if ($Action -eq 'InitializeCredential') {
        if ($AccountId -notmatch '^[a-fA-F0-9]{32}$') {
            throw [InvalidOperationException]::new('InitializeCredential 必须提供合法的 Cloudflare Account ID。')
        }
        if (-not (Get-Command Get-Clipboard -ErrorAction SilentlyContinue)) {
            throw [InvalidOperationException]::new('当前 PowerShell 不支持读取剪贴板。')
        }
        if ([IO.File]::Exists([IO.Path]::GetFullPath($CredentialPath)) -and -not $ConfirmCredentialRotation) {
            throw [InvalidOperationException]::new('Cloudflare 凭据已存在；轮换必须单独确认。')
        }

        try {
            $clipboardText = [string](Get-Clipboard -Raw)
            $apiToken = $clipboardText.Trim()
            $verification = if ($CredentialProfile -eq 'access') {
                Test-CloudflareAccessCredential -Token $apiToken -AccountId $AccountId -ApiBaseUri $ApiBaseUri -AllowInsecureLoopbackForTest:$AllowInsecureLoopbackForTest
            }
            else {
                Test-CloudflareCredential -Token $apiToken -AccountId $AccountId -ZoneName $ZoneName -ApiBaseUri $ApiBaseUri -AllowInsecureLoopbackForTest:$AllowInsecureLoopbackForTest
            }
            if (-not $verification.valid) {
                throw [InvalidOperationException]::new('Cloudflare API Token 未处于 active 状态。')
            }
            $stored = Write-CloudflareCredential -Token $apiToken -CredentialPath $CredentialPath -AllowReplace:$ConfirmCredentialRotation
            Write-JsonResult ([ordered]@{
                schemaVersion = '2.0'
                action = 'InitializeCredential'
                stored = $stored.stored
                credentialPath = $stored.path
                protection = $stored.protection
                credentialProfile = $CredentialProfile
                accountId = $verification.accountId
                zoneId = [string](Get-ObjectProperty -InputObject $verification -Name 'zoneId')
                zoneName = [string](Get-ObjectProperty -InputObject $verification -Name 'zoneName')
                clipboardCleared = $true
            })
        }
        finally {
            $apiToken = $null
            $clipboardText = $null
            Set-Clipboard -Value ''
        }
    }
    else {
        if (-not $ManifestPath) {
            throw [InvalidOperationException]::new("$Action 必须提供 -ManifestPath。")
        }
        $manifest = ConvertFrom-JsonFile -LiteralPath $ManifestPath
        $apiToken = Read-CloudflareCredential -CredentialPath $CredentialPath
        if ($Action -eq 'Plan') {
            Write-JsonResult (Get-CloudflareDeploymentPlan -Manifest $manifest -Token $apiToken)
        }
        elseif ($Action -eq 'Apply') {
            Write-JsonResult (Invoke-CloudflareDeploymentApply -Manifest $manifest -Token $apiToken)
        }
        elseif ($Action -eq 'Maintain') {
            Write-JsonResult (Invoke-CloudflareManagedMaintenance -Manifest $manifest -Token $apiToken)
        }
        else {
            $status = Get-CloudflareDeploymentPlan -Manifest $manifest -Token $apiToken
            $status.action = 'Status'
            Write-JsonResult $status
        }
    }
}
catch {
    $safeMessage = if ($_.Exception.Message -match '(?i)(token|secret|password|authorization)\s*[:=]') {
        'Cloudflare 操作失败，异常内容已脱敏。'
    }
    else {
        $_.Exception.Message
    }
    Write-JsonResult ([ordered]@{
        schemaVersion = '2.0'
        action = $Action
        error = [ordered]@{ code = 'cloudflare_operation_failed'; message = $safeMessage }
    })
    $global:LASTEXITCODE = 2
    return
}
finally {
    $apiToken = $null
}

$global:LASTEXITCODE = 0
