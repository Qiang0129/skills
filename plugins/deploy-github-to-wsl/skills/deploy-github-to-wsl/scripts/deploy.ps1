[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [ValidateSet('Plan', 'Apply', 'Resume')]
    [string]$Mode,

    [Parameter(Mandatory = $true)]
    [string]$ManifestPath,

    [string]$ApprovedPlanHash,

    [string[]]$ConfirmRisk = @(),

    [string]$CredentialPath,

    [string]$AccessCredentialPath,

    [uri]$ApiBaseUri = 'https://api.cloudflare.com/client/v4',

    [switch]$AllowInsecureLoopbackForTest,

    [switch]$Compact
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
[Console]::OutputEncoding = [Text.UTF8Encoding]::new($false)
$OutputEncoding = [Text.UTF8Encoding]::new($false)

$script:Stages = @('preflight', 'source', 'build', 'app', 'tunnel', 'route', 'acceptance', 'recorded')
$script:InspectScript = Join-Path $PSScriptRoot 'inspect_wsl.ps1'
$script:ScannerScript = Join-Path $PSScriptRoot 'scan_repository.py'
$script:CloudflareScript = Join-Path $PSScriptRoot 'cloudflare.ps1'

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

function Read-Manifest {
    param([Parameter(Mandatory = $true)][string]$LiteralPath)

    $fullPath = [IO.Path]::GetFullPath($LiteralPath)
    if (-not [IO.File]::Exists($fullPath)) {
        throw [IO.FileNotFoundException]::new("找不到部署清单：$fullPath")
    }
    try {
        return [IO.File]::ReadAllText($fullPath, [Text.UTF8Encoding]::new($false)) | ConvertFrom-Json -Depth 50
    }
    catch {
        throw [InvalidOperationException]::new('部署清单不是有效的 UTF-8 JSON。')
    }
}

function ConvertTo-CanonicalObject {
    param([AllowNull()][object]$InputObject)

    if ($null -eq $InputObject) {
        return $null
    }
    if ($InputObject -is [string] -or $InputObject.GetType().IsPrimitive) {
        return $InputObject
    }
    if ($InputObject -is [Collections.IDictionary]) {
        $ordered = [ordered]@{}
        foreach ($key in @($InputObject.Keys | Sort-Object)) {
            $ordered[[string]$key] = ConvertTo-CanonicalObject $InputObject[$key]
        }
        return $ordered
    }
    if ($InputObject -is [Collections.IEnumerable]) {
        return @($InputObject | ForEach-Object { ConvertTo-CanonicalObject $_ })
    }

    $properties = @($InputObject.PSObject.Properties | Sort-Object Name)
    $orderedObject = [ordered]@{}
    foreach ($property in $properties) {
        $orderedObject[$property.Name] = ConvertTo-CanonicalObject $property.Value
    }
    return $orderedObject
}

function Get-PlanHash {
    param([Parameter(Mandatory = $true)][object]$Manifest)

    $clone = ($Manifest | ConvertTo-Json -Depth 50 -Compress) | ConvertFrom-Json -Depth 50
    $approval = Get-ObjectProperty $clone 'approval'
    if ($approval -and $approval.PSObject.Properties['planHash']) {
        $approval.planHash = $null
    }
    $canonical = ConvertTo-CanonicalObject $clone | ConvertTo-Json -Depth 50 -Compress
    $bytes = [Text.Encoding]::UTF8.GetBytes($canonical)
    try {
        return ([Convert]::ToHexString([Security.Cryptography.SHA256]::HashData($bytes))).ToLowerInvariant()
    }
    finally {
        [Array]::Clear($bytes, 0, $bytes.Length)
    }
}

function Assert-DeploymentManifest {
    param([Parameter(Mandatory = $true)][object]$Manifest)

    if ([string](Get-ObjectProperty $Manifest 'schemaVersion') -ne '2.0') {
        throw [InvalidOperationException]::new('部署清单 schemaVersion 必须为 2.0。')
    }
    if ([string](Get-ObjectProperty $Manifest 'kind') -ne 'deploy-github-to-wsl/manifest') {
        throw [InvalidOperationException]::new('部署清单 kind 不正确。')
    }

    $repository = Get-ObjectProperty $Manifest 'repository'
    $wsl = Get-ObjectProperty $Manifest 'wsl'
    $compose = Get-ObjectProperty $Manifest 'compose'
    $cloudflare = Get-ObjectProperty $Manifest 'cloudflare'
    $state = Get-ObjectProperty $Manifest 'state'
    $approval = Get-ObjectProperty $Manifest 'approval'
    $maintenance = Get-ObjectProperty $Manifest 'maintenance'

    $url = [string](Get-ObjectProperty $repository 'canonicalUrl')
    $slug = [string](Get-ObjectProperty $repository 'slug')
    $commit = [string](Get-ObjectProperty $repository 'commit')
    $sourcePath = [string](Get-ObjectProperty $repository 'sourcePath')
    if ($url -notmatch '^https://github\.com/[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$') {
        throw [InvalidOperationException]::new('仓库 URL 必须是规范化的 github.com HTTPS 地址。')
    }
    if ($slug -notmatch '^[a-z0-9][a-z0-9-]{0,62}$' -or $commit -notmatch '^[a-f0-9]{40}$') {
        throw [InvalidOperationException]::new('仓库 slug 或固定提交 SHA 格式不正确。')
    }
    if ($sourcePath -ne "/root/projects/$slug") {
        throw [InvalidOperationException]::new('源码路径必须是 /root/projects/<slug>。')
    }

    $distribution = [string](Get-ObjectProperty $wsl 'distribution')
    if ($distribution -notmatch '^[A-Za-z0-9][A-Za-z0-9._ -]{0,127}$') {
        throw [InvalidOperationException]::new('WSL 发行版注册名格式不正确。')
    }
    $projectName = [string](Get-ObjectProperty $compose 'projectName')
    if ($projectName -ne "codex-$slug") {
        throw [InvalidOperationException]::new('Compose 项目名必须是 codex-<slug>。')
    }

    $files = @(Get-ObjectProperty $compose 'files' @())
    if ($files.Count -lt 1) {
        throw [InvalidOperationException]::new('部署清单至少需要一个 Compose 文件。')
    }
    foreach ($file in $files) {
        if ([string]$file -notmatch ('^' + [regex]::Escape($sourcePath) + '/(?:[A-Za-z0-9._-]+/)*[A-Za-z0-9._-]+$')) {
            throw [InvalidOperationException]::new('Compose 文件必须位于批准的源码目录内。')
        }
    }
    foreach ($profile in @(Get-ObjectProperty $compose 'profiles' @())) {
        if ([string]$profile -notmatch '^[A-Za-z0-9][A-Za-z0-9_.-]{0,62}$') {
            throw [InvalidOperationException]::new('Compose profile 名称格式不正确。')
        }
    }
    foreach ($serviceName in @([string](Get-ObjectProperty $compose 'appService'), [string](Get-ObjectProperty $compose 'tunnelService'))) {
        if ($serviceName -notmatch '^[a-zA-Z0-9][a-zA-Z0-9_.-]{0,62}$') {
            throw [InvalidOperationException]::new('Compose 服务名格式不正确。')
        }
    }

    # 维护适配器必须随首次部署清单固定，后续维护不能凭名称猜测应用数据结构。
    $declaredAdapterPaths = @{}
    foreach ($adapter in @(Get-ObjectProperty $maintenance 'adapters' @())) {
        $name = [string](Get-ObjectProperty $adapter 'name')
        $descriptorPath = [string](Get-ObjectProperty $adapter 'descriptorPath')
        $descriptorHash = [string](Get-ObjectProperty $adapter 'sha256')
        if ($name -notmatch '^[a-z0-9][a-z0-9-]{0,62}$') {
            throw [InvalidOperationException]::new('维护适配器名称格式不正确。')
        }
        if ($descriptorPath -notmatch '^\.codex-deploy/maintenance/adapters/[A-Za-z0-9._-]+\.json$') {
            throw [InvalidOperationException]::new('维护适配器描述文件必须位于 .codex-deploy/maintenance/adapters。')
        }
        if ($descriptorHash -notmatch '^[a-f0-9]{64}$') {
            throw [InvalidOperationException]::new('维护适配器描述文件哈希格式不正确。')
        }
        if ($declaredAdapterPaths.ContainsKey($name)) {
            throw [InvalidOperationException]::new('维护适配器名称不得重复。')
        }
        $declaredAdapterPaths[$name] = [ordered]@{ path = $descriptorPath; sha256 = $descriptorHash }
    }

    if ($declaredAdapterPaths.Count -gt 0) {
        $deploymentFileHashes = @{}
        foreach ($file in @(Get-ObjectProperty $Manifest 'deploymentFiles' @())) {
            $deploymentFileHashes[[string](Get-ObjectProperty $file 'path')] = [string](Get-ObjectProperty $file 'sha256')
        }
        foreach ($adapter in $declaredAdapterPaths.Values) {
            if ($deploymentFileHashes[$adapter.path] -ne $adapter.sha256) {
                throw [InvalidOperationException]::new('维护适配器必须作为同哈希的部署覆盖文件写入。')
            }
            $descriptorFile = @(
                @(Get-ObjectProperty $Manifest 'deploymentFiles' @()) |
                    Where-Object { [string](Get-ObjectProperty $_ 'path') -eq $adapter.path }
            )
            if ($descriptorFile.Count -ne 1) {
                throw [InvalidOperationException]::new('维护适配器描述文件必须唯一。')
            }
            $descriptorBytes = $null
            try {
                $descriptorBytes = [Convert]::FromBase64String([string](Get-ObjectProperty $descriptorFile[0] 'contentBase64'))
                $descriptor = ([Text.Encoding]::UTF8.GetString($descriptorBytes) | ConvertFrom-Json -Depth 20)
            }
            catch {
                throw [InvalidOperationException]::new('维护适配器描述文件必须是有效 UTF-8 JSON。')
            }
            finally {
                if ($null -ne $descriptorBytes) { [Array]::Clear($descriptorBytes, 0, $descriptorBytes.Length) }
            }
            $runnerPath = [string](Get-ObjectProperty $descriptor 'runnerPath')
            $runnerHash = [string](Get-ObjectProperty $descriptor 'runnerSha256')
            $runtime = [string](Get-ObjectProperty $descriptor 'runtime')
            if ([string](Get-ObjectProperty $descriptor 'schemaVersion') -ne '1.0' -or
                [string](Get-ObjectProperty $descriptor 'kind') -ne 'deploy-github-to-wsl/account-adapter' -or
                $runnerPath -notmatch '^\.codex-deploy/maintenance/adapters/[A-Za-z0-9._-]+\.(?:sh|py)$' -or
                $runnerHash -notmatch '^[a-f0-9]{64}$' -or $runtime -notin @('sh', 'python3') -or
                ($runtime -eq 'sh' -and $runnerPath -notmatch '\.sh$') -or
                ($runtime -eq 'python3' -and $runnerPath -notmatch '\.py$')) {
                throw [InvalidOperationException]::new('维护适配器描述文件不符合运行器协议。')
            }
            if ($deploymentFileHashes[$runnerPath] -ne $runnerHash) {
                throw [InvalidOperationException]::new('维护适配器运行器必须作为同哈希的部署覆盖文件写入。')
            }
        }
    }

    foreach ($serviceName in @(Get-ObjectProperty $maintenance 'services' @())) {
        if ([string]$serviceName -notmatch '^[a-zA-Z0-9][a-zA-Z0-9_.-]{0,62}$') {
            throw [InvalidOperationException]::new('维护服务白名单包含无效名称。')
        }
    }

    $statePath = [string](Get-ObjectProperty $state 'path')
    if ($statePath -ne "/root/.local/state/deploy-github-to-wsl/$slug/deployment.json") {
        throw [InvalidOperationException]::new('状态路径必须使用项目固定的 root-only 目录。')
    }

    $scope = @(Get-ObjectProperty $approval 'scope' @())
    $requiredScope = @('wslWrite', 'containers', 'cloudflareTunnel', 'cloudflareRoute')
    foreach ($item in $requiredScope) {
        if ($item -notin $scope) {
            throw [InvalidOperationException]::new("批准范围缺少必需项：$item")
        }
    }

    $serialized = $Manifest | ConvertTo-Json -Depth 50 -Compress
    if ($serialized -match '(?i)"(?:token|password|secret|privateKey)"\s*:') {
        throw [InvalidOperationException]::new('部署清单不得包含密钥字段。')
    }
    if ([string](Get-ObjectProperty $cloudflare 'accessMode' 'anonymous') -notin @('anonymous', 'access')) {
        throw [InvalidOperationException]::new('accessMode 只能是 anonymous 或 access。')
    }

    $acceptance = Get-ObjectProperty $Manifest 'acceptance'
    $acceptanceUrl = [string](Get-ObjectProperty $acceptance 'url')
    if ($acceptanceUrl) {
        $parsedAcceptanceUri = $null
        if (-not [uri]::TryCreate($acceptanceUrl, [UriKind]::Absolute, [ref]$parsedAcceptanceUri) -or
            -not $AllowInsecureLoopbackForTest -or
            -not $parsedAcceptanceUri.IsLoopback -or
            $parsedAcceptanceUri.Scheme -notin @('http', 'https')) {
            throw [InvalidOperationException]::new('自定义验收 URL 仅允许在显式测试模式下使用回环 HTTP(S) 地址。')
        }
    }
}

function Get-ComposeArguments {
    param([Parameter(Mandatory = $true)][object]$Manifest)

    $arguments = [Collections.Generic.List[string]]::new()
    $arguments.Add('compose')
    $arguments.Add('-p')
    $arguments.Add([string]$Manifest.compose.projectName)
    foreach ($file in @($Manifest.compose.files)) {
        $arguments.Add('-f')
        $arguments.Add([string]$file)
    }
    foreach ($profile in @(Get-ObjectProperty $Manifest.compose 'profiles' @())) {
        $arguments.Add('--profile')
        $arguments.Add([string]$profile)
    }
    return @($arguments)
}

function Invoke-WslCommand {
    param(
        [Parameter(Mandatory = $true)][string]$Distribution,
        [Parameter(Mandatory = $true)][string[]]$Arguments,
        [switch]$AllowFailure
    )

    $output = @(& wsl.exe -d $Distribution -- @Arguments 2>&1)
    $exitCode = $LASTEXITCODE
    if ($exitCode -ne 0 -and -not $AllowFailure) {
        throw [InvalidOperationException]::new('WSL 命令执行失败；详细输出未写入部署记录。')
    }
    return [ordered]@{ exitCode = $exitCode; output = @($output | ForEach-Object { [string]$_ }) }
}

function Get-RemoteCommit {
    param([Parameter(Mandatory = $true)][object]$Manifest)

    $ref = [string]$Manifest.repository.ref
    if ($ref -notmatch '^[A-Za-z0-9][A-Za-z0-9._/-]{0,200}$' -or $ref -match '\.\.') {
        throw [InvalidOperationException]::new('仓库 ref 格式不安全。')
    }
    $query = Invoke-WslCommand -Distribution $Manifest.wsl.distribution -Arguments @('git', 'ls-remote', '--refs', $Manifest.repository.canonicalUrl, $ref)
    $line = @($query.output | Where-Object { $_ -match '^[a-f0-9]{40}\s' } | Select-Object -First 1)
    if ($line.Count -ne 1) {
        throw [InvalidOperationException]::new('无法将批准的仓库 ref 解析为唯一提交。')
    }
    return ($line[0] -split '\s+', 2)[0]
}

function Get-WslState {
    param([Parameter(Mandatory = $true)][object]$Manifest)

    $result = Invoke-WslCommand -Distribution $Manifest.wsl.distribution -Arguments @('cat', '--', [string]$Manifest.state.path) -AllowFailure
    if ($result.exitCode -ne 0) {
        return $null
    }
    $json = ($result.output -join "`n").Trim()
    if (-not $json) {
        return $null
    }
    try {
        return $json | ConvertFrom-Json -Depth 50
    }
    catch {
        throw [InvalidOperationException]::new('已有部署状态不是有效 JSON。')
    }
}

function Write-WslState {
    param(
        [Parameter(Mandatory = $true)][object]$Manifest,
        [Parameter(Mandatory = $true)][object]$State
    )

    $json = $State | ConvertTo-Json -Depth 50
    $writeScript = 'set -eu; umask 077; state_path="\$STATE_PATH"; state_dir="\$(dirname "\$state_path")"; install -d -m 700 -- "\$state_dir"; temporary="\$(mktemp "\$state_dir/.deployment.XXXXXX")"; trap ''rm -f -- "\$temporary"'' EXIT; cat > "\$temporary"; chmod 600 -- "\$temporary"; mv -f -- "\$temporary" "\$state_path"; trap - EXIT'
    $json | & wsl.exe -d $Manifest.wsl.distribution -- env "STATE_PATH=$($Manifest.state.path)" sh -c $writeScript 2>$null
    if ($LASTEXITCODE -ne 0) {
        throw [InvalidOperationException]::new('部署状态原子写入失败。')
    }
    $permission = (Invoke-WslCommand -Distribution $Manifest.wsl.distribution -Arguments @('stat', '-c', '%a', '--', [string]$Manifest.state.path)).output[0].Trim()
    if ($permission -ne '600') {
        throw [InvalidOperationException]::new('部署状态文件权限不是 600。')
    }
}

function New-DeploymentState {
    param(
        [Parameter(Mandatory = $true)][object]$Manifest,
        [Parameter(Mandatory = $true)][string]$PlanHash
    )

    $now = [DateTimeOffset]::Now.ToString('o')
    return [ordered]@{
        schemaVersion = '2.0'
        planHash = $PlanHash
        project = [ordered]@{ slug = $Manifest.repository.slug; composeProject = $Manifest.compose.projectName }
        repository = [ordered]@{
            url = $Manifest.repository.canonicalUrl
            ref = $Manifest.repository.ref
            commit = $Manifest.repository.commit
            sourcePath = $Manifest.repository.sourcePath
        }
        compose = [ordered]@{
            projectName = $Manifest.compose.projectName
            files = @($Manifest.compose.files)
            profiles = @($Manifest.compose.profiles)
            appService = $Manifest.compose.appService
            tunnelService = $Manifest.compose.tunnelService
        }
        currentStage = 'preflight'
        completedStages = @()
        objects = [ordered]@{ tunnelId = $null; dnsRecordId = $null; accessApplicationId = $null; accessPolicyId = $null }
        cloudflare = [ordered]@{
            accountId = $Manifest.cloudflare.accountId
            zoneId = $Manifest.cloudflare.zoneId
            zoneName = $Manifest.cloudflare.zoneName
            hostname = $Manifest.cloudflare.hostname
            tunnelName = $Manifest.cloudflare.tunnelName
            service = $Manifest.cloudflare.service
            accessMode = (Get-ObjectProperty $Manifest.cloudflare 'accessMode' 'anonymous')
            credentialProfile = (Get-ObjectProperty $Manifest.cloudflare 'credentialProfile' 'public')
        }
        maintenance = [ordered]@{
            schemaVersion = '1.0'
            services = @(
                @(
                    @(Get-ObjectProperty (Get-ObjectProperty $Manifest 'maintenance') 'services' @()) +
                    @([string]$Manifest.compose.appService, [string]$Manifest.compose.tunnelService)
                ) | Select-Object -Unique
            )
            adapters = @(
                @(Get-ObjectProperty (Get-ObjectProperty $Manifest 'maintenance') 'adapters' @()) |
                    ForEach-Object {
                        [ordered]@{
                            name = [string](Get-ObjectProperty $_ 'name')
                            descriptorPath = [string](Get-ObjectProperty $_ 'descriptorPath')
                            sha256 = [string](Get-ObjectProperty $_ 'sha256')
                        }
                    }
            )
        }
        hashes = [ordered]@{ composeConfig = $null; cloudflareConfig = $null }
        acceptance = $null
        lastError = $null
        createdAt = $now
        updatedAt = $now
    }
}

function Complete-Stage {
    param(
        [Parameter(Mandatory = $true)][object]$State,
        [Parameter(Mandatory = $true)][string]$Stage
    )

    $State.completedStages = @($State.completedStages) + $Stage | Select-Object -Unique
    $index = [Array]::IndexOf($script:Stages, $Stage)
    $State.currentStage = if ($index -lt $script:Stages.Count - 1) { $script:Stages[$index + 1] } else { 'complete' }
    $State.updatedAt = [DateTimeOffset]::Now.ToString('o')
    $State.lastError = $null
}

function Get-WslPathForWindowsFile {
    param(
        [Parameter(Mandatory = $true)][string]$Distribution,
        [Parameter(Mandatory = $true)][string]$WindowsPath
    )

    return ((Invoke-WslCommand -Distribution $Distribution -Arguments @('wslpath', '-a', (Resolve-Path $WindowsPath).Path)).output -join '').Trim()
}

function Invoke-PlanChecks {
    param(
        [Parameter(Mandatory = $true)][object]$Manifest,
        [Parameter(Mandatory = $true)][string]$PlanHash
    )

    $manifestJson = $Manifest | ConvertTo-Json -Depth 50 -Compress
    $inspectJob = Start-Job -ScriptBlock {
        param($ScriptPath, $Distribution)
        $text = & $ScriptPath -Distro $Distribution -Compact
        [ordered]@{ exitCode = $LASTEXITCODE; json = ($text -join "`n") }
    } -ArgumentList @($script:InspectScript, $Manifest.wsl.distribution)

    $repositoryJob = Start-Job -ScriptBlock {
        param($Json, $ScannerPath)
        $manifest = $Json | ConvertFrom-Json -Depth 50
        $remote = @(& wsl.exe -d $manifest.wsl.distribution -- git ls-remote --refs $manifest.repository.canonicalUrl $manifest.repository.ref 2>$null)
        $remoteCommit = [string](@($remote | Where-Object { $_ -match '^[a-f0-9]{40}\s' } | Select-Object -First 1) -split '\s+', 2)[0]
        & wsl.exe -d $manifest.wsl.distribution -- test -d "$($manifest.repository.sourcePath)/.git"
        $exists = $LASTEXITCODE -eq 0
        $scan = $null
        if ($exists) {
            $scannerWslPath = ((& wsl.exe -d $manifest.wsl.distribution -- wslpath -a $ScannerPath 2>$null | Out-String).Trim())
            $scanText = & wsl.exe -d $manifest.wsl.distribution -- python3 $scannerWslPath $manifest.repository.sourcePath --url $manifest.repository.canonicalUrl --ref $manifest.repository.ref --commit $manifest.repository.commit 2>$null
            $scan = ($scanText -join "`n")
        }
        [ordered]@{ remoteCommit = $remoteCommit; sourcePresent = $exists; scanJson = $scan }
    } -ArgumentList @($manifestJson, $script:ScannerScript)

    $composeJob = Start-Job -ScriptBlock {
        param($Json)
        $manifest = $Json | ConvertFrom-Json -Depth 50
        $arguments = @('compose', '-p', [string]$manifest.compose.projectName)
        foreach ($file in @($manifest.compose.files)) { $arguments += @('-f', [string]$file) }
        foreach ($profile in @($manifest.compose.profiles)) { $arguments += @('--profile', [string]$profile) }
        $fileChecks = @($manifest.compose.files | ForEach-Object {
            & wsl.exe -d $manifest.wsl.distribution -- test -f $_
            [ordered]@{ path = $_; exists = $LASTEXITCODE -eq 0 }
        })
        $images = @()
        $configValid = $false
        if (@($fileChecks | Where-Object { -not $_.exists }).Count -eq 0) {
            $images = @(& wsl.exe -d $manifest.wsl.distribution -- docker @arguments config --images 2>$null)
            $configValid = $LASTEXITCODE -eq 0
        }
        [ordered]@{ files = $fileChecks; configValid = $configValid; images = @($images | ForEach-Object { [string]$_ }) }
    } -ArgumentList @($manifestJson)

    $cloudflareJob = Start-Job -ScriptBlock {
        param($ScriptPath, $PlanManifestPath, $PlanCredentialPath, $PlanAccessCredentialPath, $PlanApiBaseUri, $AllowLoopback)
        $parameters = @{
            Action = 'Plan'
            ManifestPath = $PlanManifestPath
            ApiBaseUri = [uri]$PlanApiBaseUri
            Compact = $true
        }
        if ($PlanCredentialPath) { $parameters.CredentialPath = $PlanCredentialPath }
        if ($PlanAccessCredentialPath) { $parameters.AccessCredentialPath = $PlanAccessCredentialPath }
        if ($AllowLoopback) { $parameters.AllowInsecureLoopbackForTest = $true }
        $text = & $ScriptPath @parameters
        [ordered]@{ exitCode = $LASTEXITCODE; json = ($text -join "`n") }
    } -ArgumentList @($script:CloudflareScript, [IO.Path]::GetFullPath($ManifestPath), $CredentialPath, $AccessCredentialPath, $ApiBaseUri.AbsoluteUri, [bool]$AllowInsecureLoopbackForTest)

    $jobs = @($inspectJob, $repositoryJob, $composeJob, $cloudflareJob)
    try {
        $jobs | Wait-Job | Out-Null
        $environmentResult = Receive-Job $inspectJob
        $repositoryResult = Receive-Job $repositoryJob
        $composeResult = Receive-Job $composeJob
        $cloudflareResult = Receive-Job $cloudflareJob

        $environment = $environmentResult.json | ConvertFrom-Json -Depth 40
        $repositoryScan = if ($repositoryResult.scanJson) { $repositoryResult.scanJson | ConvertFrom-Json -Depth 40 } else { $null }
        $cloudflare = $cloudflareResult.json | ConvertFrom-Json -Depth 40
        $blockers = [Collections.Generic.List[object]]::new()
        foreach ($blocker in @($environment.blockers)) { $blockers.Add($blocker) }
        if ($repositoryResult.remoteCommit -ne $Manifest.repository.commit) {
            $blockers.Add([ordered]@{ code = 'repository_commit_drift'; message = '远端 ref 不再指向批准提交。' })
        }
        if (-not $repositoryResult.sourcePresent) {
            $blockers.Add([ordered]@{ code = 'repository_analysis_source_missing'; message = '计划模式不写文件；请先提供只读分析副本或扫描报告。' })
        }
        if ($repositoryScan -and @($repositoryScan.blockers).Count -gt 0) {
            foreach ($blocker in @($repositoryScan.blockers)) { $blockers.Add($blocker) }
        }
        if (-not $composeResult.configValid) {
            $blockers.Add([ordered]@{ code = 'compose_config_invalid'; message = 'Compose 文件缺失或结构化解析失败。' })
        }
        foreach ($blocker in @(Get-ObjectProperty $cloudflare 'blockers' @())) { $blockers.Add($blocker) }
        if (Get-ObjectProperty $cloudflare 'error') {
            $blockers.Add([ordered]@{ code = 'cloudflare_preflight_failed'; message = [string]$cloudflare.error.message })
        }

        $manifestForOutput = ($Manifest | ConvertTo-Json -Depth 50 -Compress) | ConvertFrom-Json -Depth 50
        if (-not (Get-ObjectProperty $manifestForOutput 'approval')) {
            $manifestForOutput | Add-Member -NotePropertyName approval -NotePropertyValue ([pscustomobject]@{})
        }
        if ($manifestForOutput.approval.PSObject.Properties['planHash']) {
            $manifestForOutput.approval.planHash = $PlanHash
        }
        else {
            $manifestForOutput.approval | Add-Member -NotePropertyName planHash -NotePropertyValue $PlanHash
        }

        return [ordered]@{
            schemaVersion = '2.0'
            mode = 'Plan'
            readOnly = $true
            planHash = $PlanHash
            canApply = $blockers.Count -eq 0
            deploymentManifest = $manifestForOutput
            changes = [ordered]@{
                wsl = @('创建或更新源码、本地覆盖、状态文件和 Compose 容器')
                cloudflare = @(Get-ObjectProperty $cloudflare 'changes' @())
            }
            rollbackBoundary = @('不自动删除 Tunnel 或 DNS', '不自动删除数据卷', '失败阶段可用 Resume 续跑')
            authorizationScope = @($Manifest.approval.scope)
            checks = [ordered]@{
                environment = $environment
                repository = [ordered]@{ remoteCommit = $repositoryResult.remoteCommit; sourcePresent = $repositoryResult.sourcePresent; scan = $repositoryScan }
                compose = $composeResult
                cloudflare = $cloudflare
            }
            blockers = @($blockers)
        }
    }
    finally {
        $jobs | Remove-Job -Force -ErrorAction SilentlyContinue
    }
}

function Write-DeploymentFiles {
    param([Parameter(Mandatory = $true)][object]$Manifest)

    $files = @(Get-ObjectProperty $Manifest 'deploymentFiles' @())
    foreach ($file in $files) {
        $relativePath = [string](Get-ObjectProperty $file 'path')
        $encoded = [string](Get-ObjectProperty $file 'contentBase64')
        $expectedHash = [string](Get-ObjectProperty $file 'sha256')
        if ($relativePath -notmatch '^\.codex-deploy/(?:[A-Za-z0-9._-]+/)*[A-Za-z0-9._-]+$') {
            throw [InvalidOperationException]::new('部署文件只能写入 .codex-deploy，且不得包含路径穿越。')
        }
        try {
            $bytes = [Convert]::FromBase64String($encoded)
        }
        catch {
            throw [InvalidOperationException]::new('部署文件 contentBase64 无效。')
        }
        try {
            $actualHash = ([Convert]::ToHexString([Security.Cryptography.SHA256]::HashData($bytes))).ToLowerInvariant()
            if ($actualHash -ne $expectedHash) {
                throw [InvalidOperationException]::new('部署文件内容哈希与批准清单不一致。')
            }
            $targetPath = "$($Manifest.repository.sourcePath)/$relativePath"
            $script = 'set -eu; target="\$TARGET_PATH"; directory="\$(dirname "\$target")"; install -d -m 755 -- "\$directory"; temporary="\$(mktemp "\$directory/.deploy-file.XXXXXX")"; trap ''rm -f -- "\$temporary"'' EXIT; cat > "\$temporary"; chmod 644 -- "\$temporary"; mv -f -- "\$temporary" "\$target"; trap - EXIT'
            [Console]::OpenStandardOutput() | Out-Null
            $memory = [IO.MemoryStream]::new($bytes, $false)
            $process = [Diagnostics.Process]::new()
            $process.StartInfo = [Diagnostics.ProcessStartInfo]::new('wsl.exe')
            foreach ($argument in @('-d', [string]$Manifest.wsl.distribution, '--', 'env', "TARGET_PATH=$targetPath", 'sh', '-c', $script)) {
                $process.StartInfo.ArgumentList.Add($argument)
            }
            $process.StartInfo.RedirectStandardInput = $true
            $process.StartInfo.RedirectStandardOutput = $true
            $process.StartInfo.RedirectStandardError = $true
            $process.StartInfo.UseShellExecute = $false
            [void]$process.Start()
            $memory.CopyTo($process.StandardInput.BaseStream)
            $process.StandardInput.Close()
            $process.WaitForExit()
            if ($process.ExitCode -ne 0) {
                throw [InvalidOperationException]::new('部署覆盖文件写入 WSL 失败。')
            }
        }
        finally {
            if ($null -ne $bytes) { [Array]::Clear($bytes, 0, $bytes.Length) }
        }
    }

    $excludeScript = 'set -eu; exclude="\$SOURCE_PATH/.git/info/exclude"; mkdir -p -- "\$(dirname "\$exclude")"; touch -- "\$exclude"; grep -qxF ''.codex-deploy/'' "\$exclude" || printf ''%s\n'' ''.codex-deploy/'' >> "\$exclude"'
    [void](Invoke-WslCommand -Distribution $Manifest.wsl.distribution -Arguments @('env', "SOURCE_PATH=$($Manifest.repository.sourcePath)", 'sh', '-c', $excludeScript))
}

function Invoke-SourceStage {
    param([Parameter(Mandatory = $true)][object]$Manifest)

    $sourcePath = [string]$Manifest.repository.sourcePath
    $exists = (Invoke-WslCommand -Distribution $Manifest.wsl.distribution -Arguments @('test', '-d', "$sourcePath/.git") -AllowFailure).exitCode -eq 0
    if (-not $exists) {
        $cloneScript = 'set -eu; source_path="\$SOURCE_PATH"; parent="\$(dirname "\$source_path")"; install -d -m 755 -- "\$parent"; GIT_LFS_SKIP_SMUDGE=1 git -c core.hooksPath=/dev/null clone --no-checkout --no-recurse-submodules --filter=blob:none -- "\$REPOSITORY_URL" "\$source_path"; git -C "\$source_path" -c core.hooksPath=/dev/null fetch --no-tags origin "\$COMMIT"; GIT_LFS_SKIP_SMUDGE=1 git -C "\$source_path" -c core.hooksPath=/dev/null checkout --detach "\$COMMIT"'
        [void](Invoke-WslCommand -Distribution $Manifest.wsl.distribution -Arguments @('env', "SOURCE_PATH=$sourcePath", "REPOSITORY_URL=$($Manifest.repository.canonicalUrl)", "COMMIT=$($Manifest.repository.commit)", 'sh', '-c', $cloneScript))
    }
    else {
        $status = Invoke-WslCommand -Distribution $Manifest.wsl.distribution -Arguments @('git', '-C', $sourcePath, 'status', '--porcelain', '--untracked-files=no')
        if (($status.output -join '').Trim()) {
            throw [InvalidOperationException]::new('源码目录存在已跟踪修改，拒绝覆盖。')
        }
        [void](Invoke-WslCommand -Distribution $Manifest.wsl.distribution -Arguments @('git', '-C', $sourcePath, '-c', 'core.hooksPath=/dev/null', 'fetch', '--no-tags', 'origin', [string]$Manifest.repository.commit))
        [void](Invoke-WslCommand -Distribution $Manifest.wsl.distribution -Arguments @('env', 'GIT_LFS_SKIP_SMUDGE=1', 'git', '-C', $sourcePath, '-c', 'core.hooksPath=/dev/null', 'checkout', '--detach', [string]$Manifest.repository.commit))
    }
    Write-DeploymentFiles -Manifest $Manifest
}

function Get-ComposeConfigHash {
    param([Parameter(Mandatory = $true)][object]$Manifest)

    $arguments = Get-ComposeArguments $Manifest
    $arguments += @('config', '--format', 'json', '--no-interpolate', '--no-env-resolution')
    $script = 'set -eu; docker "\$@" | sha256sum | awk ''{print \$1}'''
    $result = Invoke-WslCommand -Distribution $Manifest.wsl.distribution -Arguments (@('sh', '-c', $script, 'compose-hash') + $arguments)
    $hash = ($result.output -join '').Trim()
    if ($hash -notmatch '^[a-f0-9]{64}$') {
        throw [InvalidOperationException]::new('无法计算 Compose 配置哈希。')
    }
    return $hash
}

function Invoke-Compose {
    param(
        [Parameter(Mandatory = $true)][object]$Manifest,
        [Parameter(Mandatory = $true)][string[]]$Arguments
    )

    $composeArguments = Get-ComposeArguments $Manifest
    return Invoke-WslCommand -Distribution $Manifest.wsl.distribution -Arguments (@('docker') + $composeArguments + $Arguments)
}

function Assert-ServiceHealthy {
    param(
        [Parameter(Mandatory = $true)][object]$Manifest,
        [Parameter(Mandatory = $true)][string]$Service
    )

    for ($attempt = 1; $attempt -le 30; $attempt++) {
        $result = Invoke-Compose -Manifest $Manifest -Arguments @('ps', '--format', 'json', $Service)
        $text = ($result.output -join "`n").Trim()
        try {
            $containers = @($text | ConvertFrom-Json -Depth 20)
        }
        catch {
            throw [InvalidOperationException]::new("无法解析 Compose 服务状态：$Service")
        }
        if ($containers.Count -ge 1) {
            $allHealthy = $true
            foreach ($container in $containers) {
                $state = [string](Get-ObjectProperty $container 'State')
                $health = [string](Get-ObjectProperty $container 'Health')
                if ($state -ne 'running' -or ($health -and $health -ne 'healthy')) {
                    $allHealthy = $false
                    break
                }
            }
            if ($allHealthy) {
                return
            }
        }
        if ($attempt -lt 30) {
            Start-Sleep -Seconds 2
        }
    }
    throw [InvalidOperationException]::new("Compose 服务未在时限内进入健康状态：$Service")
}

function Invoke-CloudflareScript {
    param(
        [Parameter(Mandatory = $true)][ValidateSet('Plan', 'Apply', 'Status')][string]$Action,
        [ValidateSet('Tunnel', 'Route', 'All')][string]$Target = 'All'
    )

    $parameters = @{
        Action = $Action
        ManifestPath = [IO.Path]::GetFullPath($ManifestPath)
        ApiBaseUri = $ApiBaseUri
        Compact = $true
    }
    if ($Action -eq 'Apply') { $parameters.Target = $Target }
    if ($CredentialPath) { $parameters.CredentialPath = $CredentialPath }
    if ($AccessCredentialPath) { $parameters.AccessCredentialPath = $AccessCredentialPath }
    if ($AllowInsecureLoopbackForTest) { $parameters.AllowInsecureLoopbackForTest = $true }
    $json = (& $script:CloudflareScript @parameters | Out-String).Trim()
    if ($LASTEXITCODE -ne 0) {
        throw [InvalidOperationException]::new('Cloudflare 子流程失败；请查看脱敏 JSON 结果。')
    }
    return $json | ConvertFrom-Json -Depth 40
}

function Invoke-ApplyStages {
    param(
        [Parameter(Mandatory = $true)][object]$Manifest,
        [Parameter(Mandatory = $true)][string]$PlanHash,
        [Parameter(Mandatory = $true)][object]$State
    )

    foreach ($stage in $script:Stages) {
        if ($stage -in @($State.completedStages)) {
            continue
        }
        $State.currentStage = $stage
        $State.updatedAt = [DateTimeOffset]::Now.ToString('o')
        Write-WslState -Manifest $Manifest -State $State
        try {
            switch ($stage) {
                'preflight' {
                    $environmentJson = & $script:InspectScript -Distro $Manifest.wsl.distribution -Compact
                    $environment = ($environmentJson -join "`n") | ConvertFrom-Json -Depth 40
                    if (@($environment.blockers).Count -gt 0 -or [string]$environment.wsl.selectedDistro -ne [string]$Manifest.wsl.distribution) {
                        throw [InvalidOperationException]::new('执行前 WSL 环境检查未通过。')
                    }
                    if ((Get-RemoteCommit -Manifest $Manifest) -ne $Manifest.repository.commit) {
                        throw [InvalidOperationException]::new('远端提交发生漂移，必须重新规划。')
                    }
                    $cloudflarePlan = Invoke-CloudflareScript -Action Plan
                    if (-not $cloudflarePlan.canApply) {
                        throw [InvalidOperationException]::new('Cloudflare 对象或权限发生漂移，必须重新规划。')
                    }
                }
                'source' {
                    Invoke-SourceStage -Manifest $Manifest
                }
                'build' {
                    $State.hashes.composeConfig = Get-ComposeConfigHash -Manifest $Manifest
                    if ([bool](Get-ObjectProperty $Manifest.compose 'pull' $true)) {
                        [void](Invoke-Compose -Manifest $Manifest -Arguments @('pull', '--ignore-buildable'))
                    }
                    if ([bool](Get-ObjectProperty $Manifest.compose 'build' $true)) {
                        [void](Invoke-Compose -Manifest $Manifest -Arguments @('build', '--pull'))
                    }
                }
                'app' {
                    [void](Invoke-Compose -Manifest $Manifest -Arguments @('up', '-d', '--no-build', [string]$Manifest.compose.appService))
                    Assert-ServiceHealthy -Manifest $Manifest -Service $Manifest.compose.appService
                }
                'tunnel' {
                    $result = Invoke-CloudflareScript -Action Apply -Target Tunnel
                    $State.objects.tunnelId = [string]$result.objects.tunnelId
                    $State.hashes.cloudflareConfig = [string](Get-ObjectProperty $Manifest.cloudflare 'configurationHash')
                    Write-WslState -Manifest $Manifest -State $State
                    [void](Invoke-Compose -Manifest $Manifest -Arguments @('up', '-d', '--no-build', [string]$Manifest.compose.tunnelService))
                    Assert-ServiceHealthy -Manifest $Manifest -Service $Manifest.compose.tunnelService
                }
                'route' {
                    $result = Invoke-CloudflareScript -Action Apply -Target Route
                    $State.objects.dnsRecordId = [string]$result.objects.dnsRecordId
                    $State.objects.accessApplicationId = [string](Get-ObjectProperty $result.objects 'accessApplicationId')
                    $State.objects.accessPolicyId = [string](Get-ObjectProperty $result.objects 'accessPolicyId')
                }
                'acceptance' {
                    Assert-ServiceHealthy -Manifest $Manifest -Service $Manifest.compose.appService
                    Assert-ServiceHealthy -Manifest $Manifest -Service $Manifest.compose.tunnelService
                    $cloudflareStatus = Invoke-CloudflareScript -Action Status
                    if (@($cloudflareStatus.blockers).Count -gt 0 -or -not [string]$cloudflareStatus.objects.tunnelId) {
                        throw [InvalidOperationException]::new('Cloudflare Tunnel 或远程配置验收未通过。')
                    }
                    $statusCode = $null
                    for ($attempt = 1; $attempt -le 12; $attempt++) {
                        try {
                            $acceptanceUrl = [string](Get-ObjectProperty (Get-ObjectProperty $Manifest 'acceptance') 'url' "https://$($Manifest.cloudflare.hostname)/")
                            $response = Invoke-WebRequest -Uri $acceptanceUrl -Method Get -TimeoutSec 15 -MaximumRedirection 5
                            $statusCode = [int]$response.StatusCode
                            if ($statusCode -ge 200 -and $statusCode -lt 400) { break }
                        }
                        catch {
                            if ($attempt -lt 12) { Start-Sleep -Seconds 5 }
                        }
                    }
                    if ($statusCode -lt 200 -or $statusCode -ge 400) {
                        throw [InvalidOperationException]::new('公网 TLS/HTTP 验收未通过。')
                    }
                    $State.acceptance = [ordered]@{ appHealthy = $true; tunnelHealthy = $true; publicHttpStatus = $statusCode; verifiedAt = [DateTimeOffset]::Now.ToString('o') }
                }
                'recorded' {
                    # 最终状态本身就是无密钥部署记录；这里只完成状态机收口。
                }
            }

            Complete-Stage -State $State -Stage $stage
            Write-WslState -Manifest $Manifest -State $State
        }
        catch {
            # Cloudflare 子流程会在创建对象后立即落盘 ID；失败收口时先合并，避免覆盖所有权证据。
            $persistedState = Get-WslState -Manifest $Manifest
            if ($persistedState -and [string](Get-ObjectProperty $persistedState.objects 'tunnelId')) {
                $State.objects.tunnelId = [string]$persistedState.objects.tunnelId
            }
            if ($persistedState -and [string](Get-ObjectProperty $persistedState.objects 'dnsRecordId')) {
                $State.objects.dnsRecordId = [string]$persistedState.objects.dnsRecordId
            }
            if ($persistedState -and [string](Get-ObjectProperty $persistedState.objects 'accessApplicationId')) {
                $State.objects.accessApplicationId = [string]$persistedState.objects.accessApplicationId
            }
            if ($persistedState -and [string](Get-ObjectProperty $persistedState.objects 'accessPolicyId')) {
                $State.objects.accessPolicyId = [string]$persistedState.objects.accessPolicyId
            }
            $State.lastError = [ordered]@{ code = "${stage}_failed"; stage = $stage; at = [DateTimeOffset]::Now.ToString('o') }
            $State.updatedAt = [DateTimeOffset]::Now.ToString('o')
            Write-WslState -Manifest $Manifest -State $State
            throw [InvalidOperationException]::new("部署在阶段 '$stage' 中断，可修复后使用 Resume 继续。")
        }
    }
    return $State
}

function Write-JsonResult {
    param([Parameter(Mandatory = $true)][object]$Value)
    if ($Compact) { $Value | ConvertTo-Json -Depth 50 -Compress } else { $Value | ConvertTo-Json -Depth 50 }
}

try {
    $manifest = Read-Manifest -LiteralPath $ManifestPath
    Assert-DeploymentManifest -Manifest $manifest
    $planHash = Get-PlanHash -Manifest $manifest

    if ($Mode -eq 'Plan') {
        Write-JsonResult (Invoke-PlanChecks -Manifest $manifest -PlanHash $planHash)
        $global:LASTEXITCODE = 0
        return
    }

    if ($ApprovedPlanHash -notmatch '^[a-f0-9]{64}$' -or $ApprovedPlanHash -ne $planHash) {
        throw [InvalidOperationException]::new('批准的计划哈希与当前清单不一致，必须重新规划。')
    }
    $declaredHash = [string](Get-ObjectProperty $manifest.approval 'planHash')
    if ($declaredHash -and $declaredHash -ne $planHash) {
        throw [InvalidOperationException]::new('清单内计划哈希与当前内容不一致。')
    }

    $riskItems = @(Get-ObjectProperty $manifest 'riskConfirmations' @())
    $separateRiskIds = @($riskItems | Where-Object { [bool](Get-ObjectProperty $_ 'requiresSeparateApproval' $false) } | ForEach-Object { [string]$_.id })
    foreach ($riskId in $separateRiskIds) {
        if ($riskId -notin $ConfirmRisk) {
            throw [InvalidOperationException]::new("高风险操作 '$riskId' 需要单独确认。")
        }
    }

    $state = Get-WslState -Manifest $manifest
    if ($Mode -eq 'Apply') {
        if ($state -and [string](Get-ObjectProperty $state 'schemaVersion') -eq '2.0' -and @($state.completedStages).Count -gt 0) {
            throw [InvalidOperationException]::new('已存在未完成或已完成的 v2 状态；请使用 Resume。')
        }
        $state = New-DeploymentState -Manifest $manifest -PlanHash $planHash
    }
    elseif (-not $state -or [string](Get-ObjectProperty $state 'schemaVersion') -ne '2.0') {
        throw [InvalidOperationException]::new('Resume 需要已有的 v2 部署状态。')
    }
    elseif ([string]$state.planHash -ne $planHash) {
        throw [InvalidOperationException]::new('已有状态绑定了其他计划哈希，拒绝续跑。')
    }

    Write-WslState -Manifest $manifest -State $state
    $finalState = Invoke-ApplyStages -Manifest $manifest -PlanHash $planHash -State $state
    Write-JsonResult ([ordered]@{ schemaVersion = '2.0'; mode = $Mode; completed = $finalState.currentStage -eq 'complete'; planHash = $planHash; state = $finalState })
}
catch {
    $message = if ($_.Exception.Message -match '(?i)(token|secret|password|authorization)\s*[:=]') { '部署失败，异常内容已脱敏。' } else { $_.Exception.Message }
    Write-JsonResult ([ordered]@{ schemaVersion = '2.0'; mode = $Mode; error = [ordered]@{ code = 'deployment_failed'; message = $message } })
    $global:LASTEXITCODE = 2
    return
}

$global:LASTEXITCODE = 0
