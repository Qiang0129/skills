[CmdletBinding()]
param(
    [Parameter()]
    [string]$Distro,

    [Parameter()]
    [switch]$Compact
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
[Console]::OutputEncoding = [System.Text.UTF8Encoding]::new($false)
$OutputEncoding = [System.Text.UTF8Encoding]::new($false)

function ConvertTo-NormalizedText {
    param([AllowNull()][object]$Value)

    if ($null -eq $Value) {
        return ''
    }

    return (($Value | Out-String) -replace "`0", '').Trim()
}

function ConvertTo-Boolean {
    param([AllowNull()][string]$Value)

    return $Value -eq 'true'
}

function Convert-WindowsPathToWslPath {
    param([string]$Path)

    if ($Path -match '^([A-Za-z]):\\(.*)$') {
        $drive = $Matches[1].ToLowerInvariant()
        $tail = $Matches[2] -replace '\\', '/'
        return "/mnt/$drive/$tail"
    }

    return $null
}

function Get-WslDistributions {
    param([string]$WslExecutable)

    $result = @()
    $registryRoot = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Lxss'

    if (Test-Path -LiteralPath $registryRoot) {
        $rootProperties = Get-ItemProperty -LiteralPath $registryRoot
        $defaultDistribution = $rootProperties.DefaultDistribution

        foreach ($key in Get-ChildItem -LiteralPath $registryRoot) {
            $properties = Get-ItemProperty -LiteralPath $key.PSPath
            if (-not $properties.DistributionName) {
                continue
            }

            $result += [ordered]@{
                name      = [string]$properties.DistributionName
                version   = if ($null -ne $properties.Version) { [int]$properties.Version } else { $null }
                isDefault = $key.PSChildName -eq $defaultDistribution
            }
        }
    }

    if ($result.Count -gt 0) {
        return @($result | Sort-Object -Property @{ Expression = { -not $_.isDefault } }, name)
    }

    $fallbackOutput = ConvertTo-NormalizedText (& $WslExecutable --list --quiet 2>&1)
    foreach ($name in ($fallbackOutput -split "`r?`n" | Where-Object { $_.Trim() })) {
        $result += [ordered]@{
            name      = $name.Trim()
            version   = $null
            isDefault = $false
        }
    }

    return $result
}

function Invoke-WslProbe {
    param(
        [string]$WslExecutable,
        [string]$DistributionName
    )

    # 只输出部署判断需要的元数据；禁止读取环境变量值、密钥内容或完整进程参数。
    $probe = @'
set +e
. /etc/os-release 2>/dev/null
emit() { printf '%s=%s\n' "$1" "$2"; }
command_version() {
  if command -v "$1" >/dev/null 2>&1; then
    shift
    "$@" 2>&1 | head -n 1
  else
    printf 'missing'
  fi
}
emit os_name "${NAME:-unknown}"
emit os_version "${VERSION_ID:-unknown}"
emit kernel "$(uname -r 2>/dev/null)"
emit architecture "$(uname -m 2>/dev/null)"
emit current_user "$(id -un 2>/dev/null)"
emit pid1 "$(ps -p 1 -o comm= 2>/dev/null | xargs)"
emit systemd_state "$(systemctl is-system-running 2>/dev/null || true)"
emit systemd_failed_units "$(systemctl --failed --no-legend --plain 2>/dev/null | awk '{print $1}' | paste -sd ',' -)"
emit cpu_count "$(nproc 2>/dev/null || printf '0')"
emit memory_total_bytes "$(awk '/MemTotal:/ {print $2 * 1024}' /proc/meminfo 2>/dev/null | awk '{printf "%.0f", $1}')"
emit memory_available_bytes "$(awk '/MemAvailable:/ {print $2 * 1024}' /proc/meminfo 2>/dev/null | awk '{printf "%.0f", $1}')"
emit disk_total_bytes "$(df -B1 / 2>/dev/null | awk 'NR==2 {print $2}')"
emit disk_available_bytes "$(df -B1 / 2>/dev/null | awk 'NR==2 {print $4}')"
emit git_version "$(command_version git git --version)"
emit curl_version "$(command_version curl curl --version)"
emit python_version "$(command_version python3 python3 --version)"
emit docker_client_version "$(command_version docker docker --version)"
emit docker_server_version "$(docker version --format '{{.Server.Version}}' 2>/dev/null)"
emit docker_service_active "$(if systemctl is-active --quiet docker 2>/dev/null; then printf 'true'; else printf 'false'; fi)"
emit docker_service_enabled "$(if systemctl is-enabled --quiet docker 2>/dev/null; then printf 'true'; else printf 'false'; fi)"
emit compose_version "$(docker compose version --short 2>/dev/null)"
emit cloudflared_binary_version "$(command_version cloudflared cloudflared --version)"
emit cloudflared_process_count "$(pgrep -c -x cloudflared 2>/dev/null || true)"
emit github_dns "$(if getent ahosts github.com >/dev/null 2>&1; then printf 'true'; else printf 'false'; fi)"
emit cloudflare_dns "$(if getent ahosts region1.v2.argotunnel.com >/dev/null 2>&1; then printf 'true'; else printf 'false'; fi)"
emit github_https "$(if timeout 5 bash -c ': </dev/tcp/github.com/443' >/dev/null 2>&1; then printf 'true'; else printf 'false'; fi)"
emit cloudflare_edge "$(if timeout 5 bash -c ': </dev/tcp/region1.v2.argotunnel.com/7844' >/dev/null 2>&1; then printf 'true'; else printf 'false'; fi)"
emit wsl_conf_present "$(if [ -f /etc/wsl.conf ]; then printf 'true'; else printf 'false'; fi)"
emit cloudflare_config_present "$(if [ -f /etc/cloudflared/config.yml ] || [ -f /etc/cloudflared/config.yaml ] || [ -f "$HOME/.cloudflared/config.yml" ] || [ -f "$HOME/.cloudflared/config.yaml" ]; then printf 'true'; else printf 'false'; fi)"
emit cloudflare_certificate_present "$(if [ -f "$HOME/.cloudflared/cert.pem" ]; then printf 'true'; else printf 'false'; fi)"
emit docker_info_available "$(if docker info >/dev/null 2>&1; then printf 'true'; else printf 'false'; fi)"
if docker version --format '{{.Server.Version}}' >/dev/null 2>&1; then
  emit compose_projects_base64 "$(docker compose ls --format json 2>/dev/null | base64 -w0)"
  printf 'containers_begin\n'
  docker ps --format '{{.Names}}\t{{.Image}}\t{{.Status}}\t{{.Ports}}\t{{.Label "com.docker.compose.project"}}\t{{.Label "com.docker.compose.service"}}' 2>/dev/null || true
  printf 'containers_end\n'
else
  emit compose_projects_base64 ''
  printf 'containers_begin\ncontainers_end\n'
fi
'@

    $cleanProbe = $probe -replace "`r", ''
    $lines = @($cleanProbe | & $WslExecutable -d $DistributionName -- bash -s 2>&1)
    $probeExitCode = $LASTEXITCODE
    if ($probeExitCode -ne 0 -and -not ($lines | Where-Object { ([string]$_ -replace "`0", '') -like 'os_name=*' })) {
        throw "无法检查 WSL 发行版 '$DistributionName'。"
    }

    $values = @{}
    $expectedKeys = @(
        'os_name', 'os_version', 'kernel', 'architecture', 'current_user', 'pid1',
        'systemd_state', 'systemd_failed_units', 'cpu_count', 'memory_total_bytes',
        'memory_available_bytes', 'disk_total_bytes', 'disk_available_bytes',
        'git_version', 'curl_version', 'python_version', 'docker_client_version',
        'docker_server_version', 'docker_service_active', 'docker_service_enabled',
        'compose_version', 'cloudflared_binary_version', 'cloudflared_process_count',
        'github_dns', 'cloudflare_dns', 'github_https', 'cloudflare_edge',
        'wsl_conf_present', 'cloudflare_config_present', 'cloudflare_certificate_present',
        'compose_projects_base64', 'docker_info_available'
    )
    foreach ($key in $expectedKeys) {
        $values[$key] = ''
    }
    $containers = @()
    $readingContainers = $false

    foreach ($rawLine in $lines) {
        $line = ([string]$rawLine -replace "`0", '').TrimEnd("`r", "`n")
        if ($line -eq 'containers_begin') {
            $readingContainers = $true
            continue
        }
        if ($line -eq 'containers_end') {
            $readingContainers = $false
            continue
        }

        if ($readingContainers) {
            $parts = @($line -split "`t", 6)
            if ($parts.Count -ge 4 -and $parts[0]) {
                $containers += [ordered]@{
                    name           = $parts[0]
                    image          = $parts[1]
                    status         = $parts[2]
                    publishedPorts = $parts[3]
                    composeProject = if ($parts.Count -ge 5) { $parts[4] } else { '' }
                    composeService = if ($parts.Count -ge 6) { $parts[5] } else { '' }
                    isCloudflared  = ($parts[1] -match '(^|/)cloudflared(:|@)' -or $parts[0] -match 'cloudflared')
                }
            }
            continue
        }

        $pair = @($line -split '=', 2)
        if ($pair.Count -eq 2 -and $pair[0]) {
            $values[$pair[0]] = $pair[1]
        }
    }

    $composeProjects = @()
    if ($values.compose_projects_base64) {
        try {
            $jsonBytes = [Convert]::FromBase64String($values.compose_projects_base64)
            $jsonText = [Text.Encoding]::UTF8.GetString($jsonBytes)
            if ($jsonText.Trim()) {
                $composeProjects = @($jsonText | ConvertFrom-Json)
            }
        }
        catch {
            $composeProjects = @()
        }
    }

    # 某些 PowerShell/WSL 组合会截断嵌套命令替换的长行，改用独立只读命令补齐容器清单。
    if ($composeProjects.Count -eq 0 -and $values.docker_server_version) {
        $composeOutput = ConvertTo-NormalizedText (& $WslExecutable -d $DistributionName -- docker compose ls --format json 2>$null)
        if ($composeOutput) {
            try {
                $composeProjects = @($composeOutput | ConvertFrom-Json)
            }
            catch {
                $composeProjects = @()
            }
        }
    }

    if ($containers.Count -eq 0 -and $values.docker_server_version) {
        $containerFormat = '{{.Names}}|{{.Image}}|{{.Status}}|{{.Ports}}|{{.Label "com.docker.compose.project"}}|{{.Label "com.docker.compose.service"}}'
        $containerLines = @(& $WslExecutable -d $DistributionName -- docker ps --format $containerFormat 2>$null)
        foreach ($rawContainerLine in $containerLines) {
            $parts = @(([string]$rawContainerLine -replace "`0", '') -split '\|', 6)
            if ($parts.Count -ge 4 -and $parts[0]) {
                $containers += [ordered]@{
                    name           = $parts[0]
                    image          = $parts[1]
                    status         = $parts[2]
                    publishedPorts = $parts[3]
                    composeProject = if ($parts.Count -ge 5) { $parts[4] } else { '' }
                    composeService = if ($parts.Count -ge 6) { $parts[5] } else { '' }
                    isCloudflared  = ($parts[1] -match '(^|/)cloudflared(:|@)' -or $parts[0] -match 'cloudflared')
                }
            }
        }
    }

    return [ordered]@{
        os = [ordered]@{
            name         = $values.os_name
            version      = $values.os_version
            kernel       = $values.kernel
            architecture = $values.architecture
            currentUser  = $values.current_user
        }
        systemd = [ordered]@{
            pid1        = $values.pid1
            state       = $values.systemd_state
            failedUnits = @($values.systemd_failed_units -split ',' | Where-Object { $_ })
        }
        resources = [ordered]@{
            cpuCount            = [int64]($values.cpu_count ?? 0)
            memoryTotalBytes    = [int64]($values.memory_total_bytes ?? 0)
            memoryAvailableBytes = [int64]($values.memory_available_bytes ?? 0)
            diskTotalBytes      = [int64]($values.disk_total_bytes ?? 0)
            diskAvailableBytes  = [int64]($values.disk_available_bytes ?? 0)
        }
        tools = [ordered]@{
            git         = $values.git_version
            curl        = $values.curl_version
            python      = $values.python_version
            docker      = $values.docker_client_version
            dockerServer = $values.docker_server_version
            compose     = $values.compose_version
            cloudflared = $values.cloudflared_binary_version
        }
        docker = [ordered]@{
            infoAvailable  = ConvertTo-Boolean $values.docker_info_available
            serviceActive  = ConvertTo-Boolean $values.docker_service_active
            serviceEnabled = ConvertTo-Boolean $values.docker_service_enabled
            composeProjects = $composeProjects
            containers      = $containers
        }
        network = [ordered]@{
            githubDns      = ConvertTo-Boolean $values.github_dns
            githubHttps    = ConvertTo-Boolean $values.github_https
            cloudflareDns  = ConvertTo-Boolean $values.cloudflare_dns
            cloudflareEdge = ConvertTo-Boolean $values.cloudflare_edge
        }
        cloudflare = [ordered]@{
            processCount      = [int]($values.cloudflared_process_count ?? 0)
            configPresent     = ConvertTo-Boolean $values.cloudflare_config_present
            certificatePresent = ConvertTo-Boolean $values.cloudflare_certificate_present
            containers        = @($containers | Where-Object { $_.isCloudflared })
        }
        wslConfigPresent = ConvertTo-Boolean $values.wsl_conf_present
    }
}

$warnings = [System.Collections.Generic.List[string]]::new()
$blockers = [System.Collections.Generic.List[object]]::new()
$wslCommand = Get-Command wsl.exe -ErrorAction SilentlyContinue

if (-not $wslCommand) {
    $blockers.Add([ordered]@{ code = 'wsl_missing'; message = '未找到 wsl.exe，无法部署到 WSL。' })
    $report = [ordered]@{
        schemaVersion = '1.0'
        capturedAt    = [DateTimeOffset]::Now.ToString('o')
        windows       = $null
        wsl           = [ordered]@{ installed = $false; version = $null; distributions = @(); selectedDistro = $null }
        target        = $null
        warnings      = @($warnings)
        blockers      = @($blockers)
    }
    $report | ConvertTo-Json -Depth 12 -Compress:$Compact
    exit 2
}

$operatingSystem = Get-CimInstance Win32_OperatingSystem
$computerSystem = Get-CimInstance Win32_ComputerSystem
$wslVersionOutput = ConvertTo-NormalizedText (& $wslCommand.Source --version 2>&1)
$wslVersion = $null
if ($wslVersionOutput -match '(?im)^\s*WSL[^\d\r\n]*(\d+(?:\.\d+){1,3})') {
    $wslVersion = $Matches[1]
}

$distributions = @(Get-WslDistributions -WslExecutable $wslCommand.Source)
$selectedDistribution = $null

if ($Distro) {
    $selectedDistribution = $distributions | Where-Object { $_.name -eq $Distro } | Select-Object -First 1
    if (-not $selectedDistribution) {
        $blockers.Add([ordered]@{ code = 'distro_not_found'; message = "未找到指定的 WSL 发行版：$Distro。" })
    }
}
elseif ($distributions.Count -eq 1) {
    $selectedDistribution = $distributions[0]
}
elseif ($distributions.Count -gt 1) {
    $blockers.Add([ordered]@{ code = 'distro_selection_required'; message = '检测到多个 WSL 发行版，需要先明确选择部署目标。' })
}
else {
    $blockers.Add([ordered]@{ code = 'distro_missing'; message = '没有检测到已安装的 WSL 发行版。' })
}

$gcmCandidates = @()
$windowsGit = Get-Command git.exe -ErrorAction SilentlyContinue
if ($windowsGit) {
    $gitRoot = Split-Path -Parent (Split-Path -Parent $windowsGit.Source)
    $gcmCandidates += Join-Path $gitRoot 'mingw64\bin\git-credential-manager.exe'
}
$gcmCandidates += 'C:\Program Files\Git\mingw64\bin\git-credential-manager.exe'
$gcmPath = $gcmCandidates | Where-Object { Test-Path -LiteralPath $_ } | Select-Object -First 1

$scheduledTasks = @()
if (Get-Command Get-ScheduledTask -ErrorAction SilentlyContinue) {
    $scheduledTasks = @(Get-ScheduledTask -ErrorAction SilentlyContinue |
        Where-Object { $_.TaskName -match 'wsl|docker|cloudflare|cloudflared' } |
        ForEach-Object {
            [ordered]@{
                name  = $_.TaskName
                state = [string]$_.State
            }
        })
}

$target = $null
if ($selectedDistribution) {
    if ($selectedDistribution.version -and [int]$selectedDistribution.version -ne 2) {
        $blockers.Add([ordered]@{ code = 'wsl2_required'; message = "发行版 '$($selectedDistribution.name)' 不是 WSL2。" })
    }

    try {
        $target = Invoke-WslProbe -WslExecutable $wslCommand.Source -DistributionName $selectedDistribution.name
    }
    catch {
        $blockers.Add([ordered]@{ code = 'distro_probe_failed'; message = $_.Exception.Message })
    }
}

if ($target) {
    if (-not $target.docker.serviceActive -or -not $target.tools.dockerServer) {
        $blockers.Add([ordered]@{ code = 'docker_unavailable'; message = 'Docker Engine 不可用，不能执行容器化部署。' })
    }
    if (-not $target.tools.compose) {
        $blockers.Add([ordered]@{ code = 'compose_unavailable'; message = 'Docker Compose 不可用。' })
    }
    if ($target.resources.memoryAvailableBytes -lt 2GB) {
        $blockers.Add([ordered]@{ code = 'memory_insufficient'; message = 'WSL 可用内存低于 2 GiB。' })
    }
    if ($target.resources.diskAvailableBytes -lt 10GB) {
        $blockers.Add([ordered]@{ code = 'disk_insufficient'; message = 'WSL 根文件系统可用空间低于 10 GiB。' })
    }
    if (-not $target.network.githubDns -or -not $target.network.githubHttps) {
        $blockers.Add([ordered]@{ code = 'github_network_unavailable'; message = 'WSL 无法正常解析或连接 GitHub。' })
    }
    if (-not $target.network.cloudflareDns -or -not $target.network.cloudflareEdge) {
        $blockers.Add([ordered]@{ code = 'cloudflare_network_unavailable'; message = 'WSL 无法正常解析或连接 Cloudflare Tunnel 边缘端口 7844。' })
    }
    if ($target.systemd.state -notin @('running', 'degraded')) {
        $warnings.Add("systemd 当前状态为 '$($target.systemd.state)'，执行前需要复核关键服务。")
    }
    if ($target.systemd.state -eq 'degraded') {
        $warnings.Add('systemd 处于 degraded；仅当 Docker、DNS 或网络等关键能力失败时才阻塞部署。')
    }
    if ($target.os.currentUser -eq 'root') {
        $warnings.Add('当前 WSL 默认用户为 root；构建第三方仓库仍具有较高主机权限风险。')
    }
    if (-not ($scheduledTasks | Where-Object { $_.name -eq 'WSL-Ubuntu-KeepAlive' })) {
        $warnings.Add('未检测到既定的 WSL 登录常驻任务；公网可用性可能在 WSL 自动退出后中断。')
    }
}

$report = [ordered]@{
    schemaVersion = '1.0'
    capturedAt    = [DateTimeOffset]::Now.ToString('o')
    windows       = [ordered]@{
        caption            = $operatingSystem.Caption
        version            = $operatingSystem.Version
        buildNumber        = $operatingSystem.BuildNumber
        totalMemoryBytes   = [int64]$computerSystem.TotalPhysicalMemory
        logicalProcessors  = [int]$computerSystem.NumberOfLogicalProcessors
    }
    wsl           = [ordered]@{
        installed       = $true
        version         = $wslVersion
        distributions   = $distributions
        selectedDistro  = if ($selectedDistribution) { $selectedDistribution.name } else { $null }
    }
    githubCredentialManager = [ordered]@{
        available = [bool]$gcmPath
        windowsPath = $gcmPath
        wslPath = if ($gcmPath) { Convert-WindowsPathToWslPath $gcmPath } else { $null }
    }
    scheduledTasks = $scheduledTasks
    target        = $target
    warnings      = @($warnings | ForEach-Object { $_ })
    blockers      = @($blockers | ForEach-Object { $_ })
}

$report | ConvertTo-Json -Depth 12 -Compress:$Compact
if ($blockers.Count -gt 0) {
    exit 2
}
