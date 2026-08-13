[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [ValidateSet('Inspect', 'Apply', 'Resume')]
    [string]$Mode,

    [Parameter(Mandatory = $true)]
    [string]$RequestPath,

    [string]$CredentialPath,

    [uri]$ApiBaseUri = 'https://api.cloudflare.com/client/v4',

    [switch]$AllowInsecureLoopbackForTest,

    [switch]$Compact
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
[Console]::OutputEncoding = [Text.UTF8Encoding]::new($false)
$OutputEncoding = [Text.UTF8Encoding]::new($false)

$script:CloudflareScript = Join-Path $PSScriptRoot 'cloudflare.ps1'

function Get-ObjectProperty {
    param([AllowNull()][object]$InputObject, [Parameter(Mandatory = $true)][string]$Name, [AllowNull()][object]$Default = $null)
    if ($null -eq $InputObject) { return $Default }
    $property = $InputObject.PSObject.Properties[$Name]
    if ($null -eq $property) { return $Default }
    return $property.Value
}

function Write-JsonResult {
    param([Parameter(Mandatory = $true)][object]$Value)
    if ($Compact) { $Value | ConvertTo-Json -Depth 50 -Compress } else { $Value | ConvertTo-Json -Depth 50 }
}

function Get-Sha256 {
    param([Parameter(Mandatory = $true)][byte[]]$Bytes)
    try { return ([Convert]::ToHexString([Security.Cryptography.SHA256]::HashData($Bytes))).ToLowerInvariant() }
    finally { [Array]::Clear($Bytes, 0, $Bytes.Length) }
}

function Get-CanonicalObject {
    param([AllowNull()][object]$InputObject)
    if ($null -eq $InputObject -or $InputObject -is [string] -or $InputObject.GetType().IsPrimitive) { return $InputObject }
    if ($InputObject -is [Collections.IDictionary]) {
        $result = [ordered]@{}
        foreach ($key in @($InputObject.Keys | Sort-Object)) { $result[[string]$key] = Get-CanonicalObject $InputObject[$key] }
        return $result
    }
    if ($InputObject -is [Collections.IEnumerable]) { return @($InputObject | ForEach-Object { Get-CanonicalObject $_ }) }
    $result = [ordered]@{}
    foreach ($property in @($InputObject.PSObject.Properties | Sort-Object Name)) { $result[$property.Name] = Get-CanonicalObject $property.Value }
    return $result
}

function Get-RequestHash {
    param([Parameter(Mandatory = $true)][object]$Request)
    $json = (Get-CanonicalObject $Request | ConvertTo-Json -Depth 50 -Compress)
    $bytes = [Text.Encoding]::UTF8.GetBytes($json)
    return Get-Sha256 -Bytes $bytes
}

function Read-JsonFile {
    param([Parameter(Mandatory = $true)][string]$Path, [Parameter(Mandatory = $true)][string]$Description)
    $fullPath = [IO.Path]::GetFullPath($Path)
    if (-not [IO.File]::Exists($fullPath)) { throw [IO.FileNotFoundException]::new("找不到$Description：$fullPath") }
    try { return [IO.File]::ReadAllText($fullPath, [Text.UTF8Encoding]::new($false)) | ConvertFrom-Json -Depth 50 }
    catch { throw [InvalidOperationException]::new("$Description 不是有效的 UTF-8 JSON。") }
}

function Invoke-Wsl {
    param([Parameter(Mandatory = $true)][string]$Distribution, [Parameter(Mandatory = $true)][string[]]$Arguments, [switch]$AllowFailure)
    $output = @(& wsl.exe -d $Distribution -- @Arguments 2>&1)
    $exitCode = $LASTEXITCODE
    if ($exitCode -ne 0 -and -not $AllowFailure) { throw [InvalidOperationException]::new('WSL 维护命令失败；详细输出未写入维护记录。') }
    return [ordered]@{ exitCode = $exitCode; output = @($output | ForEach-Object { [string]$_ }) }
}

function Get-StatePath {
    param([Parameter(Mandatory = $true)][string]$Slug)
    return "/root/.local/state/deploy-github-to-wsl/$Slug/deployment.json"
}

function Assert-Request {
    param([Parameter(Mandatory = $true)][object]$Request)
    if ([string](Get-ObjectProperty $Request 'schemaVersion') -ne '1.0' -or [string](Get-ObjectProperty $Request 'kind') -ne 'deploy-github-to-wsl/maintenance-request') {
        throw [InvalidOperationException]::new('维护请求必须使用 schemaVersion 1.0 和受支持的 kind。')
    }
    $operationId = [string](Get-ObjectProperty $Request 'operationId')
    $project = Get-ObjectProperty $Request 'project'
    $operation = Get-ObjectProperty $Request 'operation'
    if ($operationId -notmatch '^[a-z0-9][a-z0-9-]{0,62}$') { throw [InvalidOperationException]::new('维护操作 ID 格式不正确。') }
    if ([string](Get-ObjectProperty $project 'slug') -notmatch '^[a-z0-9][a-z0-9-]{0,62}$') { throw [InvalidOperationException]::new('维护项目 slug 格式不正确。') }
    if ([string](Get-ObjectProperty $operation 'type') -notin @('inspect', 'service.restart', 'service.rebuild', 'overlay.apply', 'cloudflare.sync', 'account.create', 'account.reset-password', 'account.update-roles', 'account.disable', 'account.soft-delete')) {
        throw [InvalidOperationException]::new('维护请求包含未受支持或高风险的操作类型。')
    }
    $serialized = $Request | ConvertTo-Json -Depth 50 -Compress
    if ($serialized -match '(?i)"(?:token|secret|privateKey|sql|password(?!Source))"\s*:') {
        throw [InvalidOperationException]::new('维护请求不得包含密钥、密码或任意 SQL。')
    }
}

function Get-DeploymentState {
    param([Parameter(Mandatory = $true)][string]$Distribution, [Parameter(Mandatory = $true)][string]$Slug)
    $path = Get-StatePath -Slug $Slug
    $result = Invoke-Wsl -Distribution $Distribution -Arguments @('cat', '--', $path) -AllowFailure
    if ($result.exitCode -ne 0) { throw [InvalidOperationException]::new('找不到受管部署状态，拒绝维护。') }
    try { $state = (($result.output -join "`n").Trim() | ConvertFrom-Json -Depth 50) }
    catch { throw [InvalidOperationException]::new('受管部署状态不是有效 JSON，拒绝维护。') }
    if ([string](Get-ObjectProperty $state 'schemaVersion') -ne '2.0' -or [string](Get-ObjectProperty $state 'currentStage') -ne 'complete') {
        throw [InvalidOperationException]::new('仅已完成的 v2 部署可进入自治维护。')
    }
    if ([string](Get-ObjectProperty (Get-ObjectProperty $state 'project') 'slug') -ne $Slug) {
        throw [InvalidOperationException]::new('部署状态与请求项目不匹配。')
    }
    return $state
}

function Get-ProjectContext {
    param([Parameter(Mandatory = $true)][object]$Request, [Parameter(Mandatory = $true)][object]$State)
    $slug = [string]$Request.project.slug
    $distribution = [string](Get-ObjectProperty $Request.project 'distribution' 'Ubuntu')
    if ($distribution -notmatch '^[A-Za-z0-9][A-Za-z0-9._ -]{0,127}$') { throw [InvalidOperationException]::new('WSL 发行版名称格式不正确。') }
    $project = Get-ObjectProperty $State 'project'
    $projectName = [string](Get-ObjectProperty $project 'composeProject' "codex-$slug")
    if ($projectName -ne "codex-$slug") { throw [InvalidOperationException]::new('Compose 项目名不符合受管命名约束。') }
    $repository = Get-ObjectProperty $State 'repository'
    $commit = [string](Get-ObjectProperty $repository 'commit')
    if ($commit -notmatch '^[a-f0-9]{40}$') { throw [InvalidOperationException]::new('部署状态缺少固定提交，拒绝维护。') }
    $sourcePath = [string](Get-ObjectProperty $repository 'sourcePath' "/root/projects/$slug")
    if ($sourcePath -ne "/root/projects/$slug") { throw [InvalidOperationException]::new('源码路径不符合受管目录约束。') }
    $compose = Get-ObjectProperty $State 'compose'
    $files = @((Get-ObjectProperty $compose 'files' @("$sourcePath/.codex-deploy/compose.yaml")))
    if ($files.Count -ne 1 -or [string]$files[0] -ne "$sourcePath/.codex-deploy/compose.yaml") { throw [InvalidOperationException]::new('维护仅支持受管主 Compose 文件。') }
    $profiles = @((Get-ObjectProperty $compose 'profiles' @()))
    $legacyProfileDiscovery = $profiles.Count -eq 0
    if (-not $legacyProfileDiscovery -and 'tunnel' -notin $profiles) { throw [InvalidOperationException]::new('受管 Compose 缺少 tunnel profile。') }
    $maintenance = Get-ObjectProperty $State 'maintenance'
    $services = @((Get-ObjectProperty $maintenance 'services' @()))
    $stateHashes = Get-ObjectProperty $State 'hashes'
    $maintenanceBaseline = ($null -ne $maintenance -and
        [string](Get-ObjectProperty $maintenance 'schemaVersion') -eq '1.0' -and
        $services.Count -gt 0 -and
        -not $legacyProfileDiscovery -and
        [string](Get-ObjectProperty $stateHashes 'composeConfig') -match '^[a-f0-9]{64}$')
    return [ordered]@{ slug = $slug; distribution = $distribution; projectName = $projectName; sourcePath = $sourcePath; composePath = [string]$files[0]; profiles = $profiles; legacyProfileDiscovery = $legacyProfileDiscovery; maintenanceBaseline = $maintenanceBaseline; commit = $commit; statePath = Get-StatePath -Slug $slug; services = @($services | Select-Object -Unique); legacyServiceDiscovery = ($services.Count -eq 0); state = $State }
}

function Get-ComposeArguments {
    param([Parameter(Mandatory = $true)][object]$Context)
    if ([bool]$Context.legacyProfileDiscovery) {
        $profileScript = 'import sys, yaml; data=yaml.safe_load(open(sys.argv[1], encoding="utf-8")) or {}; profiles=sorted({profile for service in (data.get("services") or {}).values() if isinstance(service, dict) for profile in (service.get("profiles") or [])}); print("\n".join(profiles))'
        $profileResult = Invoke-Wsl -Distribution $Context.distribution -Arguments @('python3', '-c', $profileScript, $Context.composePath)
        $Context.profiles = @($profileResult.output | Where-Object { $_ -match '^[A-Za-z0-9][A-Za-z0-9_.-]{0,62}$' } | Select-Object -Unique)
        if ('tunnel' -notin @($Context.profiles)) { throw [InvalidOperationException]::new('旧部署 Compose 缺少 tunnel profile。') }
        $Context.legacyProfileDiscovery = $false
    }
    $arguments = [Collections.Generic.List[string]]::new()
    $arguments.Add('compose'); $arguments.Add('-p'); $arguments.Add($Context.projectName); $arguments.Add('-f'); $arguments.Add($Context.composePath)
    foreach ($profile in @($Context.profiles)) { $arguments.Add('--profile'); $arguments.Add([string]$profile) }
    return @($arguments)
}

function Invoke-Compose {
    param([Parameter(Mandatory = $true)][object]$Context, [Parameter(Mandatory = $true)][string[]]$Arguments, [switch]$AllowFailure)
    return Invoke-Wsl -Distribution $Context.distribution -Arguments (@('docker') + (Get-ComposeArguments -Context $Context) + $Arguments) -AllowFailure:$AllowFailure
}

function Get-ComposeConfig {
    param([Parameter(Mandatory = $true)][object]$Context)
    $result = Invoke-Compose -Context $Context -Arguments @('config', '--format', 'json', '--no-interpolate', '--no-env-resolution')
    $json = ($result.output -join "`n").Trim()
    try { $config = $json | ConvertFrom-Json -Depth 50 }
    catch { throw [InvalidOperationException]::new('受管 Compose 配置不是有效 JSON。') }
    $hash = Get-Sha256 -Bytes ([Text.Encoding]::UTF8.GetBytes($json))
    return [ordered]@{ config = $config; hash = $hash }
}

function Assert-ComposeSafety {
    param([Parameter(Mandatory = $true)][object]$Config, [AllowNull()][object]$Context)
    foreach ($serviceProperty in @($Config.services.PSObject.Properties)) {
        $service = $serviceProperty.Value
        if ([bool](Get-ObjectProperty $service 'privileged' $false) -or [string](Get-ObjectProperty $service 'network_mode') -eq 'host') {
            throw [InvalidOperationException]::new('受管 Compose 出现高权限容器配置，拒绝自治维护。')
        }
        foreach ($volume in @(Get-ObjectProperty $service 'volumes' @())) {
            $source = [string](Get-ObjectProperty $volume 'source')
            if ($source -match '^/(?:var/run/docker\.sock|etc|proc|sys)(?:/|$)' -or
                ($source -eq '/root' -or $source -eq '/root/') -or
                ($source -like '/root/*' -and $Context -and $source -notlike "$($Context.sourcePath)/*") -or
                ($source -like '/run/*' -and $source -ne '/run/docker-wsl-proxy.env')) {
                throw [InvalidOperationException]::new('受管 Compose 出现敏感宿主挂载，拒绝自治维护。')
            }
        }
    }
}

function Get-ManagedContainers {
    param([Parameter(Mandatory = $true)][object]$Context)
    if (@($Context.services).Count -eq 0 -and [bool]$Context.legacyServiceDiscovery) {
        $servicesResult = Invoke-Compose -Context $Context -Arguments @('config', '--services')
        $Context.services = @($servicesResult.output | Where-Object { $_ -match '^[a-zA-Z0-9][a-zA-Z0-9_.-]{0,62}$' } | Select-Object -Unique)
        if (@($Context.services).Count -eq 0) { throw [InvalidOperationException]::new('无法从旧部署 Compose 配置中发现服务白名单。') }
    }
    $result = Invoke-Wsl -Distribution $Context.distribution -Arguments @('docker', 'ps', '--filter', "label=com.docker.compose.project=$($Context.projectName)", '--format', '{{.ID}}')
    $ids = @($result.output | Where-Object { $_ -match '^[a-f0-9]{12,64}$' })
    if ($ids.Count -eq 0) { throw [InvalidOperationException]::new('未发现受管 Compose 容器，拒绝猜测项目归属。') }
    $inspect = Invoke-Wsl -Distribution $Context.distribution -Arguments (@('docker', 'inspect', '--format', '{{index .Config.Labels "com.docker.compose.project"}}|{{index .Config.Labels "com.docker.compose.service"}}|{{.State.Status}}|{{if .State.Health}}{{.State.Health.Status}}{{end}}') + $ids)
    $containers = @()
    foreach ($line in @($inspect.output)) {
        $parts = [string]$line -split '\|', 4
        if ($parts.Count -lt 4 -or $parts[0] -ne $Context.projectName -or $parts[1] -notin $Context.services) {
            throw [InvalidOperationException]::new('检测到不在维护白名单中的容器，拒绝继续。')
        }
        $containers += [ordered]@{ project = $parts[0]; service = $parts[1]; state = $parts[2]; health = $parts[3] }
    }
    return @($containers)
}

function Assert-ServiceHealthy {
    param([Parameter(Mandatory = $true)][object]$Context, [Parameter(Mandatory = $true)][string]$Service)
    if ($Service -notin $Context.services) { throw [InvalidOperationException]::new('服务不在受管维护白名单中。') }
    for ($attempt = 1; $attempt -le 30; $attempt++) {
        $result = Invoke-Compose -Context $Context -Arguments @('ps', '--format', 'json', $Service)
        try { $containers = @(($result.output -join "`n").Trim() | ConvertFrom-Json -Depth 20) }
        catch { throw [InvalidOperationException]::new('无法解析受管服务状态。') }
        if ($containers.Count -gt 0 -and @($containers | Where-Object { [string]$_.State -ne 'running' -or ([string]$_.Health -and [string]$_.Health -ne 'healthy') }).Count -eq 0) { return }
        if ($attempt -lt 30) { Start-Sleep -Seconds 2 }
    }
    throw [InvalidOperationException]::new('受管服务未在时限内恢复健康。')
}

function Get-MaintenancePath {
    param([Parameter(Mandatory = $true)][object]$Context, [Parameter(Mandatory = $true)][string]$OperationId)
    return "/root/.local/state/deploy-github-to-wsl/$($Context.slug)/maintenance/$OperationId.json"
}

function Read-MaintenanceState {
    param([Parameter(Mandatory = $true)][object]$Context, [Parameter(Mandatory = $true)][string]$OperationId)
    $path = Get-MaintenancePath -Context $Context -OperationId $OperationId
    $result = Invoke-Wsl -Distribution $Context.distribution -Arguments @('cat', '--', $path) -AllowFailure
    if ($result.exitCode -ne 0) { return $null }
    try { return (($result.output -join "`n").Trim() | ConvertFrom-Json -Depth 50) }
    catch { throw [InvalidOperationException]::new('维护状态不是有效 JSON。') }
}

function Write-MaintenanceState {
    param([Parameter(Mandatory = $true)][object]$Context, [Parameter(Mandatory = $true)][string]$OperationId, [Parameter(Mandatory = $true)][object]$State)
    $path = Get-MaintenancePath -Context $Context -OperationId $OperationId
    $json = $State | ConvertTo-Json -Depth 50
    $script = 'set -eu; umask 077; target="\$TARGET"; directory="\$(dirname "\$target")"; install -d -m 700 -- "\$directory"; temporary="\$(mktemp "\$directory/.maintenance.XXXXXX")"; trap ''rm -f -- "\$temporary"'' EXIT; cat > "\$temporary"; chmod 600 -- "\$temporary"; mv -f -- "\$temporary" "\$target"; trap - EXIT'
    $json | & wsl.exe -d $Context.distribution -- env "TARGET=$path" sh -c $script 2>$null
    if ($LASTEXITCODE -ne 0) { throw [InvalidOperationException]::new('维护状态原子写入失败。') }
}

function New-MaintenanceState {
    param([Parameter(Mandatory = $true)][object]$Context, [Parameter(Mandatory = $true)][object]$Request, [Parameter(Mandatory = $true)][string]$RequestHash)
    $now = [DateTimeOffset]::Now.ToString('o')
    return [ordered]@{
        schemaVersion = '1.0'; kind = 'deploy-github-to-wsl/maintenance-state'; operationId = [string]$Request.operationId; requestHash = $RequestHash
        project = [ordered]@{ slug = $Context.slug; composeProject = $Context.projectName; commit = $Context.commit }
        operation = [string]$Request.operation.type; status = 'running'; currentStage = 'preflight'; completedStages = @(); affected = @(); health = $null; rollback = [ordered]@{ attempted = $false; completed = $false }; lastError = $null; createdAt = $now; updatedAt = $now
    }
}

function Complete-MaintenanceStage {
    param([Parameter(Mandatory = $true)][object]$State, [Parameter(Mandatory = $true)][string]$Stage)
    $State.completedStages = @($State.completedStages) + $Stage | Select-Object -Unique
    $State.currentStage = $Stage
    $State.updatedAt = [DateTimeOffset]::Now.ToString('o')
    $State.lastError = $null
}

function Assert-ExpectedComposeHash {
    param([Parameter(Mandatory = $true)][object]$Request, [Parameter(Mandatory = $true)][object]$State, [Parameter(Mandatory = $true)][string]$ActualHash)
    $expected = [string](Get-ObjectProperty (Get-ObjectProperty $Request 'preconditions') 'composeConfigHash')
    if ($expected -notmatch '^[a-f0-9]{64}$' -or $expected -ne $ActualHash) {
        throw [InvalidOperationException]::new('Compose 配置哈希漂移或请求未绑定当前配置，拒绝维护。')
    }
}

function Get-Adapter {
    param([Parameter(Mandatory = $true)][object]$Context, [Parameter(Mandatory = $true)][string]$Name)
    $adapters = @(Get-ObjectProperty (Get-ObjectProperty $Context.state 'maintenance') 'adapters' @())
    $binding = @($adapters | Where-Object { [string](Get-ObjectProperty $_ 'name') -eq $Name })
    if ($binding.Count -ne 1) { throw [InvalidOperationException]::new('账号操作未绑定受管应用适配器。') }
    $relativePath = [string](Get-ObjectProperty $binding[0] 'descriptorPath')
    $expectedHash = [string](Get-ObjectProperty $binding[0] 'sha256')
    if ($relativePath -notmatch '^\.codex-deploy/maintenance/adapters/[A-Za-z0-9._-]+\.json$' -or $expectedHash -notmatch '^[a-f0-9]{64}$') { throw [InvalidOperationException]::new('受管应用适配器绑定无效。') }
    $absolutePath = "$($Context.sourcePath)/$relativePath"
    $descriptorHashResult = Invoke-Wsl -Distribution $Context.distribution -Arguments @('sha256sum', '--', $absolutePath)
    $actualHash = (($descriptorHashResult.output -join '') -split '\s+', 2)[0]
    if ($actualHash -ne $expectedHash) { throw [InvalidOperationException]::new('应用适配器描述文件哈希漂移，拒绝账号操作。') }
    $descriptorText = (Invoke-Wsl -Distribution $Context.distribution -Arguments @('cat', '--', $absolutePath)).output -join "`n"
    try { $descriptor = $descriptorText | ConvertFrom-Json -Depth 30 }
    catch { throw [InvalidOperationException]::new('应用适配器描述文件不是有效 JSON。') }
    $runnerPath = [string](Get-ObjectProperty $descriptor 'runnerPath')
    $runnerHash = [string](Get-ObjectProperty $descriptor 'runnerSha256')
    $runtime = [string](Get-ObjectProperty $descriptor 'runtime')
    if ([string](Get-ObjectProperty $descriptor 'schemaVersion') -ne '1.0' -or [string](Get-ObjectProperty $descriptor 'kind') -ne 'deploy-github-to-wsl/account-adapter' -or
        $runnerPath -notmatch '^\.codex-deploy/maintenance/adapters/[A-Za-z0-9._-]+\.(?:sh|py)$' -or $runnerHash -notmatch '^[a-f0-9]{64}$' -or
        $runtime -notin @('sh', 'python3')) {
        throw [InvalidOperationException]::new('应用适配器类型不受支持。')
    }
    if (($runtime -eq 'sh' -and $runnerPath -notmatch '\.sh$') -or ($runtime -eq 'python3' -and $runnerPath -notmatch '\.py$')) {
        throw [InvalidOperationException]::new('应用适配器运行时与文件扩展名不一致。')
    }
    $runnerAbsolutePath = "$($Context.sourcePath)/$runnerPath"
    $runnerHashResult = Invoke-Wsl -Distribution $Context.distribution -Arguments @('sha256sum', '--', $runnerAbsolutePath)
    $actualRunnerHash = (($runnerHashResult.output -join '') -split '\s+', 2)[0]
    if ($actualRunnerHash -ne $runnerHash) { throw [InvalidOperationException]::new('应用适配器运行器哈希漂移，拒绝账号操作。') }
    $descriptor | Add-Member -NotePropertyName resolvedRunnerPath -NotePropertyValue $runnerAbsolutePath -Force
    return $descriptor
}

function Assert-AccountRequest {
    param([Parameter(Mandatory = $true)][object]$Request, [Parameter(Mandatory = $true)][object]$Adapter)
    $account = Get-ObjectProperty $Request.operation 'account'
    $username = [string](Get-ObjectProperty $account 'username')
    if ($username -notmatch '^[A-Za-z0-9][A-Za-z0-9_.-]{0,63}$') { throw [InvalidOperationException]::new('账号名格式不正确。') }
    $type = [string]$Request.operation.type
    if ($type -in @('account.create', 'account.reset-password') -and [string](Get-ObjectProperty $account 'passwordSource') -notin @('clipboard', 'stdin')) {
        throw [InvalidOperationException]::new('密码操作只能使用 clipboard 或 stdin 安全输入。')
    }
    $allowedRoles = @((Get-ObjectProperty $Adapter 'allowedRoles' @()))
    foreach ($role in @(Get-ObjectProperty $account 'roles' @())) {
        if ([string]$role -notin $allowedRoles) { throw [InvalidOperationException]::new('账号角色不在受管适配器白名单中。') }
    }
    if ($type -eq 'account.create' -and (@(Get-ObjectProperty $account 'roles' @()).Count -eq 0 -or [string](Get-ObjectProperty $account 'displayName') -eq '')) {
        throw [InvalidOperationException]::new('创建账号必须提供显示名和至少一个角色。')
    }
}

function Read-PasswordBytes {
    param([Parameter(Mandatory = $true)][string]$Source)
    if ($Source -eq 'clipboard') {
        if (-not (Get-Command Get-Clipboard -ErrorAction SilentlyContinue)) { throw [InvalidOperationException]::new('当前 PowerShell 不支持安全读取剪贴板。') }
        $value = $null
        try {
            $value = [string](Get-Clipboard -Raw)
            $value = $value.TrimEnd([char[]]"`r`n")
            if (-not $value) { throw [InvalidOperationException]::new('剪贴板中没有可用密码。') }
            return [Text.Encoding]::UTF8.GetBytes($value)
        }
        finally {
            $value = $null
            Set-Clipboard -Value ''
        }
    }
    $input = [Console]::OpenStandardInput()
    $memory = [IO.MemoryStream]::new()
    try {
        $input.CopyTo($memory)
        $bytes = $memory.ToArray()
        if ($bytes.Length -eq 0) { throw [InvalidOperationException]::new('标准输入中没有可用密码。') }
        return $bytes
    }
    finally {
        $memory.Dispose()
    }
}

function Invoke-AdapterRunner {
    param([Parameter(Mandatory = $true)][object]$Context, [Parameter(Mandatory = $true)][object]$Request, [Parameter(Mandatory = $true)][object]$Adapter, [AllowNull()][byte[]]$StandardInput)
    $runner = [string]$Adapter.resolvedRunnerPath
    $requestJson = $Request.operation | ConvertTo-Json -Depth 20 -Compress
    $header = [Text.Encoding]::UTF8.GetBytes($requestJson + "`n")
    $passwordLength = if ($null -eq $StandardInput) { 0 } else { $StandardInput.Length }
    $payload = [byte[]]::new($header.Length + $passwordLength)
    [Array]::Copy($header, 0, $payload, 0, $header.Length)
    if ($null -ne $StandardInput) { [Array]::Copy($StandardInput, 0, $payload, $header.Length, $StandardInput.Length) }
    [Array]::Clear($header, 0, $header.Length)
    $runtime = [string]$Adapter.runtime
    $command = @($runtime, '--', $runner)
    $process = [Diagnostics.Process]::new()
    $process.StartInfo = [Diagnostics.ProcessStartInfo]::new('wsl.exe')
    foreach ($argument in @('-d', $Context.distribution, '--') + $command) { $process.StartInfo.ArgumentList.Add($argument) }
    $process.StartInfo.RedirectStandardInput = $true; $process.StartInfo.RedirectStandardOutput = $true; $process.StartInfo.RedirectStandardError = $true; $process.StartInfo.UseShellExecute = $false
    try {
        [void]$process.Start(); $process.StandardInput.BaseStream.Write($payload, 0, $payload.Length); $process.StandardInput.Close()
        $output = $process.StandardOutput.ReadToEnd(); [void]$process.StandardError.ReadToEnd(); $process.WaitForExit()
        if ($process.ExitCode -ne 0) { throw [InvalidOperationException]::new('受管账号适配器执行失败；详细输出未写入维护记录。') }
        return [ordered]@{ exitCode = 0; output = @($output) }
    }
    finally { [Array]::Clear($payload, 0, $payload.Length) }
}

function Invoke-AccountOperation {
    param([Parameter(Mandatory = $true)][object]$Context, [Parameter(Mandatory = $true)][object]$Request, [Parameter(Mandatory = $true)][object]$Adapter)
    Assert-AccountRequest -Request $Request -Adapter $Adapter
    $account = $Request.operation.account
    $type = [string]$Request.operation.type
    $username = [string]$account.username
    $passwordBytes = $null
    try {
        if ($type -in @('account.create', 'account.reset-password')) { $passwordBytes = Read-PasswordBytes -Source ([string]$account.passwordSource) }
        # 运行器受首次部署的哈希绑定，核心只传递受验证的结构化操作和受控密码标准输入。
        $result = Invoke-AdapterRunner -Context $Context -Request $Request -Adapter $Adapter -StandardInput $passwordBytes
        $safeOutput = @($result.output | Where-Object { $_ -match '^\{"schemaVersion":"1\.0","ok":true,"username":"[A-Za-z0-9_.-]+"' })
        if ($safeOutput.Count -ne 1) { throw [InvalidOperationException]::new('账号操作后核验失败，未自动回滚用户数据。') }
        return [ordered]@{ affected = @([ordered]@{ kind = 'account'; username = $username; operation = $type }); verification = 'adapter-confirmed' }
    }
    finally {
        if ($null -ne $passwordBytes) { [Array]::Clear($passwordBytes, 0, $passwordBytes.Length) }
    }
}

function Invoke-CloudflareMaintenance {
    param([Parameter(Mandatory = $true)][object]$Context)
    $cloudflare = Get-ObjectProperty $Context.state 'cloudflare'
    $objects = Get-ObjectProperty $Context.state 'objects'
    if (-not $cloudflare -or -not [string](Get-ObjectProperty $objects 'tunnelId') -or -not [string](Get-ObjectProperty $objects 'dnsRecordId')) {
        throw [InvalidOperationException]::new('部署状态没有足够的 Cloudflare 所有权证据，拒绝同步。')
    }
    if ([string](Get-ObjectProperty $cloudflare 'accessMode') -ne 'anonymous') { throw [InvalidOperationException]::new('Access 配置变更必须单独确认。') }
    $manifest = [ordered]@{
        schemaVersion = '2.0'; kind = 'deploy-github-to-wsl/manifest'
        repository = [ordered]@{ slug = $Context.slug; sourcePath = $Context.sourcePath; canonicalUrl = $Context.state.repository.url; ref = $Context.state.repository.ref; commit = $Context.commit }
        wsl = [ordered]@{ distribution = $Context.distribution }
        compose = [ordered]@{ projectName = $Context.projectName; files = @($Context.composePath); profiles = @($Context.profiles); appService = ''; tunnelService = ''; internalPort = 1 }
        cloudflare = $cloudflare; state = [ordered]@{ path = $Context.statePath }; riskConfirmations = @(); approval = [ordered]@{ scope = @('wslWrite', 'containers', 'cloudflareTunnel', 'cloudflareRoute') }; deploymentFiles = @()
    }
    $temporaryPath = Join-Path ([IO.Path]::GetTempPath()) ('deploy-github-to-wsl-maintenance-' + [Guid]::NewGuid().ToString('N') + '.json')
    try {
        [IO.File]::WriteAllText($temporaryPath, ($manifest | ConvertTo-Json -Depth 30), [Text.UTF8Encoding]::new($false))
        $parameters = @{ Action = 'Maintain'; ManifestPath = $temporaryPath; ApiBaseUri = $ApiBaseUri; Compact = $true }
        if ($CredentialPath) { $parameters.CredentialPath = $CredentialPath }
        if ($AllowInsecureLoopbackForTest) { $parameters.AllowInsecureLoopbackForTest = $true }
        $text = & $script:CloudflareScript @parameters
        if ($LASTEXITCODE -ne 0) { throw [InvalidOperationException]::new('受管 Cloudflare 同步失败。') }
        $result = ($text -join "`n") | ConvertFrom-Json -Depth 40
        if (Get-ObjectProperty $result 'error') { throw [InvalidOperationException]::new('受管 Cloudflare 同步被阻断。') }
        return $result
    }
    finally { if ([IO.File]::Exists($temporaryPath)) { Remove-Item -LiteralPath $temporaryPath -Force } }
}

function Invoke-OverlayOperation {
    param([Parameter(Mandatory = $true)][object]$Context, [Parameter(Mandatory = $true)][object]$Request)
    $files = @(Get-ObjectProperty $Request.operation 'files' @())
    if ($files.Count -eq 0) { throw [InvalidOperationException]::new('覆盖维护请求未提供文件。') }
    $backupDirectory = "$($Context.sourcePath)/.codex-deploy/.maintenance-backups/$($Request.operationId)"
    $written = [Collections.Generic.List[string]]::new()
    try {
        foreach ($file in $files) {
            $path = [string](Get-ObjectProperty $file 'path')
            $content = [string](Get-ObjectProperty $file 'contentBase64')
            $expectedHash = [string](Get-ObjectProperty $file 'sha256')
            if ($path -notmatch '^\.codex-deploy/(?!\.maintenance-backups/)(?:[A-Za-z0-9._-]+/)*[A-Za-z0-9._-]+$' -or $expectedHash -notmatch '^[a-f0-9]{64}$') { throw [InvalidOperationException]::new('覆盖文件路径或哈希无效。') }
            $bytes = [Convert]::FromBase64String($content)
            try { if ((Get-Sha256 -Bytes $bytes) -ne $expectedHash) { throw [InvalidOperationException]::new('覆盖文件内容哈希不匹配。') } }
            finally { $bytes = $null }
            $target = "$($Context.sourcePath)/$path"
            $writeScript = 'set -eu; target="\$TARGET"; backup_root="\$BACKUP"; relative="\$RELATIVE"; directory="\$(dirname "\$target")"; install -d -m 755 -- "\$directory" "\$backup_root/\$(dirname "\$relative")"; if [ -e "\$target" ]; then cp -p -- "\$target" "\$backup_root/\$relative"; else : > "\$backup_root/\$relative.absent"; fi; temporary="\$(mktemp "\$directory/.maintenance-overlay.XXXXXX")"; trap ''rm -f -- "\$temporary"'' EXIT; cat > "\$temporary"; chmod 644 -- "\$temporary"; mv -f -- "\$temporary" "\$target"; trap - EXIT'
            $raw = [Convert]::FromBase64String($content)
            $process = [Diagnostics.Process]::new(); $process.StartInfo = [Diagnostics.ProcessStartInfo]::new('wsl.exe')
            foreach ($argument in @('-d', $Context.distribution, '--', 'env', "TARGET=$target", "BACKUP=$backupDirectory", "RELATIVE=$path", 'sh', '-c', $writeScript)) { $process.StartInfo.ArgumentList.Add($argument) }
            $process.StartInfo.RedirectStandardInput = $true; $process.StartInfo.RedirectStandardOutput = $true; $process.StartInfo.RedirectStandardError = $true; $process.StartInfo.UseShellExecute = $false; [void]$process.Start(); $process.StandardInput.BaseStream.Write($raw, 0, $raw.Length); $process.StandardInput.Close(); [void]$process.StandardOutput.ReadToEnd(); [void]$process.StandardError.ReadToEnd(); $process.WaitForExit(); [Array]::Clear($raw, 0, $raw.Length)
            if ($process.ExitCode -ne 0) { throw [InvalidOperationException]::new('受管覆盖文件写入失败。') }
            $written.Add($path)
        }
        return [ordered]@{ backupDirectory = $backupDirectory; files = @($written) }
    }
    catch { throw }
}

function Restore-Overlay {
    param([Parameter(Mandatory = $true)][object]$Context, [Parameter(Mandatory = $true)][string]$BackupDirectory, [Parameter(Mandatory = $true)][string[]]$Files)
    foreach ($path in $Files) {
        $target = "$($Context.sourcePath)/$path"; $backup = "$BackupDirectory/$path"; $absent = "$backup.absent"
        $script = 'set -eu; if [ -f "\$BACKUP" ]; then install -d -m 755 -- "\$(dirname "\$TARGET")"; cp -p -- "\$BACKUP" "\$TARGET"; elif [ -f "\$ABSENT" ]; then rm -f -- "\$TARGET"; else exit 20; fi'
        [void](Invoke-Wsl -Distribution $Context.distribution -Arguments @('env', "TARGET=$target", "BACKUP=$backup", "ABSENT=$absent", 'sh', '-c', $script))
    }
}

function Invoke-Maintenance {
    param([Parameter(Mandatory = $true)][object]$Context, [Parameter(Mandatory = $true)][object]$Request, [Parameter(Mandatory = $true)][object]$State, [Parameter(Mandatory = $true)][object]$OperationState)
    $type = [string]$Request.operation.type
    $compose = Get-ComposeConfig -Context $Context
    Assert-ComposeSafety -Config $compose.config -Context $Context
    $containers = Get-ManagedContainers -Context $Context
    Complete-MaintenanceStage -State $OperationState -Stage 'preflight'; $OperationState.affected = @($containers | ForEach-Object { [ordered]@{ kind = 'service'; name = $_.service } }); Write-MaintenanceState -Context $Context -OperationId $Request.operationId -State $OperationState
    if ($type -eq 'inspect') {
        $OperationState.health = [ordered]@{ composeConfigHash = $compose.hash; containers = $containers; public = $null }; $OperationState.status = 'complete'; Complete-MaintenanceStage -State $OperationState -Stage 'verified'; Write-MaintenanceState -Context $Context -OperationId $Request.operationId -State $OperationState; return $OperationState
    }
    if (-not [bool]$Context.maintenanceBaseline) {
        throw [InvalidOperationException]::new('当前部署只有兼容只读状态，写入型维护需要先通过批准的升级建立维护基线。')
    }
    if ($type -notlike 'account.*') { Assert-ExpectedComposeHash -Request $Request -State $State -ActualHash $compose.hash }
    if ($type -in @('service.restart', 'service.rebuild')) {
        $service = [string](Get-ObjectProperty $Request.operation 'service')
        if ($service -notin $Context.services) { throw [InvalidOperationException]::new('目标服务不在维护白名单中。') }
        if ($service -match '(?i)(?:^|[-_.])(?:migrate|migration|seed)(?:$|[-_.])') { throw [InvalidOperationException]::new('迁移或初始化服务不属于自治维护范围。') }
        if ('applied' -notin @($OperationState.completedStages)) {
            $arguments = if ($type -eq 'service.restart') { @('restart', $service) } else { @('up', '-d', '--build', '--no-deps', $service) }
            [void](Invoke-Compose -Context $Context -Arguments $arguments); Complete-MaintenanceStage -State $OperationState -Stage 'applied'; $OperationState.affected = @([ordered]@{ kind = 'service'; name = $service; operation = $type }); Write-MaintenanceState -Context $Context -OperationId $Request.operationId -State $OperationState
        }
        Assert-ServiceHealthy -Context $Context -Service $service
    }
    elseif ($type -eq 'overlay.apply') {
        $overlay = [ordered]@{ backupDirectory = "$($Context.sourcePath)/.codex-deploy/.maintenance-backups/$($Request.operationId)"; files = @((Get-ObjectProperty $Request.operation 'files' @()) | ForEach-Object { [string](Get-ObjectProperty $_ 'path') }) }
        if ('applied' -notin @($OperationState.completedStages)) {
            $overlay = Invoke-OverlayOperation -Context $Context -Request $Request; Complete-MaintenanceStage -State $OperationState -Stage 'applied'; $OperationState.affected = @($overlay.files | ForEach-Object { [ordered]@{ kind = 'overlay'; path = $_ } }); Write-MaintenanceState -Context $Context -OperationId $Request.operationId -State $OperationState
        }
        try {
            $service = [string](Get-ObjectProperty $Request.operation 'service')
            if ($service -notin $Context.services) { throw [InvalidOperationException]::new('覆盖操作目标服务不在白名单中。') }
            if ($service -match '(?i)(?:^|[-_.])(?:migrate|migration|seed)(?:$|[-_.])') { throw [InvalidOperationException]::new('迁移或初始化服务不属于自治维护范围。') }
            [void](Invoke-Compose -Context $Context -Arguments @('up', '-d', '--build', '--no-deps', $service)); Assert-ServiceHealthy -Context $Context -Service $service
        }
        catch {
            $OperationState.rollback.attempted = $true; Restore-Overlay -Context $Context -BackupDirectory $overlay.backupDirectory -Files @($overlay.files); $service = [string](Get-ObjectProperty $Request.operation 'service'); [void](Invoke-Compose -Context $Context -Arguments @('up', '-d', '--build', '--no-deps', $service)); $OperationState.rollback.completed = $true; throw
        }
    }
    elseif ($type -eq 'cloudflare.sync') {
        if ('applied' -notin @($OperationState.completedStages)) {
            $result = Invoke-CloudflareMaintenance -Context $Context; Complete-MaintenanceStage -State $OperationState -Stage 'applied'; $OperationState.affected = @($result.updated); Write-MaintenanceState -Context $Context -OperationId $Request.operationId -State $OperationState
        }
    }
    else {
        if ('applied' -notin @($OperationState.completedStages)) {
            $adapter = Get-Adapter -Context $Context -Name ([string]$Request.operation.adapter); $result = Invoke-AccountOperation -Context $Context -Request $Request -Adapter $adapter; Complete-MaintenanceStage -State $OperationState -Stage 'applied'; $OperationState.affected = @($result.affected); Write-MaintenanceState -Context $Context -OperationId $Request.operationId -State $OperationState
        }
    }
    $OperationState.health = [ordered]@{ composeConfigHash = (Get-ComposeConfig -Context $Context).hash; containers = Get-ManagedContainers -Context $Context }; $OperationState.status = 'complete'; Complete-MaintenanceStage -State $OperationState -Stage 'verified'; Write-MaintenanceState -Context $Context -OperationId $Request.operationId -State $OperationState; return $OperationState
}

try {
    $request = Read-JsonFile -Path $RequestPath -Description '维护请求'; Assert-Request -Request $request
    $distribution = [string](Get-ObjectProperty (Get-ObjectProperty $request 'project') 'distribution' 'Ubuntu')
    $deploymentState = Get-DeploymentState -Distribution $distribution -Slug ([string]$request.project.slug)
    $context = Get-ProjectContext -Request $request -State $deploymentState
    $requestHash = Get-RequestHash -Request $request
    $existing = Read-MaintenanceState -Context $context -OperationId ([string]$request.operationId)
    if ($Mode -eq 'Inspect') {
        $config = Get-ComposeConfig -Context $context; Assert-ComposeSafety -Config $config.config -Context $context
        Write-JsonResult ([ordered]@{ schemaVersion = '1.0'; mode = 'Inspect'; requestHash = $requestHash; managed = $true; project = [ordered]@{ slug = $context.slug; composeProject = $context.projectName; commit = $context.commit }; composeConfigHash = $config.hash; stateComposeHash = [string](Get-ObjectProperty (Get-ObjectProperty $deploymentState 'hashes') 'composeConfig'); containers = Get-ManagedContainers -Context $context; existingOperation = $existing; blockers = @() })
        $global:LASTEXITCODE = 0; return
    }
    if (-not [bool]$context.maintenanceBaseline) {
        throw [InvalidOperationException]::new('当前部署只有兼容只读状态，写入型维护需要先通过批准的升级建立维护基线。')
    }
    if ($Mode -eq 'Apply') {
        if ($existing) { throw [InvalidOperationException]::new('维护操作 ID 已存在；请使用 Resume，不能覆盖历史记录。') }
        $operationState = New-MaintenanceState -Context $context -Request $request -RequestHash $requestHash
        Write-MaintenanceState -Context $context -OperationId ([string]$request.operationId) -State $operationState
    }
    else {
        if (-not $existing -or [string](Get-ObjectProperty $existing 'requestHash') -ne $requestHash) { throw [InvalidOperationException]::new('Resume 找不到匹配的维护状态。') }
        if ([string](Get-ObjectProperty $existing 'status') -eq 'complete') { Write-JsonResult $existing; $global:LASTEXITCODE = 0; return }
        $operationState = $existing
    }
    try { Write-JsonResult (Invoke-Maintenance -Context $context -Request $request -State $deploymentState -OperationState $operationState) }
    catch { $operationState.status = 'failed'; $operationState.lastError = [ordered]@{ code = 'maintenance_failed'; stage = $operationState.currentStage }; $operationState.updatedAt = [DateTimeOffset]::Now.ToString('o'); Write-MaintenanceState -Context $context -OperationId ([string]$request.operationId) -State $operationState; throw }
}
catch {
    $message = if ($_.Exception.Message -match '(?i)(token|secret|password|authorization|sql)\s*[:=]') { '维护操作失败，异常内容已脱敏。' } else { $_.Exception.Message }
    Write-JsonResult ([ordered]@{ schemaVersion = '1.0'; mode = $Mode; error = [ordered]@{ code = 'maintenance_operation_failed'; message = $message } })
    $global:LASTEXITCODE = 2
    return
}

$global:LASTEXITCODE = 0
