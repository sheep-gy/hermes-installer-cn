<#
  Hermes 安装加速器
  用法：双击「Hermes安装加速.bat」（它会调用本脚本的 menu 模式）

  它解决两个老问题：
    ① 老 bat 把代理端口写死（127.0.0.1:13004）。LeapVPN 一换模式
       （比如切到 TUN 全局模式），这个端口就不存在了，git 被指到
       一个死代理上，反而装不上。→ 改成每次都现判断、现探测。
    ② 老 bat 只管设、不管收。一旦设置留在系统里，Hermes 桌面端
       以后升级就会卡在这个死代理上。→ 改成装完自动清理 + 一键恢复。

  一律走代理：
    · 每次现探测 LeapVPN 的代理端口（不写死，端口会变）
    · 临时设好 → 启动安装 → 装完自动收干净（零残留）
    · 探测不到端口会告诉你具体是哪种情况、该怎么办
    · 装完自动清理，保证 Hermes 桌面端以后升级不会被死代理卡住
#>
param(
    [ValidateSet('menu','mirror','install','restore','check','update')]
    [string]$Action = 'menu',
    [switch]$NoLaunch,       # 仅测试：只判断和设置，不真的启动安装程序
    [string]$ProbeUrl = 'https://github.com'   # 判断"直连通不通"用的目标，仅供测试
)

try { [Console]::OutputEncoding = [System.Text.Encoding]::GetEncoding(936) } catch {}
try { [System.Net.ServicePointManager]::SecurityProtocol = [System.Net.SecurityProtocolType]::Tls12 } catch {}
$ErrorActionPreference = 'Continue'

$RegPath  = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Internet Settings'
$ProxyVars = @('HTTP_PROXY','HTTPS_PROXY','ALL_PROXY','NO_PROXY')
$VpnNames  = @('leapvpn','clash','clash-verge','clashwin','verge-mihomo','mihomo',
               'sing-box','v2ray','v2rayn','xray','nekoray','hiddify','hiddify-core')

# 工具所在目录（打包成 exe 时，由 exe 通过环境变量告知真实位置）
$ScriptDir = if ($env:HERMES_TOOL_DIR) { $env:HERMES_TOOL_DIR }
             elseif ($PSScriptRoot)      { $PSScriptRoot }
             else                        { (Get-Location).Path }

# 官方安装包直链（缺失时联网下载用；直连即可，不用 VPN）
$SetupUrl = 'https://hermes-assets.nousresearch.com/Hermes-Setup.exe'

# 官方安装脚本 install.ps1 的下载地址（安装器原本要从 raw.githubusercontent.com 拿，
# 那个域名国内常被墙 → 用国内镜像先下好喂给它，绕开）
$InstallScriptUrls = @(
    'https://gh-proxy.com/https://raw.githubusercontent.com/NousResearch/hermes-agent/main/scripts/install.ps1',
    'https://hermes-agent.nousresearch.com/install.ps1'
)

# ══════ 国内镜像清单（安装前会实际测速，挑最快的用）══════
$RepoGitUrl    = 'https://github.com/NousResearch/hermes-agent.git'
$RepoProbePath = 'https://github.com/NousResearch/hermes-agent/archive/refs/heads/main.tar.gz'
$RepoMirrors = @(
    @{ Name = 'gh-proxy';    Prefix = 'https://gh-proxy.com/' },
    @{ Name = 'gh.llkk.cc';  Prefix = 'https://gh.llkk.cc/' },
    @{ Name = 'ghproxy.net'; Prefix = 'https://ghproxy.net/' },
    @{ Name = 'github直连';  Prefix = '' }
)
$PypiMirrors = @(
    'https://pypi.tuna.tsinghua.edu.cn/simple',
    'https://mirrors.aliyun.com/pypi/simple',
    'https://pypi.mirrors.ustc.edu.cn/simple',
    'https://mirrors.cloud.tencent.com/pypi/simple'
)
$NpmMirrors = @(
    'https://registry.npmmirror.com',
    'https://mirrors.cloud.tencent.com/npm'
)

# 找 Hermes-Setup.exe 的几个候选位置
$SetupCands = @(
    (Join-Path $ScriptDir 'Hermes-Setup.exe'),
    'D:\下载\Hermes-Setup.exe',
    (Join-Path $env:USERPROFILE 'Downloads\Hermes-Setup.exe'),
    (Join-Path ([Environment]::GetFolderPath('Desktop')) 'Hermes-Setup.exe')
)

function Say    { param([string]$m,[string]$c='Gray'); Write-Host $m -ForegroundColor $c }
function MsgOK  { param([string]$m); Write-Host "  [$([char]0x221A)] $m" -ForegroundColor Green }
function MsgNG  { param([string]$m); Write-Host "  [$([char]0x00D7)] $m" -ForegroundColor Red }
function MsgTip { param([string]$m); Write-Host "  [!] $m" -ForegroundColor Yellow }
function MsgRaw { param([string]$m); Write-Host "  $m" -ForegroundColor Gray }

function Wait-Key {
    param([string]$m = '  按回车键返回菜单…')
    Write-Host ''
    Write-Host $m -ForegroundColor DarkGray -NoNewline
    [void](Read-Host)
}

function Update-ProxyNow {
    if (-not ('PxTool.Native' -as [type])) {
        $sig = @"
[DllImport("wininet.dll", SetLastError=true, CharSet=CharSet.Auto)]
public static extern bool InternetSetOption(IntPtr hInternet, int dwOption, IntPtr lpBuffer, int dwBufferLength);
"@
        try { Add-Type -MemberDefinition $sig -Name Native -Namespace PxTool -ErrorAction Stop | Out-Null } catch {}
    }
    try {
        [void][PxTool.Native]::InternetSetOption([IntPtr]::Zero, 39, [IntPtr]::Zero, 0)
        [void][PxTool.Native]::InternetSetOption([IntPtr]::Zero, 37, [IntPtr]::Zero, 0)
    } catch {}
}

function Resolve-GitExe {
    $c = Get-Command git -ErrorAction SilentlyContinue
    if ($c -and $c.Source) { return $c.Source }
    foreach ($p in @(
        (Join-Path $env:ProgramFiles 'Git\cmd\git.exe'),
        (Join-Path ${env:ProgramFiles(x86)} 'Git\cmd\git.exe'),
        (Join-Path $env:LOCALAPPDATA 'Programs\Git\cmd\git.exe'))) {
        if ($p -and (Test-Path $p)) { return $p }
    }
    $hermes = Join-Path $env:LOCALAPPDATA 'hermes\tools'
    if (Test-Path $hermes) {
        $d = Get-ChildItem $hermes -Filter 'git-*' -Directory -ErrorAction SilentlyContinue | Select-Object -First 1
        if ($d) {
            $p = Join-Path $d.FullName 'cmd\git.exe'
            if (Test-Path $p) { return $p }
        }
    }
    return ''
}

# ── 关键判断：不走任何代理，能不能连上 GitHub ──
function Test-DirectInternet {
    param([string]$Url, [int]$TimeoutMs = 8000)
    if (-not $Url) { $Url = $ProbeUrl }
    try {
        $req = [System.Net.HttpWebRequest]::Create($Url)
        $req.Proxy = New-Object System.Net.WebProxy      # 空代理 = 明确不走代理
        $req.Timeout = $TimeoutMs
        $req.ReadWriteTimeout = $TimeoutMs
        $resp = $req.GetResponse()
        $resp.Close()
        return $true
    } catch { return $false }
}

# ── 有没有 TUN 虚拟网卡（全局模式）──
function Get-TunnelAdapter {
    try {
        return @(Get-NetAdapter -ErrorAction SilentlyContinue |
                 Where-Object { $_.Status -eq 'Up' -and $_.InterfaceDescription -match 'Tunnel|TUN|TAP|WireGuard|Wintun' })
    } catch { return @() }
}

# ── 找可用代理端口 ──
function Test-ProxyPort {
    param([int]$Port, [string]$Url = 'https://www.google.com/generate_204', [int]$TimeoutMs = 5000)
    try {
        $req = [System.Net.HttpWebRequest]::Create($Url)
        $req.Proxy = New-Object System.Net.WebProxy("http://127.0.0.1:$Port")
        $req.Timeout = $TimeoutMs
        $req.ReadWriteTimeout = $TimeoutMs
        $resp = $req.GetResponse()
        $resp.Close()
        return $true
    } catch { return $false }
}

function Find-ProxyPort {
    $procs = @()
    foreach ($n in $VpnNames) { $procs += @(Get-Process -Name $n -ErrorAction SilentlyContinue) }
    $procs = @($procs | Where-Object { $_ -ne $null })
    if ($procs.Count -eq 0) { return 0 }
    $ports = @()
    foreach ($p in $procs) {
        try {
            $ports += @(Get-NetTCPConnection -State Listen -OwningProcess $p.Id -ErrorAction SilentlyContinue |
                        Where-Object { $_.LocalAddress -eq '127.0.0.1' } |
                        Select-Object -ExpandProperty LocalPort)
        } catch {}
    }
    $ports = @($ports | Sort-Object -Unique)
    foreach ($pt in $ports) { if (Test-ProxyPort -Port $pt) { return $pt } }
    return 0
}

function Find-Setup {
    foreach ($p in $SetupCands) {
        if ($p -and (Test-Path $p)) { return $p }
    }
    return ''
}

# 找安装包；本机没有就联网下载（放到工具目录）
function Get-Setup {
    $s = Find-Setup
    if ($s) { return $s }

    Say ''
    Say '  本机没找到安装包，正在联网下载（约 7.9MB，直连不用 VPN）…' Yellow
    $dest = Join-Path $ScriptDir 'Hermes-Setup.exe'
    try {
        try { [System.Net.ServicePointManager]::SecurityProtocol = [System.Net.SecurityProtocolType]::Tls12 } catch {}
        $wc = New-Object System.Net.WebClient
        $wc.DownloadFile($SetupUrl, $dest)
    } catch {
        Say ''
        MsgNG "下载失败：$($_.Exception.Message)"
        MsgRaw "  下载地址：$SetupUrl"
        MsgTip '检查一下网络，或手动把这个 exe 放到本文件夹里。'
        return ''
    }
    if (Test-Path $dest) {
        MsgOK "安装包已下载：$dest"
        return $dest
    }
    MsgNG '下载没成功。'
    return ''
}

# 把官方安装脚本改成"优先走国内镜像"。
# 原版下组件时先试 github.com，失败才切镜像 —— 但 github 在国内是"能连但被限速到
# 几十 KB/s"，于是它一直卡在慢线上、永远不切镜像（下个 git/uv 要几十分钟）。
function Repair-InstallScript {
    param([string]$Text)
    # ① 先把"测速排序"辅助函数插进安装脚本
    if (-not $Text.Contains('HERMES_SPEED_ORDER')) {
        $helper = @'
# HERMES_SPEED_ORDER
function Test-HermesUrlSpeed {
    param([string]$Url, [int]$MaxBytes = 262144, [int]$TimeoutSec = 4)
    if (-not $Url) { return 0 }
    try {
        $h = ([uri]$Url).Host
        $dns = [System.Net.Dns]::BeginGetHostAddresses($h, $null, $null)
        if (-not $dns.AsyncWaitHandle.WaitOne(2500)) { return 0 }
        try { [void][System.Net.Dns]::EndGetHostAddresses($dns) } catch { return 0 }
        $req = [System.Net.HttpWebRequest]::Create($Url)
        $req.Timeout = $TimeoutSec * 1000
        $req.ReadWriteTimeout = $TimeoutSec * 1000
        try { $req.AddRange(0, $MaxBytes - 1) } catch {}
        $sw = [System.Diagnostics.Stopwatch]::StartNew()
        $resp = $req.GetResponse(); $rs = $resp.GetResponseStream()
        $buf = New-Object byte[] 65536; $total = 0
        while ($total -lt $MaxBytes -and $sw.Elapsed.TotalSeconds -lt $TimeoutSec) {
            $n = $rs.Read($buf, 0, $buf.Length); if ($n -le 0) { break }; $total += $n
        }
        $sw.Stop(); try { $rs.Close() } catch {}; try { $resp.Close() } catch {}
        if ($total -le 0) { return 0 }
        return [int]($total / ([Math]::Max($sw.Elapsed.TotalSeconds, 0.05)) / 1024)
    } catch { return 0 }
}
function Order-UrlsBySpeed {
    param([string[]]$Urls)
    $cands = @()
    foreach ($u in $Urls) {
        foreach ($c in @($u, "https://gh-proxy.com/$u", "https://gh.llkk.cc/$u")) {
            if ($cands -notcontains $c) { $cands += $c }
        }
    }
    $good = @(); $bad = @()
    foreach ($c in $cands) {
        $sp = Test-HermesUrlSpeed -Url $c
        if ($sp -gt 0) { $good += [pscustomobject]@{ Url = $c; Speed = $sp } } else { $bad += $c }
    }
    $ordered = @($good | Sort-Object Speed -Descending | ForEach-Object { $_.Url })
    if ($ordered.Count -eq 0) { return $Urls }
    return @($ordered + $bad)
}
'@
        $anchor = '$RepoUrl = if ($env:HERMES_REPO_URL)'
        $idx = $Text.IndexOf($anchor)
        if ($idx -ge 0) {
            $eol = $Text.IndexOf("`n", $idx)
            if ($eol -ge 0) { $Text = $Text.Insert($eol + 1, $helper + "`n") }
        }
    }

    # ② 下载顺序：改成"先测速、挑最快的那个"（官方地址会自动加国内代理一起比）
    if ($Text.Contains('$urls = @($Url)')) {
        $Text = $Text.Replace('$urls = @($Url)', '$urls = @()')
        $rep = 'if ($MirrorUrl -and $MirrorUrl -ne $Url) { $urls += $MirrorUrl }; $urls += $Url' + "`n" +
               '    try { $urls = @(Order-UrlsBySpeed -Urls $urls) } catch {}'
        $Text = $Text.Replace('if ($MirrorUrl -and $MirrorUrl -ne $Url) { $urls += $MirrorUrl }', $rep)
    }
    # 代码仓库默认地址也改成 gh-proxy 镜像（env 有设就以 env 为准）
    $Text = $Text.Replace('"https://github.com/NousResearch/hermes-agent.git"',
                          '"https://gh-proxy.com/https://github.com/NousResearch/hermes-agent.git"')

    # 3. 克隆前自动探测：挨个试镜像，挑一个能连上的用（网络对域名挑食时救命）
    if (-not $Text.Contains('HERMES_MIRROR_PROBE')) {
        $anchor = '        if ($Commit) { $checkout = @(''--no-checkout'') }'
        if ($Text.Contains($anchor)) {
            $probe = @(
                '',
                '        # HERMES_MIRROR_PROBE: 仓库镜像候选（挨个试，挂了自动换下一个）',
                '        $repoTries = @()',
                '        if ($env:HERMES_REPO_URL) { $repoTries += $env:HERMES_REPO_URL }',
                '        $repoTries += @(',
                "            'https://gh-proxy.com/https://github.com/NousResearch/hermes-agent.git',",
                "            'https://gh.llkk.cc/https://github.com/NousResearch/hermes-agent.git',",
                "            'https://github.com/NousResearch/hermes-agent.git'",
                '        )',
                '        $script:RepoTries = @($repoTries | Select-Object -Unique)',
                '        if ($env:HERMES_REPO_URL) { $script:RepoUrl = $env:HERMES_REPO_URL }'
            ) -join "`n"
            $Text = $Text.Replace($anchor, $anchor + "`n" + $probe)
        }
    }

    # 克隆时：低速就放弃；重试时换下一个镜像（镜像会说挂就挂）
    $Text = $Text.Replace(
        '                Invoke-Logged $cloneLabel { git clone @progress --filter=blob:none @checkout --branch $Branch $RepoUrl $tree }',
        '                $tryUrl = $RepoUrl' + "`n" +
        '                if ($script:RepoTries -and $script:RepoTries.Count -ge $attempt) { $tryUrl = $script:RepoTries[$attempt-1] }' + "`n" +
        '                $cloneLabel = "Cloning $tryUrl ($Branch)"' + "`n" +
        '                Invoke-Logged $cloneLabel { git -c http.lowSpeedLimit=2000 -c http.lowSpeedTime=25 clone @progress --filter=blob:none @checkout --branch $Branch $tryUrl $tree }')
    $Text = $Text.Replace(
        '                Invoke-Logged "Cloning history" { git clone @progress --filter=blob:none --no-checkout --branch $Branch $RepoUrl $tree }',
        '                Invoke-Logged "Cloning history" { git -c http.lowSpeedLimit=2000 -c http.lowSpeedTime=25 clone @progress --filter=blob:none --no-checkout --branch $Branch $RepoUrl $tree }')
    return $Text
}

# ── 预先下好安装脚本，让安装器绕开被墙的 raw.githubusercontent.com ──
# 安装器认环境变量 HERMES_SETUP_DEV_REPO_ROOT：只要该目录下有 scripts\install.ps1，
# 它就直接用本地脚本，不再联网下载。（脚本按 UTF-8 BOM 写，PowerShell 5.1 才不会乱码）
function Ensure-InstallScript {
    $root = Join-Path $env:LOCALAPPDATA 'hermes\_tool_install'
    $dir  = Join-Path $root 'scripts'
    $file = Join-Path $dir 'install.ps1'
    if (-not (Test-Path $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }

    Say '  正在准备安装脚本（走国内镜像，不用 VPN）…' Gray
    $got = $false
    foreach ($u in $InstallScriptUrls) {
        try {
            try { [System.Net.ServicePointManager]::SecurityProtocol = [System.Net.SecurityProtocolType]::Tls12 } catch {}
            $wc = New-Object System.Net.WebClient
            $bytes = $wc.DownloadData($u)
            if ($bytes -and $bytes.Length -gt 1000) {
                $text = Repair-InstallScript -Text ([System.Text.Encoding]::UTF8.GetString($bytes))
                $bom  = [byte[]](0xEF,0xBB,0xBF)
                $enc  = [System.Text.Encoding]::UTF8.GetBytes($text)
                $fs = [System.IO.File]::Create($file)
                $fs.Write($bom, 0, $bom.Length)
                $fs.Write($enc, 0, $enc.Length)
                $fs.Close()
                $got = $true
                break
            }
        } catch {}
    }

    if (-not $got -and (Test-Path $file)) {
        # 没刷成：沿用已存在的，但也确保它是改过的
        try {
            $text  = Get-Content -Path $file -Raw -Encoding UTF8
            $fixed = Repair-InstallScript -Text $text
            if ($fixed -ne $text) {
                $bom = [byte[]](0xEF,0xBB,0xBF)
                $enc = [System.Text.Encoding]::UTF8.GetBytes($fixed)
                $fs = [System.IO.File]::Create($file)
                $fs.Write($bom, 0, $bom.Length)
                $fs.Write($enc, 0, $enc.Length)
                $fs.Close()
            }
        } catch {}
        $got = $true
    }

    if ($got) {
        MsgOK '安装脚本已就绪（已改成镜像优先）'
        $env:HERMES_SETUP_DEV_REPO_ROOT = $root
        return $true
    }
    MsgTip '安装脚本没拿到，安装器可能仍要联网（失败就用 [2] 并开 VPN）'
    return $false
}

# ── 当前有没有代理残留 ──
function Get-Residue {
    $en = (Get-ItemProperty -Path $RegPath -Name ProxyEnable -ErrorAction SilentlyContinue).ProxyEnable
    $envs = @()
    foreach ($v in $ProxyVars) {
        $val = [Environment]::GetEnvironmentVariable($v,'User')
        if ($val) { $envs += "$v=$val" }
    }
    $gitExe = Resolve-GitExe
    $git = ''
    if ($gitExe) {
        $raw = & $gitExe config --global --get http.proxy 2>$null
        if ($null -ne $raw) { $git = ([string]$raw).Trim() }
    }
    return @{
        SysProxy  = ($en -eq 1)
        SysServer = (Get-ItemProperty -Path $RegPath -Name ProxyServer -ErrorAction SilentlyContinue).ProxyServer
        EnvVars   = $envs
        GitProxy  = $git
        Any       = (($en -eq 1) -or ($envs.Count -gt 0) -or ($git -ne ''))
    }
}

# ── 彻底恢复原样 ──
function Clear-Proxy {
    param([switch]$Quiet)

    New-ItemProperty -Path $RegPath -Name ProxyEnable -Value 0 -PropertyType DWord -Force | Out-Null
    Update-ProxyNow
    if (-not $Quiet) { MsgOK '系统代理：已关闭' }

    $n = 0
    foreach ($v in $ProxyVars) {
        if ([Environment]::GetEnvironmentVariable($v,'User')) {
            [Environment]::SetEnvironmentVariable($v, $null, 'User')
            $n++
        }
        Remove-Item -Path "env:$v" -ErrorAction SilentlyContinue
    }
    if (-not $Quiet) {
        if ($n -gt 0) { MsgOK "环境变量：已清掉 $n 个" } else { MsgRaw '环境变量：本来就是空的' }
    }

    $gitExe = Resolve-GitExe
    if ($gitExe) {
        & $gitExe config --global --unset http.proxy  2>$null
        & $gitExe config --global --unset https.proxy 2>$null
        if (-not $Quiet) { MsgOK 'git 代理：已清除' }
    } else {
        if (-not $Quiet) { MsgRaw 'git：没找到，跳过' }
    }

    if (-not $Quiet) {
        $r = Get-Residue
        if ($r.Any) { MsgNG '还有残留没清干净，请把上面几行发给我' }
        else { MsgOK '检查过一遍：代理设置已全部还原' }
    }
}

# ══════════════ 国内下载通道（安装 / 更新 共用）══════════════
# 只设"给本次进程用"的环境变量 —— 关掉窗口就没了，天然零残留。
# ══════ 测速：只下一小段，估算 KB/s（连不上=0）══════
function Test-UrlSpeed {
    param([string]$Url, [int]$MaxBytes = 262144, [int]$TimeoutSec = 4)
    if (-not $Url) { return 0 }
    try {
        try { [System.Net.ServicePointManager]::SecurityProtocol = [System.Net.SecurityProtocolType]::Tls12 } catch {}
        # 域名解析不了就立刻跳过（免得卡在被墙的域名上）
        $h = ([uri]$Url).Host
        $dns = [System.Net.Dns]::BeginGetHostAddresses($h, $null, $null)
        if (-not $dns.AsyncWaitHandle.WaitOne(2500)) { return 0 }
        try { [void][System.Net.Dns]::EndGetHostAddresses($dns) } catch { return 0 }

        $req = [System.Net.HttpWebRequest]::Create($Url)
        $req.Timeout = $TimeoutSec * 1000
        $req.ReadWriteTimeout = $TimeoutSec * 1000
        $req.UserAgent = 'hermes-tool'
        try { $req.AddRange(0, $MaxBytes - 1) } catch {}
        $sw = [System.Diagnostics.Stopwatch]::StartNew()
        $resp = $req.GetResponse()
        $rs = $resp.GetResponseStream()
        $buf = New-Object byte[] 65536
        $total = 0
        while ($total -lt $MaxBytes -and $sw.Elapsed.TotalSeconds -lt $TimeoutSec) {
            $n = $rs.Read($buf, 0, $buf.Length)
            if ($n -le 0) { break }
            $total += $n
        }
        $sw.Stop()
        try { $rs.Close() } catch {}
        try { $resp.Close() } catch {}
        if ($total -le 0) { return 0 }
        $sec = [Math]::Max($sw.Elapsed.TotalSeconds, 0.05)
        return [int]($total / $sec / 1024)
    } catch { return 0 }
}

# 从候选里挑最快的。每项：@{ Name=..; Url=..; Probe=.. }
function Select-FastestMirror {
    param([array]$Cands)
    $best = $null
    foreach ($c in $Cands) {
        $sp = Test-UrlSpeed -Url $c.Probe
        if ($sp -gt 0) {
            Write-Host ("      {0,-16} {1,6} KB/s" -f $c.Name, $sp) -ForegroundColor DarkGray
            if ($null -eq $best -or $sp -gt $best.Speed) {
                $best = @{ Name = $c.Name; Url = $c.Url; Speed = $sp }
            }
        } else {
            Write-Host ("      {0,-16}  连不上，跳过" -f $c.Name) -ForegroundColor DarkGray
        }
    }
    return $best
}

# ══════ 配好国内下载通道（安装/更新共用；先测速、挑最快）══════
function Set-MirrorEnv {
    Say '  正在测速、挑选最快的国内镜像（约几秒）…' Gray

    # ① 代码仓库
    $repoCands = @()
    foreach ($m in $RepoMirrors) {
        $repoCands += @{ Name = $m.Name; Url = "$($m.Prefix)$RepoGitUrl"; Probe = "$($m.Prefix)$RepoProbePath" }
    }
    $repoBest = Select-FastestMirror -Cands $repoCands
    if ($repoBest) {
        $env:HERMES_REPO_URL = $repoBest.Url
        MsgOK "代码仓库 → $($repoBest.Name)  ($($repoBest.Speed) KB/s)"
    } else {
        $env:HERMES_REPO_URL = "$($RepoMirrors[0].Prefix)$RepoGitUrl"
        MsgTip '代码仓库：测速都没通，用默认镜像'
    }

    # ② Python 依赖（用各镜像 simple/pip/ 页面测速）
    $pypiCands = @()
    foreach ($m in $PypiMirrors) {
        $pypiCands += @{ Name = ([uri]$m).Host; Url = $m; Probe = "$m/pip/" }
    }
    $pypiBest = Select-FastestMirror -Cands $pypiCands
    if ($pypiBest) {
        $env:UV_DEFAULT_INDEX = $pypiBest.Url
        $env:UV_INDEX_URL     = $pypiBest.Url
        $env:PIP_INDEX_URL    = $pypiBest.Url
        $env:PIP_TRUSTED_HOST = ([uri]$pypiBest.Url).Host
        MsgOK "Python 依赖 → $($pypiBest.Name)  ($($pypiBest.Speed) KB/s)"
    } else {
        $env:UV_DEFAULT_INDEX = $PypiMirrors[0]
        $env:UV_INDEX_URL     = $PypiMirrors[0]
        $env:PIP_INDEX_URL    = $PypiMirrors[0]
        $env:PIP_TRUSTED_HOST = ([uri]$PypiMirrors[0]).Host
        MsgTip 'Python 依赖：测速都没通，用默认镜像'
    }

    # ③ npm / Electron（用较大的 /react 包页面测速）
    $npmCands = @()
    foreach ($m in $NpmMirrors) {
        $npmCands += @{ Name = ([uri]$m).Host; Url = $m; Probe = "$m/react" }
    }
    $npmBest = Select-FastestMirror -Cands $npmCands
    if ($npmBest) {
        $env:npm_config_registry = $npmBest.Url
        MsgOK "npm 包 → $($npmBest.Name)  ($($npmBest.Speed) KB/s)"
    } else {
        $env:npm_config_registry = $NpmMirrors[0]
    }

    # ④ 其余固定镜像（无备选，直接用）
    $env:UV_PYTHON_INSTALL_MIRROR         = 'https://gh-proxy.com/https://github.com/astral-sh/python-build-standalone/releases/download'
    $env:npm_config_disturl               = 'https://npmmirror.com/mirrors/node/'
    $env:ELECTRON_MIRROR                  = 'https://npmmirror.com/mirrors/electron/'
    $env:ELECTRON_BUILDER_BINARIES_MIRROR = 'https://npmmirror.com/mirrors/electron-builder-binaries/'

    # ★ Hermes 有几个依赖必须从 GitHub 拿，给 git 加 URL 重写（只对本次有效）
    $env:GIT_CONFIG_COUNT      = '1'
    $env:GIT_CONFIG_KEY_0      = 'url.https://gh-proxy.com/https://github.com/.insteadOf'
    $env:GIT_CONFIG_VALUE_0    = 'https://github.com/'

    # 网络不稳时：让 git 在"低速"时尽快放弃，别卡在挂掉的镜像上（低于 2KB/s 持续 25 秒就断）
    $env:GIT_HTTP_LOW_SPEED_LIMIT = '2000'
    $env:GIT_HTTP_LOW_SPEED_TIME  = '25'
}

# ══════════════ 启动安装（走国内镜像，不用 VPN）══════════════
function Do-InstallMirror {
    Say ''
    Say '  ────── 启动 Hermes 安装（走国内镜像）──────' Cyan
    Say ''

    $setup = Get-Setup
    if (-not $setup) { Say ''; return }
    MsgOK "安装程序：$setup"
    Say ''
    MsgTip '这条路线不用 VPN 通道（实测 VPN 只有 ~25KB/s，镜像快 400 倍）'
    Say ''

    Set-MirrorEnv

    # ── 预先下好代码仓库 ──
    # 安装脚本最慢的一步就是 clone 这个仓库（走 VPN 要 15 分钟还常失败）。
    # 提前用镜像下好放在它要找的位置，它就会跳过 clone 直接更新，几十秒搞定。
    $repoDir = Join-Path $env:LOCALAPPDATA 'hermes\hermes-agent'
    if (Test-Path (Join-Path $repoDir '.git')) {
        MsgOK '代码仓库：已就绪（安装时会跳过最慢的 clone）'
    } else {
        $gitExe = Resolve-GitExe
        if ($gitExe) {
            Say ''
            Say '  正在预先下载代码仓库（走镜像，约 1~2 分钟）…' Yellow
            try {
                & $gitExe clone --depth=1 --branch main -q `
                    'https://gh-proxy.com/https://github.com/NousResearch/hermes-agent.git' $repoDir 2>$null
            } catch {}
            Say ''
            if (Test-Path (Join-Path $repoDir '.git')) {
                MsgOK '代码仓库：已下好'
            } else {
                MsgNG '代码仓库：没下成功，安装器会自己重试（会比较慢）'
            }
        }
    }
    Say ''

    Say '  已配好的下载通道（都是上一步测速选出来的）：' Gray
    if ($env:HERMES_REPO_URL)    { MsgRaw ("代码仓库    → " + $env:HERMES_REPO_URL) }
    if ($env:PIP_INDEX_URL)      { MsgRaw ("Python 依赖 → " + $env:PIP_INDEX_URL) }
    if ($env:npm_config_registry){ MsgRaw ("npm 包      → " + $env:npm_config_registry) }
    MsgRaw '★ Electron / Node 二进制 → npmmirror 镜像'
    MsgRaw '★ PortableGit / uv → 官方镜像 + 国内代理（自动挑最快）'
    Say ''
    MsgTip '这些只对本次安装有效，装完自动消失，不用清理。'
    Say ''

    [void](Ensure-InstallScript)
    Say ''

    if ($NoLaunch) { MsgTip '（测试模式，不真的启动安装程序）'; return }

    Launch-Setup $setup
}

# ══════════════ 启动安装（走 VPN 代理）══════════════
function Do-Install {
    Say ''
    Say '  ────────── 启动 Hermes 安装 ──────────' Cyan
    Say ''

    $setup = Get-Setup
    if (-not $setup) { Say ''; return }
    MsgOK "安装程序：$setup"

    # ── 探测代理端口（一律走代理，不靠全局模式自动接管）──
    Say ''
    Say '  正在探测 LeapVPN 的代理端口…' Gray

    $port = Find-ProxyPort
    if ($port -le 0) {
        Say ''
        MsgNG '找不到可用的代理端口，没法走代理。'
        Say ''
        MsgRaw '一般是这两种情况：'
        MsgRaw '  1. LeapVPN 没连上节点'
        MsgRaw '     → 打开它连一个节点，再回来选 [1]'
        MsgRaw '  2. LeapVPN 在【全局 / TUN 模式】'
        MsgRaw '     → 这个模式不提供代理端口，请在 LeapVPN 里'
        MsgRaw '       切成【代理模式 / 系统代理模式】'
        Say ''
        $tun = Get-TunnelAdapter
        if ($tun.Count -gt 0) {
            MsgTip "（检测到虚拟网卡 $($tun[0].Name) —— 你现在确实是全局模式）"
            Say ''
        }
        return
    }

    $full = "http://127.0.0.1:$port"
    MsgOK "代理端口：127.0.0.1:$port（每次现探测，不写死）"

    # ── 临时设代理 ──
    New-ItemProperty -Path $RegPath -Name ProxyEnable -Value 1 -PropertyType DWord -Force | Out-Null
    New-ItemProperty -Path $RegPath -Name ProxyServer -Value "127.0.0.1:$port" -PropertyType String -Force | Out-Null
    $cur = (Get-ItemProperty -Path $RegPath -Name ProxyOverride -ErrorAction SilentlyContinue).ProxyOverride
    if ([string]::IsNullOrWhiteSpace($cur)) {
        New-ItemProperty -Path $RegPath -Name ProxyOverride -Value 'localhost;127.*;10.*;192.168.*;<local>' -PropertyType String -Force | Out-Null
    }
    Update-ProxyNow

    foreach ($v in @('HTTP_PROXY','HTTPS_PROXY','ALL_PROXY')) {
        [Environment]::SetEnvironmentVariable($v, $full, 'User')
        Set-Item -Path "env:$v" -Value $full -ErrorAction SilentlyContinue
    }
    [Environment]::SetEnvironmentVariable('NO_PROXY','localhost,127.0.0.1,::1','User')

    $gitExe = Resolve-GitExe
    if ($gitExe) {
        & $gitExe config --global http.proxy  $full 2>$null
        & $gitExe config --global https.proxy $full 2>$null
    }
    MsgOK '代理已临时设好（系统代理 + 环境变量 + git）'

    # ── 验证代理真的能通 ──
    Say ''
    Say '  正在验证代理是否生效…' Gray
    $bad = @()
    foreach ($c in @(
        @{ n = 'GitHub（下 Hermes 代码）' ; u = 'https://github.com' },
        @{ n = 'Google（判进出得去）'    ; u = 'https://www.google.com/generate_204' }
    )) {
        if (Test-ProxyPort -Port $port -Url $c.u -TimeoutMs 12000) { MsgOK "$($c.n)：通" }
        else { MsgNG "$($c.n)：连不上"; $bad += $c.n }
    }
    Say ''
    if ($bad.Count -gt 0) {
        MsgTip '有连不上的 —— 多半是节点不稳或掉了。'
        MsgTip '可以先换个节点再来；不想装了，回菜单选 [2] 恢复干净。'
        Say ''
    }

    [void](Ensure-InstallScript)
    Say ''

    if ($NoLaunch) { MsgTip '（测试模式，不真的启动安装程序）'; return }

    Launch-Setup $setup -UsedProxy
}

# ── 启动安装器，等它结束，然后自动收尾 ──
function Launch-Setup {
    param([string]$Setup, [switch]$UsedProxy)

    Say '  正在启动安装程序，请在弹出的窗口里操作…' Cyan
    Say ''
    Say '  ─────────────────────────────────────────────' -ForegroundColor DarkGray
    Say '   ★ 装完之后，请【先别急着点完成】，' -ForegroundColor Yellow
    Say '     等这个黑窗口提示"已收尾"再关。' -ForegroundColor Yellow
    Say '  ─────────────────────────────────────────────' -ForegroundColor DarkGray
    Say ''

    try {
        $p = Start-Process -FilePath $Setup -PassThru
        Start-Sleep -Seconds 2
        while (-not $p.HasExited) {
            Start-Sleep -Seconds 2
            $p.Refresh()
        }
    } catch {
        MsgNG "启动失败：$($_.Exception.Message)"
        return
    }

    # 安装器可能还有后台子进程在收尾，多等一会儿
    Start-Sleep -Seconds 3

    Say ''
    Say '  ────────── 安装程序已退出 ──────────' Cyan

    Say ''
    if ($UsedProxy) {
        Say '  正在把刚才临时设的代理收干净…' Gray
        Start-Sleep -Seconds 2
        Clear-Proxy -Quiet
        Say ''
        MsgOK '已收尾：代理设置全部还原，系统干净了'
        MsgTip 'Hermes 桌面端以后升级不会再被这个死代理卡住。'
    } else {
        MsgOK '本次没有动过任何系统设置，无需清理'
    }

    Say ''
    MsgTip '接下来：如果 Hermes 桌面端开着，重启它一次。'
    Say ''
}

# ══════════════ 一键恢复 ══════════════
function Do-Restore {
    Say ''
    Say '  ────────── 一键恢复原样 ──────────' Cyan
    Say ''

    $before = Get-Residue
    if (-not $before.Any) {
        MsgOK '检查过了：系统里没有任何代理残留，本来就是干净的。'
        Say ''
        MsgTip '如果你遇到的是 Hermes 升级失败，那就不是代理的问题，'
        MsgTip '把升级时的报错发给我，我再看。'
        Say ''
        return
    }

    Say '  发现这些残留，正在清理…' Yellow
    Say ''
    if ($before.SysProxy) { MsgRaw "系统代理  → $($before.SysServer)" }
    foreach ($e in $before.EnvVars) { MsgRaw "环境变量  → $e" }
    if ($before.GitProxy) { MsgRaw "git 代理  → $($before.GitProxy)" }
    Say ''

    Clear-Proxy

    Say ''
    MsgTip '现在系统已经回到"什么都没设"的状态。'
    MsgTip 'Hermes 桌面端升级时就不会再被死代理挡住了。'
    Say ''
}

# ══════════════ 体检 ══════════════
function Show-Check {
    Say ''
    Say '  ────────── 当前状态 ──────────' Cyan
    Say ''

    $setup = Find-Setup
    if ($setup) { MsgOK "安装程序：$setup" } else { MsgTip '安装程序：没找到 Hermes-Setup.exe' }

    $tun = Get-TunnelAdapter
    if ($tun.Count -gt 0) { MsgOK "虚拟网卡：$($tun[0].Name) 已启用（TUN 全局模式）" }
    else { MsgRaw '虚拟网卡：没有 TUN 网卡（不是全局模式）' }

    $p = Find-ProxyPort
    if ($p -gt 0) { MsgOK "代理端口：127.0.0.1:$p 可用（装 Hermes 会用它）" }
    else { MsgNG '代理端口：探测不到 → 连上 LeapVPN，或切到【代理模式 / 系统代理模式】' }

    if (Test-DirectInternet -TimeoutMs 6000) {
        MsgRaw '参考：不走代理也能连上 GitHub（VPN 有全局接管）'
    } else {
        MsgRaw '参考：不走代理连不上 GitHub（必须靠代理）'
    }

    Say ''
    $r = Get-Residue
    if (-not $r.Any) {
        MsgOK '代理残留：无（系统干净）'
    } else {
        MsgNG '代理残留：有！'
        if ($r.SysProxy) { MsgRaw "  · 系统代理 → $($r.SysServer)" }
        foreach ($e in $r.EnvVars) { MsgRaw "  · $e" }
        if ($r.GitProxy) { MsgRaw "  · git 代理 → $($r.GitProxy)" }
        MsgTip '建议回菜单选 [2] 一键恢复'
    }
    Say ''
}

# ══════════════ 检查并更新 Hermes ══════════════
# 找 hermes 命令：优先 PATH，其次常见安装位置。
function Get-HermesExe {
    $c = Get-Command hermes -ErrorAction SilentlyContinue
    if ($c -and $c.Source) { return $c.Source }
    foreach ($p in @(
        (Join-Path $env:LOCALAPPDATA 'hermes\bin\hermes.exe'),
        (Join-Path $env:LOCALAPPDATA 'hermes\bin\hermes.cmd'))) {
        if ($p -and (Test-Path $p)) { return $p }
    }
    return ''
}

# Hermes 是否还开着（桌面端 Hermes.exe / 命令行 hermes.exe）
function Get-HermesProcs {
    $procs = @()
    foreach ($n in @('Hermes','hermes')) {
        $procs += @(Get-Process -Name $n -ErrorAction SilentlyContinue)
    }
    return @($procs | Where-Object { $_ -ne $null })
}

# 更新阶段：英文 → 中文（屏幕上只显示中文；英文原文收进日志文件）
$UpdateMarkers = [ordered]@{
    'finishing an interrupted source update' = '发现上次没做完的更新，先补完它…'
    'Stopping Windows gateway'               = '正在暂停后台服务…'
    'Resuming Windows gateway'               = '正在恢复后台服务…'
    'Fetching updates'                       = '正在检查更新…'
    'Pulling updates'                        = '正在应用更新…'
    'Preparing Node dependencies'            = '正在准备依赖…'
    'Building desktop packaged app'          = '正在编译桌面程序…'
    'Packaging the desktop app'              = '正在打包桌面程序…'
    'Syncing bundled skills'                 = '正在同步技能…'
    'Checking configuration'                 = '正在检查配置…'
    'Code updated'                           = '代码已更新'
    'Update complete'                        = '更新完成'
    'Already up to date'                     = '已是最新版本，无需更新'
}

# 判断这次更新成功没：以 Hermes 自己写的"更新收据"为准（比退出码可靠）
function Test-UpdateSucceeded {
    param([datetime]$Since, [string]$Log)
    $receipt = Join-Path $env:LOCALAPPDATA 'hermes\logs\update_receipts\latest.json'
    try {
        $j = Get-Content -Path $receipt -Raw -ErrorAction Stop | ConvertFrom-Json
        if ($j.outcome -eq 'success') {
            $started = [datetime]::MinValue
            try { $started = ([datetime]$j.started_at).ToUniversalTime() } catch {}
            if ($started -ge $Since.ToUniversalTime().AddMinutes(-3)) { return $true }
        }
    } catch {}
    # 兜底：看日志里有没有成功标志，且没有明确的失败标志
    $text = ''
    try { $text = [string](Get-Content -Path $Log -Raw -Encoding UTF8 -ErrorAction SilentlyContinue) } catch {}
    if ($text -match '(?i)(Update complete|up to date)' -and
        $text -notmatch '(?i)(Update failed|bootstrap FAILED|Traceback)') { return $true }
    return $false
}

# 把日志里新出现的"已知阶段"翻成中文显示（每条只显示一次；认不出的不显示）
function Show-UpdateProgress {
    param([string]$Log)
    if (-not (Test-Path $Log)) { return }
    $lines = @(Get-Content -Path $Log -Encoding UTF8 -ErrorAction SilentlyContinue)
    for ($i = $script:UpdSeen; $i -lt $lines.Count; $i++) {
        $ln = [string]$lines[$i]
        if ($ln -match 'Found\s+(\d+)\s+new commit') {
            if (-not $script:UpdShown.ContainsKey('found')) {
                $script:UpdShown['found'] = $true
                Write-Host "    → 找到 $($Matches[1]) 处更新" -ForegroundColor Gray
            }
            continue
        }
        foreach ($k in $UpdateMarkers.Keys) {
            if ($ln -match [regex]::Escape($k)) {
                if (-not $script:UpdShown.ContainsKey($k)) {
                    $script:UpdShown[$k] = $true
                    Write-Host ("    → " + $UpdateMarkers[$k]) -ForegroundColor Gray
                }
                break
            }
        }
    }
    $script:UpdSeen = $lines.Count
}

function Do-Update {
    Say ''
    Say '  ────────── 检查并更新 Hermes ──────────' Cyan
    Say ''

    $hermes = Get-HermesExe
    if (-not $hermes) {
        MsgNG '没找到 hermes 命令，可能 Hermes 没装好。'
        MsgRaw '  找过：PATH 里的 hermes、%LOCALAPPDATA%\hermes\bin\hermes.exe'
        Say ''
        return
    }
    MsgOK "更新程序：$hermes"
    Say ''

    # ── ① 先看 Hermes 是不是还开着（只提醒，不自动关）──
    $running = Get-HermesProcs
    if ($running.Count -gt 0) {
        MsgNG "检测到 Hermes 还开着（有 $($running.Count) 个进程），更新会被【文件被占用】挡住。"
        Say ''
        MsgRaw '请先【完全退出】Hermes 桌面端：'
        MsgRaw '  · 点右上角 × 只是最小化到托盘 → 要右键托盘图标选【退出】'
        MsgRaw '  · 实在找不到，就用任务管理器结束 Hermes 进程'
        Say ''
        MsgTip '关干净后，回来再选一次 [5] 即可。'
        Say ''
        return
    }
    MsgOK 'Hermes 已关闭，可以更新。'
    Say ''

    # ── ② 配好国内下载通道（只对本次有效，关窗即消失）──
    Set-MirrorEnv

    # ── ③ 真正更新（非交互，自动完成）──
    if ($NoLaunch) { MsgTip '（测试模式，不真的执行更新）'; Say ''; return }

    $go = Read-Host '   回车=开始更新，输入 n=先不更新'
    if ($go -match '^\s*n') { Say '  已取消，没有改动任何东西。'; Say ''; return }
    Say ''
    Say '  正在更新，请稍候…（拉最新代码 + 重装依赖 + 刷新桌面程序）' Yellow
    Say '  这一步通常几分钟，中途请不要关这个窗口。' Yellow
    Say ''

    # 日志目录：Hermes 的英文细节都写进这里（出问题把它发给我）
    $logDir = Join-Path $ScriptDir '更新日志'
    if (-not (Test-Path $logDir)) { New-Item -ItemType Directory -Path $logDir -Force | Out-Null }
    $stamp   = Get-Date -Format 'yyyyMMdd-HHmmss'
    $logFile = Join-Path $logDir "更新-$stamp.txt"
    $errFile = Join-Path $logDir "更新-$stamp.err.txt"

    $script:UpdSeen  = 0
    $script:UpdShown = @{}

    $ok = $false
    $t0 = Get-Date
    try {
        $p = Start-Process -FilePath $hermes -ArgumentList 'update','-y' `
             -RedirectStandardOutput $logFile -RedirectStandardError $errFile `
             -NoNewWindow -PassThru
        while (-not $p.HasExited) {
            Show-UpdateProgress -Log $logFile
            $sec = [int]((Get-Date) - $t0).TotalSeconds
            Write-Host "`r    已进行 $sec 秒…" -ForegroundColor DarkGray -NoNewline
            Start-Sleep -Milliseconds 800
            $p.Refresh()
        }
        Show-UpdateProgress -Log $logFile
        Write-Host "`r                                   " -NoNewline
        Write-Host ''
        $ok = Test-UpdateSucceeded -Since $t0 -Log $logFile
    } catch {
        MsgNG "更新失败：$($_.Exception.Message)"
    }

    Say ''
    Say '  ─────────────────────────────────────────────' -ForegroundColor DarkGray
    if ($ok) {
        MsgOK '更新完成！'
        MsgTip '现在可以打开 Hermes 了。'
    } else {
        MsgNG '更新没有正常结束。'
        Say ''
        MsgRaw '最近几行原始信息（英文，供排查）：'
        $tail = @(Get-Content -Path $logFile -Encoding UTF8 -Tail 8 -ErrorAction SilentlyContinue)
        foreach ($l in $tail) { if ($l -and $l.Trim()) { Write-Host ("    " + $l) -ForegroundColor DarkGray } }
        MsgTip "完整日志：$logFile"
        MsgTip '把这个日志发给我，我来看。'
    }
    Say '  ─────────────────────────────────────────────' -ForegroundColor DarkGray
    Say ''
}

# ══════════════ 菜单 ══════════════
function Show-Menu {
    while ($true) {
        Clear-Host
        Write-Host ''
        Write-Host '   ========================================================' -ForegroundColor DarkCyan
        Write-Host ''
        Write-Host '        Hermes 安装加速器  (LeapVPN)' -ForegroundColor White
        Write-Host ''
        Write-Host '   ========================================================' -ForegroundColor DarkCyan
        Write-Host ''
        Write-Host '     [1]   启动 Hermes 安装   ★ 走国内镜像（最快，不用VPN）' -ForegroundColor Green
        Write-Host '     [2]   启动 Hermes 安装     走 VPN 代理（原方式）' -ForegroundColor Gray
        Write-Host '     [3]   一键恢复原样（清掉所有代理残留）' -ForegroundColor Gray
        Write-Host '     [4]   查看当前状态' -ForegroundColor Gray
        Write-Host '     [5]   检查并更新 Hermes   ★ 收到更新提示时用它（不用桌面端）' -ForegroundColor Green
        Write-Host '     [0]   退出' -ForegroundColor Gray
        Write-Host ''
        Write-Host '   --------------------------------------------------------' -ForegroundColor DarkGray
        Write-Host '    实测速度（同一份文件）：' -ForegroundColor DarkGray
        Write-Host '      走 VPN 节点   →  25 KB/秒   要下 33 分钟' -ForegroundColor DarkGray
        Write-Host '      走国内镜像    →  9.9 MB/秒  只要 6 秒' -ForegroundColor DarkGray
        Write-Host '   --------------------------------------------------------' -ForegroundColor DarkGray
        Write-Host ''

        $ch = Read-Host '   请输入数字后回车'

        switch ($ch) {
            '1' { Clear-Host; Do-InstallMirror; Wait-Key }
            '2' { Clear-Host; Do-Install;       Wait-Key }
            '3' { Clear-Host; Do-Restore;       Wait-Key }
            '4' { Clear-Host; Show-Check;       Wait-Key }
            '5' { Clear-Host; Do-Update;        Wait-Key }
            '0' { return }
            default { }
        }
    }
}

switch ($Action) {
    'menu'    { Show-Menu }
    'mirror'  { Do-InstallMirror }
    'install' { Do-Install }
    'restore' { Do-Restore }
    'check'   { Show-Check }
    'update'  { Do-Update }
}
