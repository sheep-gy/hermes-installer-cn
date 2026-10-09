<#
  全局代理开关 —— 配合 LeapVPN 使用
  用法：双击「全局代理开关.bat」即可（它会调用本脚本的 menu 模式）

  为什么要单独给 git 设代理：
      Hermes 安装程序靠 git clone 拉代码，而 git 只认自己的配置，
      不认 Windows 的"系统代理"开关，所以必须单独设一条。

  探测判据说明：
      用 www.google.com/generate_204 当靶子 —— 它在大陆直连必定不通，
      只有真正走了代理才通。（gstatic.com / github.com 直连也能通，没区分度）

  退出提醒说明：
      菜单里常驻一块红底大字提醒"用完记得选 [2] 恢复"；
      选 [0] 退出时如果代理还开着，还会弹窗问你要不要顺手关掉。
      （点窗口右上角的 × 属于强杀，任何程序都拦不住，所以靠菜单里的红字提醒。）
#>
param(
    [ValidateSet('on','off','status','menu')]
    [string]$Action = 'menu',
    [int]$ForcePort = 0      # 仅供测试：跳过自动探测，直接指定端口
)

try { [Console]::OutputEncoding = [System.Text.Encoding]::GetEncoding(936) } catch {}
try { [System.Net.ServicePointManager]::SecurityProtocol = [System.Net.SecurityProtocolType]::Tls12 } catch {}
$ErrorActionPreference = 'Continue'

$RegPath   = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Internet Settings'
$BypassDef = 'localhost;127.*;10.*;172.16.*;172.17.*;172.18.*;172.19.*;172.20.*;172.21.*;172.22.*;172.23.*;172.24.*;172.25.*;172.26.*;172.27.*;172.28.*;172.29.*;172.30.*;172.31.*;192.168.*;<local>'
$ProbeUrl  = 'https://www.google.com/generate_204'

# 常见代理软件进程名（小写）。LeapVPN 排第一，其余是顺手兼容。
$VpnNames = @('leapvpn','clash','clash-verge','clashwin','verge-mihomo','mihomo',
              'sing-box','v2ray','v2rayn','xray','nekoray','hiddify','hiddify-core')

function Say    { param([string]$m,[string]$c='Gray'); Write-Host $m -ForegroundColor $c }
function MsgOK  { param([string]$m); Write-Host "  [$([char]0x221A)] $m" -ForegroundColor Green }
function MsgNG  { param([string]$m); Write-Host "  [$([char]0x00D7)] $m" -ForegroundColor Red }
function MsgTip { param([string]$m); Write-Host "  [!] $m" -ForegroundColor Yellow }

function Wait-Key {
    param([string]$m = '  按回车键返回菜单…')
    Write-Host ''
    Write-Host $m -ForegroundColor DarkGray -NoNewline
    [void](Read-Host)
}

# ── 让系统立刻应用新的代理设置 ──
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

# ── 弹一个提醒框，返回 $true 表示用户选了"是" ──
function Show-Ask {
    param([string]$Text, [string]$Title = '全局代理开关')

    # 测试钩子：设了 HERMES_PROXY_NOGUI 就不真弹窗，
    # 把该弹的内容写进 _弹窗记录.log，并按环境变量的值当作"点了是/否"。
    # 平时绝对不会走到这里，不影响正常使用。
    if ($env:HERMES_PROXY_NOGUI) {
        $ans = if ($env:HERMES_PROXY_NOGUI -eq 'yes') { 'YES' } else { 'NO' }
        try {
            $line = "[$ans] $Title :: " + $Text.Replace("`r`n", ' | ')
            $line | Out-File -FilePath (Join-Path $PSScriptRoot '_弹窗记录.log') -Append -Encoding UTF8
        } catch {}
        return ($ans -eq 'YES')
    }

    if (-not ('PxTool.Msg' -as [type])) {
        $sig = @"
[DllImport("user32.dll", CharSet=CharSet.Unicode)]
public static extern int MessageBox(IntPtr hWnd, string lpText, string lpCaption, uint uType);
"@
        try { Add-Type -MemberDefinition $sig -Name Msg -Namespace PxTool -ErrorAction Stop | Out-Null } catch { return $false }
    }
    # MB_YESNO(4) | MB_ICONWARNING(0x30) | MB_TOPMOST(0x40000) | MB_SETFOREGROUND(0x10000)
    $r = [PxTool.Msg]::MessageBox([IntPtr]::Zero, $Text, $Title, 0x50034)
    return ($r -eq 6)
}

# ── 试试：经 127.0.0.1:$Port 能不能访问 $Url ──
#    判定标准是"请求没抛异常"。这很关键：
#    LeapVPN 本机有两个 HTTP 接口端口，拿它们当代理会返回 404/死循环重定向，
#    这两种情况 .NET 都会抛异常，正好被自动排除掉。
function Test-ProxyPort {
    param(
        [int]$Port,
        [string]$Url = $ProbeUrl,
        [int]$TimeoutMs = 6000
    )
    try {
        $req = [System.Net.HttpWebRequest]::Create($Url)
        $req.Proxy = New-Object System.Net.WebProxy("http://127.0.0.1:$Port")
        $req.Timeout = $TimeoutMs
        $req.ReadWriteTimeout = $TimeoutMs
        $resp = $req.GetResponse()
        $resp.Close()
        return $true
    } catch {
        return $false
    }
}

# ── 自动探测代理端口（LeapVPN 端口每次连接都可能变，必须现探）──
function Find-ProxyPort {
    $procs = @()
    foreach ($n in $VpnNames) {
        $procs += @(Get-Process -Name $n -ErrorAction SilentlyContinue)
    }
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
    if ($ports.Count -eq 0) { return 0 }

    foreach ($pt in $ports) {
        if (Test-ProxyPort -Port $pt) { return $pt }
    }

    # 进程端口都测不通时，退一步试试"系统代理里当前配着的端口"
    $regSrv = (Get-ItemProperty -Path $RegPath -Name ProxyServer -ErrorAction SilentlyContinue).ProxyServer
    if ($regSrv -match ':(\d+)\s*$') {
        $rp = [int]$Matches[1]
        if ($ports -notcontains $rp -and (Test-ProxyPort -Port $rp)) { return $rp }
    }
    return 0
}

function Resolve-Port {
    if ($ForcePort -gt 0) { return $ForcePort }
    return (Find-ProxyPort)
}

# ── 找 git 可执行文件 ──
# 光靠 PATH 有时会找不到（比如被别的程序调起来时），所以再按常见路径兜底找一遍。
function Resolve-GitExe {
    $c = Get-Command git -ErrorAction SilentlyContinue
    if ($c -and $c.Source) { return $c.Source }

    $cands = @(
        (Join-Path $env:ProgramFiles 'Git\cmd\git.exe'),
        (Join-Path ${env:ProgramFiles(x86)} 'Git\cmd\git.exe'),
        (Join-Path $env:LOCALAPPDATA 'Programs\Git\cmd\git.exe')
    )
    foreach ($p in $cands) { if ($p -and (Test-Path $p)) { return $p } }

    # Hermes 自带的 PortableGit 也认（在它 bootstrap 过之后会存在）
    $hermes = Join-Path $env:LOCALAPPDATA 'hermes\tools'
    if (Test-Path $hermes) {
        $d = Get-ChildItem $hermes -Filter 'git-*' -Directory -ErrorAction SilentlyContinue |
             Select-Object -First 1
        if ($d) {
            $p = Join-Path $d.FullName 'cmd\git.exe'
            if (Test-Path $p) { return $p }
        }
    }
    return ''
}

function Get-GitProxy {
    $gitExe = Resolve-GitExe
    if (-not $gitExe) { return '' }
    $v = & $gitExe config --global --get http.proxy 2>$null
    if ($null -eq $v) { return '' }
    return ([string]$v).Trim()
}

# ── 三处设置的现状 ──
function Get-ProxyState {
    $en = (Get-ItemProperty -Path $RegPath -Name ProxyEnable -ErrorAction SilentlyContinue).ProxyEnable
    return @{
        Sys = ($en -eq 1)
        Env = [bool][Environment]::GetEnvironmentVariable('HTTPS_PROXY','User')
        Git = [bool](Get-GitProxy)
    }
}

# ══════════════════ 开启 ══════════════════
function Do-On {
    Say ''
    Say '  ────────── 开启全局代理 ──────────' Cyan
    Say ''
    Say '  正在探测 LeapVPN 的代理端口，请稍候…'

    $port = Resolve-Port
    if ($port -le 0) {
        Say ''
        MsgNG '没探测到能用的代理端口。'
        Say ''
        MsgTip '十有八九是：LeapVPN 没启动，或者启动了但还没连上节点。'
        MsgTip '请打开 LeapVPN、连上一个节点（浏览器能打开 Google），再回来运行本程序。'
        Say ''
        return $false
    }

    $full = "http://127.0.0.1:$port"
    MsgOK "代理端口：127.0.0.1:$port"
    Say ''

    # ① 系统代理（浏览器、桌面软件）
    New-ItemProperty -Path $RegPath -Name ProxyEnable -Value 1 -PropertyType DWord  -Force | Out-Null
    New-ItemProperty -Path $RegPath -Name ProxyServer -Value "127.0.0.1:$port" -PropertyType String -Force | Out-Null
    $cur = (Get-ItemProperty -Path $RegPath -Name ProxyOverride -ErrorAction SilentlyContinue).ProxyOverride
    if ([string]::IsNullOrWhiteSpace($cur)) {
        New-ItemProperty -Path $RegPath -Name ProxyOverride -Value $BypassDef -PropertyType String -Force | Out-Null
    }
    Update-ProxyNow
    MsgOK '系统代理已开启（浏览器、桌面软件）'

    # ② 环境变量（pip / uv / curl 等命令行工具）
    foreach ($v in @('HTTP_PROXY','HTTPS_PROXY','ALL_PROXY')) {
        [Environment]::SetEnvironmentVariable($v, $full, 'User')
        Set-Item -Path "env:$v" -Value $full -ErrorAction SilentlyContinue
    }
    [Environment]::SetEnvironmentVariable('NO_PROXY', 'localhost,127.0.0.1,::1', 'User')
    Set-Item -Path 'env:NO_PROXY' -Value 'localhost,127.0.0.1,::1' -ErrorAction SilentlyContinue
    MsgOK '环境变量已设置（pip / uv 等）'

    # ③ git —— Hermes 安装的关键一笔（git 不认系统代理）
    $gitExe = Resolve-GitExe
    if ($gitExe) {
        & $gitExe config --global http.proxy  $full 2>$null
        & $gitExe config --global https.proxy $full 2>$null
        MsgOK 'git 代理已设置（Hermes 拉代码靠这一条）'
    } else {
        MsgTip '本机没找到 git 命令，跳过'
    }

    # ④ 连通性检查
    Say ''
    Say '  ────────── 连通性检查 ──────────' Cyan
    $allOk  = $true
    $checks = @(
        @{ n = 'Google（判断代理是否真通）' ; u = 'https://www.google.com/generate_204' },
        @{ n = 'GitHub（Hermes 源码）'      ; u = 'https://github.com' },
        @{ n = 'PyPI（Python 依赖包）'      ; u = 'https://pypi.org/simple/' }
    )
    foreach ($c in $checks) {
        if (Test-ProxyPort -Port $port -Url $c.u -TimeoutMs 12000) { MsgOK "$($c.n)：通" }
        else { MsgNG "$($c.n)：连不上"; $allOk = $false }
    }

    Say ''
    if ($allOk) {
        Say '  ═══════════ 设置完成 ═══════════' Green
        Say ''
        MsgTip '重要：如果 Hermes 安装程序现在还开着，请先把它完全关掉，再重新打开。'
        MsgTip '      不重开的话它读不到新设置，还是会一样慢。'
        MsgTip '用完之后：回菜单选 [2] 恢复，再关窗口。菜单上的红字会一直提醒你。'
    } else {
        Say '  ══════ 已设置，但有连不通的 ══════' Yellow
        Say ''
        MsgTip '代理参数已经写好了，但外网连不通 —— 多半是 LeapVPN 的节点掉了。'
        MsgTip '请打开 LeapVPN 确认已连上，再重新运行本程序。'
    }
    Say ''
    return $true
}

# ══════════════════ 关闭 ══════════════════
function Do-Off {
    Say ''
    Say '  ────────── 恢复默认（关闭代理）──────────' Cyan
    Say ''

    New-ItemProperty -Path $RegPath -Name ProxyEnable -Value 0 -PropertyType DWord -Force | Out-Null
    Update-ProxyNow
    MsgOK '系统代理已关闭'

    $had = $false
    foreach ($v in @('HTTP_PROXY','HTTPS_PROXY','ALL_PROXY','NO_PROXY')) {
        if ([Environment]::GetEnvironmentVariable($v,'User')) { $had = $true }
        [Environment]::SetEnvironmentVariable($v, $null, 'User')
        Remove-Item -Path "env:$v" -ErrorAction SilentlyContinue
    }
    if ($had) { MsgOK '环境变量已清除' } else { MsgTip '环境变量本来就是空的' }

    $gitExe = Resolve-GitExe
    if ($gitExe) {
        & $gitExe config --global --unset http.proxy  2>$null
        & $gitExe config --global --unset https.proxy 2>$null
        MsgOK 'git 代理已清除'
    } else {
        MsgNG '本机没找到 git 命令，git 代理没能清干净'
        MsgTip ('请手动删掉 ' + (Join-Path $env:USERPROFILE '.gitconfig') + ' 里的 http.proxy / https.proxy 两行')
    }

    Say ''
    MsgTip '现在是直连状态，一切恢复原样。'
    MsgTip '提醒：直连打不开 Google，这是正常的。'
    Say ''
}

# ══════════════════ 查状态 ══════════════════
function Show-Status {
    Say ''
    Say '  ────────── 当前状态 ──────────' Cyan
    Say ''

    $en = (Get-ItemProperty -Path $RegPath -Name ProxyEnable -ErrorAction SilentlyContinue).ProxyEnable
    $sv = (Get-ItemProperty -Path $RegPath -Name ProxyServer -ErrorAction SilentlyContinue).ProxyServer
    if ($en -eq 1) { MsgOK "系统代理：已开启（$sv）" } else { MsgTip '系统代理：未开启' }

    $h = [Environment]::GetEnvironmentVariable('HTTPS_PROXY','User')
    if ($h) { MsgOK "环境变量：$h" } else { MsgTip '环境变量：未设置' }

    $g = Get-GitProxy
    if ($g) { MsgOK "git 代理：$g" } else { MsgTip 'git 代理：未设置' }

    Say ''
    if (Get-Process -Name 'leapvpn' -ErrorAction SilentlyContinue) { MsgOK 'LeapVPN 进程：运行中' }
    else { MsgNG 'LeapVPN 进程：没在运行' }

    $p = Resolve-Port
    if ($p -gt 0) { MsgOK "VPN 代理端口：127.0.0.1:$p（可正常使用）" }
    else { MsgNG 'VPN 代理端口：探测不到（多半是没连上节点）' }
    Say ''
}

# ══════════════════ 体检 ══════════════════
# On        = 我们设的代理还开着吗
# VpnUp     = LeapVPN 的代理端口现在能用吗
# Port      = 现在实际可用的端口
# SetPort   = 设置里记着的端口
# PortStale = 两者对不上（LeapVPN 换了端口）
function Get-HealthReport {
    $st = Get-ProxyState
    $on = ($st.Env -or $st.Git)

    $h = [Environment]::GetEnvironmentVariable('HTTPS_PROXY','User')
    $setPort = 0
    if ($h -match ':(\d+)\s*$') { $setPort = [int]$Matches[1] }

    $port = 0
    if ($on) { $port = Resolve-Port }

    return @{
        On        = $on
        VpnUp     = ($port -gt 0)
        Port      = $port
        SetPort   = $setPort
        PortStale = ($on -and $port -gt 0 -and $setPort -gt 0 -and $setPort -ne $port)
    }
}

function Write-HealthLine {
    $r = Get-HealthReport

    Write-Host '   状态：' -ForegroundColor DarkGray -NoNewline

    if (-not $r.On) {
        Write-Host '[ ] 代理未开启（直连）' -ForegroundColor DarkGray -NoNewline
        if (Get-Process -Name 'leapvpn' -ErrorAction SilentlyContinue) {
            Write-Host ' · LeapVPN 在运行' -ForegroundColor DarkGray
        } else {
            Write-Host ' · LeapVPN 未运行' -ForegroundColor DarkGray
        }
        return
    }

    if (-not $r.VpnUp) {
        Write-Host '[!] 代理开着，但 VPN 端口探测不到' -ForegroundColor Red -NoNewline
        Write-Host '  ← 设置已失效，选 [4] 修复' -ForegroundColor Red
        return
    }

    if ($r.PortStale) {
        Write-Host "[!] 端口变了：设置里是 $($r.SetPort)，实际是 $($r.Port)" -ForegroundColor Yellow -NoNewline
        Write-Host '  ← 选 [4] 修复' -ForegroundColor Yellow
        return
    }

    Write-Host "[$([char]0x221A)] 代理已开启 · VPN 正常（端口 $($r.Port)）" -ForegroundColor Green
}

# ── 大字红字提醒：只在"代理还开着"的时候亮出来 ──
function Write-Reminder {
    $st = Get-ProxyState
    Write-Host ''
    if (-not ($st.Env -or $st.Git)) {
        Write-Host '     （当前没有残留的代理设置，随时可以关窗口）' -ForegroundColor DarkGray
        return
    }
    Write-Host '   ############################################################' -ForegroundColor Red
    Write-Host ''
    Write-Host '        ★★   用 完 记 得 回 来 选  [2]  恢 复   ★★' -ForegroundColor White -BackgroundColor DarkRed
    Write-Host ''
    Write-Host '        不恢复的话，pip / git 这些命令会连不上网' -ForegroundColor Red
    Write-Host ''
    Write-Host '   ############################################################' -ForegroundColor Red
}

# ══════════════════ 一键修复 ══════════════════
function Do-Repair {
    Say ''
    Say '  ────────── 一键修复 ──────────' Cyan
    Say ''
    Say '  正在重新探测 VPN 端口，请稍候…'

    $r = Get-HealthReport

    # 情况一：本来就没开代理，没什么可修的
    if (-not $r.On) {
        Say ''
        MsgOK '检查完毕：系统里没有残留的代理设置。'
        MsgTip '当前是直连状态，不需要修复。'
        Say ''
        MsgTip '如果你是想"开代理"，请回菜单选 [1]。'
        Say ''
        return
    }

    # 情况二：代理开着，但 VPN 端口没了 —— 这状态最坑，pip/git 会静默坏掉
    if (-not $r.VpnUp) {
        Say ''
        MsgNG '代理开着，但探测不到可用的 VPN 端口。'
        MsgTip '现在 pip / git 这类命令是连不上网的（而且报错很难懂）。'
        Say ''
        $ask = "代理设置还留在系统里，但 LeapVPN 的端口探测不到。`n`n" +
               "这会让 pip / git 之类的命令连不上网。`n`n" +
               "要现在把代理关掉吗？`n（等你连上 LeapVPN 之后，再运行本程序选 [1] 即可）"
        if (Show-Ask -Text $ask -Title '一键修复') {
            Do-Off
            Say ''
            MsgOK '已关掉，问题解除。'
        } else {
            MsgTip '已保留。等 LeapVPN 连上后再选 [4]，就能自动修好。'
        }
        Say ''
        return
    }

    # 情况三：VPN 通着 —— 用当前端口重写一遍（端口变了也能刷正）
    if ($r.PortStale) {
        MsgTip "端口变了：设置里是 $($r.SetPort)，现在是 $($r.Port)"
    } else {
        MsgTip "端口没变（$($r.Port)），重新写一遍确保三处一致"
    }
    Say ''
    [void](Do-On)
    Say ''
    MsgOK '修复完成。'
    Say ''
}

# ══════════════════ 菜单 ══════════════════
function Confirm-Exit {
    $st = Get-ProxyState
    if (-not ($st.Env -or $st.Git)) { return $true }   # 没留尾巴，直接退

    $msg = @"
代理还开着，确定要退出吗？

  「是」 = 退出，但代理留着（下次想关就跑一次本程序选 2）
  「否」 = 先关掉代理再退出
"@
    if (Show-Ask -Text $msg -Title '提醒：全局代理还开着') { return $true }
    Do-Off | Out-Null
    return $true
}

function Show-Menu {
    while ($true) {
        Clear-Host
        Write-Host ''
        Write-Host '   ========================================================' -ForegroundColor DarkCyan
        Write-Host ''
        Write-Host '              全 局 代 理 开 关   (LeapVPN)' -ForegroundColor White
        Write-Host ''
        Write-Host '   ========================================================' -ForegroundColor DarkCyan
        Write-Host ''
        Write-Host '     [1]   开启全局代理    （下载走 VPN）' -ForegroundColor Gray
        Write-Host '     [2]   恢复默认        （关闭代理）' -ForegroundColor Gray
        Write-Host '     [3]   查看当前状态' -ForegroundColor Gray
        Write-Host '     [4]   一键修复        （端口变了 / 断线了）' -ForegroundColor Gray
        Write-Host '     [0]   退出' -ForegroundColor Gray
        Write-Host ''
        Write-Host '   --------------------------------------------------------' -ForegroundColor DarkGray
        Write-HealthLine
        Write-Host '   --------------------------------------------------------' -ForegroundColor DarkGray

        Write-Reminder

        Write-Host ''
        Write-Host '    装 Hermes 之前：先选 [1]，再把 Hermes 安装' -ForegroundColor DarkGray
        Write-Host '    程序完全关掉、重新打开，就不慢了。' -ForegroundColor DarkGray
        Write-Host ''

        $ch = Read-Host '   请输入数字后回车'

        switch ($ch) {
            '1' { Clear-Host; [void](Do-On);    Wait-Key }
            '2' { Clear-Host; Do-Off;           Wait-Key }
            '3' { Clear-Host; Show-Status;      Wait-Key }
            '4' { Clear-Host; Do-Repair;        Wait-Key }
            '0' { if (Confirm-Exit) { return } }
            default { }
        }
    }
}

switch ($Action) {
    'on'       { Do-On | Out-Null }
    'off'      { Do-Off }
    'status'   { Show-Status }
    'menu'     { Show-Menu }
}
