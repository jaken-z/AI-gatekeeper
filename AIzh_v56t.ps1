# =========================================================================
#  AI 本地栈控制中心  v5.6t (中文版构建)
#  Baseline: v4.7 (verified running on this machine)
#  This build is 100% ASCII on purpose:
#    - if it runs  -> the v48 CJK build failed due to encoding
#    - if it fails -> real logic bug in my code, 需要 different fix
#  Save: any encoding (ASCII / UTF-8 / UTF-8 BOM all fine)
#  Run : as Administrator
# =========================================================================
#Requires -RunAsAdministrator
param(
    [switch]$SelfTest
)

$ErrorActionPreference = "Continue"

$Script:SelfTestMode = [bool]$SelfTest.IsPresent

# =========================================================================
$Script:ConfigFile = Join-Path $PSScriptRoot "paths.json"
$Script:EnableHardLinkExpand = $false
# v5.6a: config-only -- 不再有 scan/process/auto 三种来源
$Script:PathSource = @{ Engine = "config"; Panel = "config" }

function Update-LegacyConfigKeys {
    param($Config)
    if (-not $Config) { return $false }
    $changed = $false
    # 旧键名 -> 通用键名 (读旧写新, 现有 paths.json 无需手工重填)
    foreach ($pair in @(
        @{ New = 'engine'; Old = 'ollama' },
        @{ New = 'panel';  Old = 'vscode' }
    )) {
        $old = $Config.PSObject.Properties[$pair.Old]
        if ($old -and -not $Config.PSObject.Properties[$pair.New]) {
            $Config | Add-Member -MemberType NoteProperty -Name $pair.New -Value ([object[]]@($old.Value)) -Force
            $Config.PSObject.Properties.Remove($pair.Old)
            $changed = $true
        }
    }
    # 78/79: model_dir / engine_env 已不再由中间件管理, 旧配置里的死键顺手清掉
    foreach ($dead in @('model_dir', 'engine_env', 'fw_engine_rule', 'fw_panel_rule')) {
        if ($Config.PSObject.Properties[$dead]) {
            $Config.PSObject.Properties.Remove($dead)
            $changed = $true
        }
    }
        $oldPort = $Config.PSObject.Properties['api_port']
        if ($oldPort -and -not $Config.PSObject.Properties['engine_port']) {
            $Config | Add-Member -MemberType NoteProperty -Name 'engine_port' -Value ([int]$oldPort.Value) -Force
            $Config.PSObject.Properties.Remove('api_port')
            $changed = $true
        }
    return $changed
}

function Load-PathConfig {
    if (-not (Test-Path -LiteralPath $Script:ConfigFile)) { return $null }
    try {
        return (Get-Content -LiteralPath $Script:ConfigFile -Raw -Encoding UTF8 | ConvertFrom-Json)
    } catch {
        Write-Host "[!] paths.json 解析失败，已忽略。" -ForegroundColor Yellow
        return $null
    }
}

function Save-PathConfig {
    param($Config)
    try {
        $json = $Config | ConvertTo-Json -Depth 4
        [System.IO.File]::WriteAllText($Script:ConfigFile, $json,
            (New-Object System.Text.UTF8Encoding($false)))
        return $true
    } catch {
        Write-Host "[!] paths.json 写入失败: $($_.Exception.Message)" -ForegroundColor Red
        return $false
    }
}

function Expand-HardLinks {
    param([string]$Path)
    $out = @()
    if (-not $Script:EnableHardLinkExpand) { return $out }
    if (-not (Test-Path -LiteralPath $Path)) { return $out }
    try {
        $lines = & fsutil hardlink list $Path 2>$null
        foreach ($l in $lines) { if ($l -and (Test-Path -LiteralPath $l)) { $out += $l } }
    } catch { }
    return $out
}

function Test-ExePath {
    param([string]$Path, [string]$Kind)
    $r = [PSCustomObject]@{
        Path = $Path; Ok = $false; Level = 0; Msg = ""
        Real = $Path; HardLinks = @(); Warn = ""
    }
    if (-not $Path)                          { $r.Msg = "empty path";        return $r }
    if (-not (Test-Path -LiteralPath $Path)) { $r.Msg = "路径不存在";    return $r }
    $r.Level = 1
    if ($Path -notmatch '\.exe$')            { $r.Msg = "not an .exe";       return $r }
    $r.Level = 2
    $item = Get-Item -LiteralPath $Path -Force -ErrorAction SilentlyContinue
    if ($item -and $item.LinkType -and $item.Target) {
        $t = @($item.Target)[0]
        if ($t -and (Test-Path -LiteralPath $t)) { $r.Real = $t }
    }
    $r.Level = 3
    if ($item -and $item.VersionInfo -and $item.VersionInfo.ProductName) {
        $r.Warn = "product: $($item.VersionInfo.ProductName.Trim())"
    } else { $r.Warn = "no version info (common for portable)" }
    $r.Level = 4
    $r.HardLinks = @(Expand-HardLinks $r.Real)
    $r.Level = 5
    if ($Kind -eq "Engine") {
        try {
            $out = & $r.Real list 2>$null
            if ($LASTEXITCODE -eq 0 -or $out) { $r.Ok = $true; $r.Level = 6 }
            else { $r.Msg = "found but cannot run (list empty)" }
        } catch { $r.Msg = "found but call failed" }
    } else {
        $pn = if ($Kind -eq "Panel") { [System.IO.Path]::GetFileNameWithoutExtension($r.Real) } else { $Kind }
        $proc = Get-CimInstance Win32_Process -Filter "Name = '$pn.exe'" -ErrorAction SilentlyContinue |
                 Select-Object -First 1
        if ($proc -and $proc.ExecutablePath -and ($proc.ExecutablePath.ToLower() -eq $r.Real.ToLower())) {
            $r.Ok = $true; $r.Level = 6
        } elseif ($proc) {
            $r.Msg = "running but path differs (unverified)"; $r.Level = 5
        } else {
            $r.Msg = "not running, treated as exists"; $r.Ok = $true; $r.Level = 5
        }
    }
    return $r
}

$Script:PathConfig = Load-PathConfig
if (Update-LegacyConfigKeys $Script:PathConfig) { $null = Save-PathConfig $Script:PathConfig }
$Script:EngineManual = @(); $Script:PanelManual = @()
if ($Script:PathConfig) {
    if ($Script:PathConfig.engine) { $Script:EngineManual = @($Script:PathConfig.engine) }
    if ($Script:PathConfig.panel) { $Script:PanelManual = @($Script:PathConfig.panel) }
}

# v5.6a: no discovery / no scan / no process grab -- config only, no fallback
$Script:EngineExes = @()
$Script:PanelExes = @()
foreach ($p in $Script:EngineManual) { if ($p -and (Test-Path -LiteralPath $p)) { $Script:EngineExes += [string]$p } }
foreach ($p in $Script:PanelManual) { if ($p -and (Test-Path -LiteralPath $p)) { $Script:PanelExes += [string]$p } }

$Script:EngineExe  = if ($Script:EngineExes.Count -gt 0) { [string]$Script:EngineExes[0] } else { $null }
$Script:PanelPath = if ($Script:PanelExes.Count -gt 0) { [string]$Script:PanelExes[0] } else { $null }

$LogDir = Join-Path $PSScriptRoot "logs"
if (-not (Test-Path -LiteralPath $LogDir)) { New-Item -ItemType Directory -Path $LogDir -Force | Out-Null }
# --- 引擎对接槽位 (v5.6t): 全部来自 paths.json ---
# 无出厂缺省: 配置里填什么就传什么, 没填就裸启动 (引擎侧参数不由中间件代劳)
$Script:EngineArgs     = if ($Script:PathConfig -and $Script:PathConfig.engine_args)     { @($Script:PathConfig.engine_args | ForEach-Object { [string]$_ }) } else { @() }
$Script:ApiPort        = if ($Script:PathConfig -and $Script:PathConfig.engine_port)        { [int]$Script:PathConfig.engine_port }          else { $null }
$Script:HealthEndpoint = if ($Script:PathConfig -and $Script:PathConfig.health_endpoint) { [string]$Script:PathConfig.health_endpoint } else { "/api/tags" }
$Script:ProcessNames   = if ($Script:PathConfig -and $Script:PathConfig.process_name)    { @($Script:PathConfig.process_name) }        else { @() }

# --- 防火墙规则名前缀 (v5.6t): 锁死, 不可配置 ---
# 前缀不开放给用户: "AI_Block_*" 同时是三样东西的唯一依据 ——
#   菜单 5 的删除 / README 手工脚本 / 状态栏计数
#   前缀一旦可改, 三者同时失效, 孤儿规则将无法找回
$Script:RulePrefix = "AI_Block_"
# 拦截目标 (104 节): net_rules 是唯一依据, 没有就不拦, 不回退 engine/panel
$Script:NetRules = @()
if ($Script:PathConfig -and $Script:PathConfig.net_rules) {
    foreach ($r in @($Script:PathConfig.net_rules)) {
        if ($r) { $Script:NetRules += [string]$r }
    }
}


# --- 插件加载 (v5.6t): 静默加载, 单个插件出错不影响主控台 ---
$Script:PluginDir = Join-Path $PSScriptRoot "plugins"
if (Test-Path -LiteralPath $Script:PluginDir) {
    Get-ChildItem -LiteralPath $Script:PluginDir -Filter *.ps1 -File -ErrorAction SilentlyContinue | ForEach-Object {
        try { . $_.FullName } catch { }
    }
}




# =========================================================================
#  2. SelfTest (list only, no changes)
# =========================================================================
function Invoke-SelfTest {
    Write-Host ""
    Write-Host "============= 自检 : 仅列出，不修改 =============" -ForegroundColor Cyan

    Write-Host ""
    Write-Host "[AI 引擎 exe]" -ForegroundColor Yellow
    if ($Script:EngineExes.Count -eq 0) {
        Write-Host "  未找到" -ForegroundColor Red
    } else {
        Write-Host "  来源: $($Script:PathSource['Engine'])" -ForegroundColor DarkGray
        $Script:EngineExes | ForEach-Object { Write-Host "  $($_)" -ForegroundColor Green }
    }

    Write-Host ""
    Write-Host "[对话面板 exe]" -ForegroundColor Yellow
    if ($Script:PanelExes.Count -eq 0) {
        Write-Host "  未找到" -ForegroundColor Red
    } else {
        Write-Host "  来源: $($Script:PathSource['Panel'])" -ForegroundColor DarkGray
        $Script:PanelExes | ForEach-Object { Write-Host "  $($_)" -ForegroundColor Green }
        $bad = @($Script:PanelExes | Where-Object { $_ -match '\.(cmd|bat)$' })
        if ($bad.Count -gt 0) {
            Write-Host "  [!] 这是启动脚本而非 exe - 规则会失效" -ForegroundColor Red
        }
    }

    Write-Host ""
    Write-Host "[防火墙规则]" -ForegroundColor Yellow
    $r = Get-NetFirewallRule -DisplayName "$($Script:RulePrefix)*" -ErrorAction SilentlyContinue
    if ($r) {
        $r | ForEach-Object {
            $c = if ($_.Enabled -eq 'True') { "Red" } else { "DarkGray" }
            Write-Host "  $($_.DisplayName)  Enabled=$($_.Enabled)" -ForegroundColor $c
        }
    } else { Write-Host "  $($Script:RulePrefix)* : 不存在" -ForegroundColor DarkGray }

    Write-Host ""
    Write-Host "[AI 引擎 进程]" -ForegroundColor Yellow
    $names = @($Script:ProcessNames)
    if ($names.Count -gt 0) {
        foreach ($n in $names) {
            $p = @(Get-Process -Name $n -ErrorAction SilentlyContinue)
            if ($p.Count -gt 0) { $p | ForEach-Object { Write-Host "  $($_.ProcessName)  PID $($_.Id)" -ForegroundColor Green } }
        }
    } elseif ($Script:ApiPort -and (Test-PortOpen -Port $Script:ApiPort)) {
        Write-Host "  端口 $Script:ApiPort 有服务在监听" -ForegroundColor Green
    } else { Write-Host "  无 AI 引擎 进程正在运行" -ForegroundColor DarkGray }

    Write-Host ""
    Write-Host "[回环]" -ForegroundColor Yellow
    if (-not $Script:ApiPort) {
        Write-Host "  paths.json 未填 engine_port - 已跳过" -ForegroundColor DarkGray
    } else {
        try {
            $null = Invoke-WebRequest -Uri "http://127.0.0.1:$Script:ApiPort$Script:HealthEndpoint" -Method Get -TimeoutSec 3 -UseBasicParsing
            Write-Host "  127.0.0.1:$Script:ApiPort OK (HTTP 200)" -ForegroundColor Green
        } catch { Write-Host "  127.0.0.1:$Script:ApiPort no response (service down?)" -ForegroundColor Red }
    }

    Write-Host ""
    Write-Host "======================================================" -ForegroundColor Cyan
    Write-Host "确认以上路径后，不带 -SelfTest 重新运行。" -ForegroundColor Cyan
    Write-Host ""
}

if ($SelfTest) { Invoke-SelfTest; return }

# =========================================================================
#  3. Status
# =========================================================================
function Get-SystemStatus {
    $rules = @(Get-NetFirewallRule -DisplayName "$($Script:RulePrefix)*" -ErrorAction SilentlyContinue)
    $active = @($rules | Where-Object { $_.Enabled -eq 'True' })
    if ($active.Count -gt 0) {
        $netStatus = "[LOCK] air-gapped ($($active.Count) rules)"; $netColor = "Red"
    } else {
        $netStatus = "[OPEN] normal"; $netColor = "Green"
    }

    $engineStatus = "[STOPPED]"; $engineColor = "Red"
    if (-not $Script:ApiPort) {
        $engineStatus = "[未配置端口] 未填写 engine_port"; $engineColor = "Red"
    } elseif (Test-EngineRunning) {
        if (Test-PortOpen -Port $Script:ApiPort) { $engineStatus = "[Run] $Script:ApiPort"; $engineColor = "Green" }
        else { $engineStatus = "[停止] 无响应"; $engineColor = "Yellow" }
    }

    $panelStatus = "[CLOSED]"; $panelColor = "Red"
    $panelProcName = if ($Script:PanelPath) { [System.IO.Path]::GetFileNameWithoutExtension($Script:PanelPath) } else { $null }
    if ($panelProcName -and (Get-Process -Name $panelProcName -ErrorAction SilentlyContinue)) {
        $panelStatus = "[RUNNING]"; $panelColor = "Green"
    }

    $gpuInfo = "no nvidia data"
    if (Get-Command nvidia-smi -ErrorAction SilentlyContinue) {
        $smi = nvidia-smi --query-gpu=memory.used,memory.total --format=csv,noheader,nounits
        if ($smi) { $a = ($smi -split ','); $gpuInfo = "VRAM $($a[0].Trim()) / $($a[1].Trim()) MiB" }
    }
    $ramFree = [math]::Round((Get-CimInstance Win32_OperatingSystem).FreePhysicalMemory / 1MB, 1)

    return [PSCustomObject]@{
        NetStatus = $netStatus; NetColor = $netColor
        EngineStatus = $engineStatus; EngineColor = $engineColor
        PanelStatus = $panelStatus; PanelColor = $panelColor
        GpuInfo = $gpuInfo; RamInfo = "free ${ramFree} GB"
    }
}

# =========================================================================
#  4. Menu (table driven, single source of truth)
# =========================================================================
$MenuActions = @(
    @{ Group = "引擎";    Text = "启动 AI 引擎";              Action = { Start-Engine } }
    @{ Group = "引擎";    Text = "停止 AI 引擎（清显存）";   Action = { Stop-Engine } }
    @{ Group = "引擎";    Text = "启动对话面板";             Action = { Start-Panel } }
    @{ Group = "网络控制";   Text = "阻断外网总闸";            Action = { Toggle-Network $true } }
    @{ Group = "网络控制";   Text = "恢复网络通行";           Action = { Toggle-Network $false } }
    @{ Group = "网络控制";   Text = "测试 API 连通性";                  Action = { Test-API } }
    @{ Group = "网络控制";   Text = "添加网络规则";          Action = { Add-NetRule } }
    @{ Group = "系统配置"; Text = "指定引擎路径";       Action = { Set-ManualPath -IsEngine $true } }
    @{ Group = "系统配置"; Text = "指定面板路径";        Action = { Set-ManualPath -IsEngine $false } }
    @{ Group = "系统配置"; Text = "校验当前路径 (六层验证)";   Action = { Invoke-PathAudit } }
    @{ Group = "逃生舱";    Text = "打开文件资源管理器";             Action = { Open-Explorer } }
    @{ Group = "逃生舱";    Text = "打开任务管理器";         Action = { Open-TaskManager } }
)
$Script:MenuIndex = @{}


$DangerActions = @(
    @{ Group = "危险区域";    Text = "Force-kill AI 引擎";         Action = { Kill-Zombies } }
    @{ Group = "危险区域";    Text = "删除指定模型";            Action = { Delete-Model-Danger } }
    @{ Group = "危险区域";    Text = "拉取新模型";              Action = { Pull-Model } }
    
    
    
)

$MenuOrder  = @("引擎", "网络控制", "系统配置", "逃生舱")
$DangerGroup = "危险区域"

# 菜单编号现算: 不依赖 MenuIndex($Script:MenuIndex 在状态栏之后才构建,
# 首个渲染周期尚为空), 也不硬编码数字 —— 改菜单不会让提示失效
function Get-MenuNo {
    param([string]$Text)
    $no = 1
    foreach ($g in $MenuOrder) {
        if ($g -eq $DangerGroup) { continue }
        foreach ($it in @($MenuActions | Where-Object { $_.Group -eq $g })) {
            if ($it.Text -eq $Text) { return [string]$no }
            $no++
        }
    }
    return "?"
}

function Get-DisplayWidth {
    param([string]$s)
    if (-not $s) { return 0 }
    $w = 0
    foreach ($ch in $s.ToCharArray()) { if ([int]$ch -gt 0x1100) { $w += 2 } else { $w += 1 } }
    return $w
}

function Show-MenuGroup {
    param([string]$Group, [int]$StartNo, $Items)
    if ($null -eq $Items) { $Items = $MenuActions }
    $isDanger = ($Group -eq $DangerGroup)
    $fg = if ($isDanger) { "Red" } else { "Cyan" }
    Write-Host " [$Group]" -ForegroundColor $fg
    if ($isDanger) { Write-Host "   (以下操作需二次确认)" -ForegroundColor DarkGray }

    $items = @($Items | Where-Object { $_.Group -eq $Group })
    $no = $StartNo
    for ($i = 0; $i -lt $items.Count; $i += 2) {
        $cnt = 1
        $k1 = if ($isDanger) { Get-LetterKey $no } else { [string]$no }
        $Script:MenuIndex[$k1] = $items[$i]
        $left = "  {0}. {1}" -f $k1, $items[$i].Text

        if ($i + 1 -lt $items.Count) {
            $cnt = 2
            $k2 = if ($isDanger) { Get-LetterKey ($no + 1) } else { [string]($no + 1) }
            $Script:MenuIndex[$k2] = $items[$i + 1]
            $right = "  {0}. {1}" -f $k2, $items[$i + 1].Text
            $pad = 42 - (Get-DisplayWidth $left)
            if ($pad -lt 2) { $pad = 2 }
            Write-Host ($left + (" " * $pad) + $right) -ForegroundColor $fg
        } else {
            Write-Host $left -ForegroundColor $fg
        }
        $no += $cnt
    }
    return $no
}

function Show-Menu {
    $status = Get-SystemStatus
    Clear-Host
    Write-Host "=========================================================================" -ForegroundColor Cyan
    Write-Host "        AI 本地栈控制中心  v5.6t (中文版)" -ForegroundColor Cyan
    Write-Host "=========================================================================" -ForegroundColor Cyan
    Write-Host " 网络    : " -NoNewline; Write-Host $status.NetStatus -ForegroundColor $status.NetColor
    Write-Host " AI 引擎 : " -NoNewline; Write-Host $status.EngineStatus -ForegroundColor $status.EngineColor
    Write-Host " 对话面板 : " -NoNewline; Write-Host $status.PanelStatus -ForegroundColor $status.PanelColor
    Write-Host " 硬件    : " -NoNewline; Write-Host "[$($status.GpuInfo)] | [$($status.RamInfo)]" -ForegroundColor Magenta
    Write-Host "-------------------------------------------------------------------------" -ForegroundColor DarkGray
    Write-Host " AI 引擎 : " -NoNewline
    if ($Script:EngineExe) {
        Write-Host ("{0}  ({1} found, src: {2})" -f $Script:EngineExe, $Script:EngineExes.Count, $Script:PathSource["Engine"]) -ForegroundColor DarkGray
    } else { Write-Host ("未找到（用 {0}，或 -SelfTest）" -f (Get-MenuNo "指定引擎路径")) -ForegroundColor Red }
    Write-Host " 对话面板 : " -NoNewline
    if ($Script:PanelPath) {
        Write-Host ("{0}  ({1} found, src: {2})" -f $Script:PanelPath, $Script:PanelExes.Count, $Script:PathSource["Panel"]) -ForegroundColor DarkGray
    } else { Write-Host ("未找到（用 {0}，或 -SelfTest）" -f (Get-MenuNo "指定面板路径")) -ForegroundColor Red }
    Write-Host "=========================================================================" -ForegroundColor Cyan
    $Script:MenuIndex = @{}
    $noNormal = 1
    # v55: danger zone moved out to Show-DangerMenu (second-level menu),
    #      its data moved out to $DangerActions. normal counter -> 1..16.
    foreach ($g in $MenuOrder) {
        if ($g -eq $DangerGroup) { continue }
        $noNormal = Show-MenuGroup -Group $g -StartNo $noNormal
    }
    # v55: entry number is a FIXED far-end value, never derived and never
    #      hardcoded mid-list. It stays stable when normal items are added.
    #      CONSTRAINT: normal menu items must stay below 98.
    $Script:DangerEntryKey = "99"
    Write-Host "=========================================================================" -ForegroundColor Cyan
    Write-Host ("  {0}. >>> 危险操作区 (A-{1}) <<<" -f $Script:DangerEntryKey, (Get-LetterKey $DangerActions.Count)) -ForegroundColor Yellow
    Write-Host "  0. 退出"
    Write-Host "========================================================================="
}

# =========================================================================
#  Show-DangerMenu - danger zone as a second-level menu
#  RULES (user-dictated, not to be relaxed):
#    1. Reset $Script:MenuIndex on entry and on every redraw.
#       The main map is full-table; leftovers would leak in here.
#    2. Entry number derived by caller. Never hardcoded.
#    3. Stay in the danger list after an action (user decision).
#       The main-loop pause is NOT reached on that path, so this loop
#       must hold the screen itself or results get wiped by Clear-Host.
#       Exactly ONE blocking read, and only after a real action.
#    4. return, never break. break would kill the whole main loop.
# =========================================================================
function Show-DangerMenu {
    $Script:MenuIndex = @{}
    while ($true) {
        $Script:MenuIndex = @{}
        Clear-Host
        Write-Host "=========================================================================" -ForegroundColor Red
        Write-Host "        !!! 危险操作区 !!!  (可能终止进程 / 删除文件)" -ForegroundColor Red
        Write-Host "=========================================================================" -ForegroundColor Red
        Write-Host "  [!] 此处每一项操作都具有破坏性且不可逆。" -ForegroundColor Red
        Write-Host "      输入前请先看清每项操作顶部的红色警告。" -ForegroundColor Red
        Write-Host ""
        $null = Show-MenuGroup -Group $DangerGroup -StartNo 1 -Items $DangerActions
        Write-Host "=========================================================================" -ForegroundColor Red
        Write-Host "  0. 返回主菜单"
        Write-Host "=========================================================================" -ForegroundColor Red
        $dc = (Read-Host "危险区选择").Trim().ToUpper()
        if ($dc -eq '0') { return }
        if ($Script:MenuIndex.ContainsKey($dc)) {
            $it = $Script:MenuIndex[$dc]
            Write-Host ""
            Write-Host "  [!] 即将执行: $($it.Text)" -ForegroundColor Red
            if ((Read-Host "  回车继续，输入 n 取消") -ne "") {
                Write-Host "[!] 已取消。" -ForegroundColor DarkGray; continue
            }
            & $it.Action
            Write-Host ""
            Read-Host "完成。按回车返回危险区列表" | Out-Null
            continue
        }
        Write-Host ""; Write-Host "输入无效。" -ForegroundColor Red
    }
}

# =========================================================================
#  Specify path
#  Process names split by choice (v4.12.1 hardcoded both, causing cross-talk)
# =========================================================================
function Set-ManualPath {
    param([bool]$IsEngine)
    Write-Host ""
    Write-Host "============= 指定路径 =============" -ForegroundColor Cyan

    $isEngine = $IsEngine
    $label    = if ($isEngine) { "Engine" } else { "Panel" }
    $kind     = if ($isEngine) { "Engine" } else { "Panel" }
    # v5.6a: no process grab -- type the absolute path, or cancel
    $picked = Read-Host "  完整路径(例: D:\my-engine\engine.exe)"
    if (-not $picked) { Write-Host "[!] 已取消。" -ForegroundColor DarkGray; return }

    Write-Host ""
    Write-Host "  正在校验: $picked" -ForegroundColor Yellow
    $v = Test-ExePath -Path $picked -Kind $kind
    Write-Host "  1 文件存在   : $(if ($v.Level -ge 1) { '通过' } else { '失败 - ' + $v.Msg })"
    Write-Host "  2 是 exe     : $(if ($v.Level -ge 2) { '通过' } else { '失败 - ' + $v.Msg })"
    Write-Host "  3 链接解析   : $(if ($v.Real -ne $v.Path) { '符号链接 -> ' + $v.Real } else { '无链接 / 已解析' })"
    Write-Host "  4 版本信息   : $($v.Warn)"
    Write-Host "  5 硬链接     : $(if ($v.HardLinks.Count -gt 1) { $v.HardLinks.Count.ToString() + ' 个' } else { '已禁用' })"
    Write-Host "  6 行为检测   : $(if ($v.Ok) { '通过' } else { $v.Msg })"

    if ($v.Level -lt 2) {
        Write-Host ""
        Write-Host "[Fatal] 无法据此路径构建有效规则。保存已取消。" -ForegroundColor Red
        return
    }

    $save = @($v.Real)
    if ($v.HardLinks.Count -gt 1) {
        Write-Host ""
        Write-Host "  发现 $($v.HardLinks.Count) 个等价名称，是否全部包含？" -ForegroundColor Yellow
        if ((Read-Host "  （回车 = 否）") -in @("y", "Y")) { $save = $v.HardLinks }
    }

    $cfg = if ($Script:PathConfig) { $Script:PathConfig }
           else { [PSCustomObject]@{ engine = @(); panel = @() } }
    $cfg | Add-Member -MemberType NoteProperty -Name $(if ($isEngine) { 'engine' } else { 'panel' }) -Value ([object[]]$save) -Force

    Write-Host ""
    if ((Read-Host "  写入 paths.json？（回车 = 是）") -ne "n") {
        if (Save-PathConfig $cfg) {
            Write-Host "[+] 已保存: $Script:ConfigFile" -ForegroundColor Green
            Write-Host "  已记录  : $($save[0])" -ForegroundColor DarkGray
            Write-Host "  状态    : level $($v.Level)/6  $(if ($v.Ok) { '可用' } else { $v.Msg + ' （路径已记录）' })" -ForegroundColor DarkGray
        }
    } else { Write-Host "[!] 未保存（仅内存中）。" -ForegroundColor Yellow }

    $save = @($save)
    if ($isEngine) { $Script:EngineExes = $save; $Script:EngineExe = $save[0] }
    else           { $Script:PanelExes = $save; $Script:PanelPath = $save[0] }
    $Script:PathSource[$label] = "manual"
}

function Invoke-PathAudit {
    Write-Host ""
    Write-Host "============= 路径校验 =============" -ForegroundColor Cyan
    foreach ($k in @(
        @{ Label = "AI 引擎"; Kind = "Engine"; List = $Script:EngineExes; Src = $Script:PathSource["Engine"] },
        @{ Label = "对话面板"; Kind = "Panel"; List = $Script:PanelExes; Src = $Script:PathSource["Panel"] }
    )) {
        Write-Host ""
        Write-Host "[$($k.Label)]  来源: $($k.Src)" -ForegroundColor Yellow
        if (-not $k.List -or $k.List.Count -eq 0) {
            Write-Host "  未找到" -ForegroundColor Red
            continue
        }
        foreach ($p in $k.List) {
            $v = Test-ExePath -Path $p -Kind $k.Kind
            $c = if ($v.Ok) { "Green" } elseif ($v.Level -ge 2) { "Yellow" } else { "Red" }
            Write-Host "  $p" -ForegroundColor $c
            Write-Host "     level $($v.Level)/6  $(if ($v.Ok) { '可用' } else { $v.Msg })" -ForegroundColor $c
            if ($v.Real -ne $v.Path) { Write-Host "     符号链接目标: $($v.Real)" -ForegroundColor DarkGray }
        }
    }
    Write-Host ""
}

# =========================================================================
#  Engine ops
# =========================================================================
function Start-Panel {
    if ($Script:PanelPath -and (Test-Path -LiteralPath $Script:PanelPath)) {
        Write-Host ""; Write-Host "[+] 正在启动对话面板..." -ForegroundColor Yellow
        Start-Process -FilePath $Script:PanelPath `
            -RedirectStandardOutput "$LogDir\panel_out.log" `
            -RedirectStandardError  "$LogDir\panel_err.log"
    } else {
        Write-Host ""; Write-Host ("[!] 未找到对话面板 - 请用菜单 {0}。" -f (Get-MenuNo "指定面板路径")) -ForegroundColor Yellow
    }
}

function Get-LetterKey {
    param([int]$n)
    if ($n -le 26) { return [string][char](64 + $n) }
    $f = [char](64 + [math]::Floor(($n - 1) / 26))
    $s = [char](64 + (($n - 1) % 26) + 1)
    return "$f$s"
}

function Test-PortOpen {
    param([string]$IP = "127.0.0.1", [int]$Port, [int]$TimeoutMs = 700)
    $tcp = $null
    try {
        $tcp = New-Object System.Net.Sockets.TcpClient
        $ar  = $tcp.BeginConnect($IP, $Port, $null, $null)
        if ($ar.AsyncWaitHandle.WaitOne($TimeoutMs) -and $tcp.Connected) {
            $tcp.EndConnect($ar)
            return $true
        }
        return $false
    } catch { return $false }
    finally { if ($tcp) { $tcp.Close(); $tcp.Dispose() } }
}

function Test-EngineRunning {
    $names = @($Script:ProcessNames)
    if ($names.Count -gt 0) {
        foreach ($n in $names) { if (Get-Process -Name $n -ErrorAction SilentlyContinue) { return $true } }
        return $false
    }
    if (-not $Script:ApiPort) { return $false }
    return (Test-PortOpen -Port $Script:ApiPort)
}

function Check-VramSafety {
    if (-not (Get-Command nvidia-smi -ErrorAction SilentlyContinue)) { return }
    try {
        $smi = nvidia-smi --query-gpu=memory.used,memory.total --format=csv,noheader,nounits 2>$null | Select-Object -First 1
        if (-not $smi) { return }
        $a = ($smi -split ',')
        if ($a.Count -lt 2) { return }
        $used  = [int]$a[0].Trim()
        $total = [int]$a[1].Trim()
        if ($total -gt 0 -and ($used / $total) -gt 0.85) {
            Write-Host "[警告] 显存占用过高 (>85%)，强行启动可能失败。" -ForegroundColor Red
            Write-Host "       ($used / $total MB)" -ForegroundColor Yellow
            Start-Sleep -Seconds 2
        }
    } catch { }
}

function Start-Engine {
    if (Test-EngineRunning) {
        Write-Host ""; Write-Host "[!] AI 引擎已在运行。" -ForegroundColor Yellow; return
    }
    Check-VramSafety
    if (-not $Script:EngineExe) {
        Write-Host ""; Write-Host "[Fatal] 无 AI 引擎 exe。" -ForegroundColor Red; return
    }
    $exe = @($Script:EngineExe)
    if ($exe.Count -eq 0 -or -not $exe[0]) {
        Write-Host ""; Write-Host "[Fatal] 路径为空。" -ForegroundColor Red; return
    }
    $exe = [string]$exe[0]
    if (-not (Test-Path -LiteralPath $exe)) {
        Write-Host ""; Write-Host "[Fatal] 路径已失效: $exe" -ForegroundColor Red; return
    }

    if (-not $Script:ApiPort) {
        Write-Host ""; Write-Host "[Fatal] paths.json 未填 engine_port，无法验证启动。" -ForegroundColor Red; return
    }

    Write-Host ""
    Write-Host "[+] starting AI 引擎 in background..." -ForegroundColor Yellow
    Write-Host "    $exe" -ForegroundColor DarkGray
    try {
        Start-Process -FilePath $exe -ArgumentList $Script:EngineArgs -WindowStyle Hidden `
            -RedirectStandardError  "$LogDir\engine_error.log" `
            -RedirectStandardOutput "$LogDir\engine_stdout.log"
    } catch {
        Write-Host "[Fatal] 启动失败: $($_.Exception.Message)" -ForegroundColor Red
        return
    }
    $ok = $false
    for ($i = 0; $i -lt 10; $i++) {
        if (Test-PortOpen -Port $Script:ApiPort) { $ok = $true; break }
        Start-Sleep -Milliseconds 300
    }
    if (-not $ok) {
        Write-Host "[Fatal] 端口 $Script:ApiPort 10 秒后仍无响应。" -ForegroundColor Red
        Write-Host "Check: $LogDir\engine_error.log" -ForegroundColor Yellow
        return
    }
    Write-Host "[+] 已启动，端口 $Script:ApiPort 就绪" -ForegroundColor Green
}

function Stop-Engine {
    Write-Host ""; Write-Host "[+] 正在停止 AI 引擎并释放显存..." -ForegroundColor Yellow
    $names = @($Script:ProcessNames)
    if ($names.Count -gt 0) {
        foreach ($n in $names) { Stop-Process -Name $n -Force -ErrorAction SilentlyContinue }
    } else {
        if (-not $Script:ApiPort) { Write-Host "[Fatal] paths.json 未填 engine_port，无法定位进程。" -ForegroundColor Red; return }
        $pids = @(Get-NetTCPConnection -LocalPort $Script:ApiPort -State Listen -ErrorAction SilentlyContinue |
                  ForEach-Object { $_.OwningProcess } | Where-Object { $_ -gt 0 } | Select-Object -Unique)
        foreach ($id in $pids) { Stop-Process -Id $id -Force -ErrorAction SilentlyContinue }
    }
    Write-Host "[-] 已停止。" -ForegroundColor Green
}

# =========================================================================
#  Firewall (multi-target + verify after create, never silent)
# =========================================================================
function Clear-BlockRules {
    $old = @(Get-NetFirewallRule -DisplayName "$($Script:RulePrefix)*" -ErrorAction SilentlyContinue)
    if ($old.Count -gt 0) {
        $old | Remove-NetFirewallRule -ErrorAction SilentlyContinue
        Write-Host "  [OK] cleared $($old.Count) rule(s): $($Script:RulePrefix)*" -ForegroundColor Green
    } else {
        Write-Host "  [OK] 无规则可清除" -ForegroundColor Green
    }
}

function Set-BlockRules {
    if ($Script:NetRules.Count -eq 0) {
        Write-Host "  [Fatal] net_rules 为空 - 无可阻断目标。" -ForegroundColor Red
        Write-Host "          请在 paths.json 添加 net_rules，或用「添加网络规则」菜单。" -ForegroundColor Yellow
        return
    }
    $i = 0
    foreach ($exe in $Script:NetRules) {
        $i++
        $name = "${Script:RulePrefix}$i"
        if (-not (Test-Path -LiteralPath $exe)) {
            Write-Host "  [!] skipped (not found): $exe" -ForegroundColor Yellow; continue
        }
        try {
            New-NetFirewallRule -DisplayName $name -Direction Outbound `
                -Program $exe -Action Block -Profile Any -ErrorAction Stop | Out-Null
        } catch {
            Write-Host "  [Fatal] 无法创建规则: $name" -ForegroundColor Red
            Write-Host "          $($_.Exception.Message)" -ForegroundColor DarkGray
            continue
        }
        $check = Get-NetFirewallRule -DisplayName $name -ErrorAction SilentlyContinue
        if ($check -and $check.Enabled -eq 'True') {
            Write-Host "  [OK] 已阻断: $exe" -ForegroundColor Green
        } else {
            Write-Host "  [Fatal] 规则未生效: $exe" -ForegroundColor Red
        }
    }
}

function Add-NetRule {
    Write-Host ""
    Write-Host "  [!] 阻断状态下删改 paths.json 会留下孤儿规则。" -ForegroundColor Red
    Write-Host "      请到 Windows 防火墙手工删除，或用 README 里的脚本:" -ForegroundColor Red
    Write-Host '      Get-NetFirewallRule -DisplayName "AI_Block_*" | Remove-NetFirewallRule' -ForegroundColor Red
    Write-Host ""
    Write-Host "============= 添加网络规则 =============" -ForegroundColor Cyan
    Write-Host "参考格式（paths.json 里 net_rules 的一条）:" -ForegroundColor DarkGray
    Write-Host '  "D:\path\to\program.exe"' -ForegroundColor DarkGray
    Write-Host ""
    Write-Host "当前规则:" -ForegroundColor DarkGray
    if ($Script:NetRules.Count -eq 0) { Write-Host "  （空）" -ForegroundColor DarkGray }
    else { $Script:NetRules | ForEach-Object { Write-Host "  $_" -ForegroundColor DarkGray } }
    Write-Host ""
    $p = Read-Host "程序完整路径（回车 = 取消）"
    if ([string]::IsNullOrWhiteSpace($p)) { Write-Host "  已取消"; return }
    $p = $p.Trim([char]34).Trim()
    if (-not (Test-Path -LiteralPath $p)) {
        Write-Host "  [Fatal] 路径不存在: $p" -ForegroundColor Red; return
    }
    if ($Script:NetRules -contains $p) {
        Write-Host "  已存在，跳过"; return
    }
    $Script:NetRules += $p
    if (-not $Script:PathConfig) {
        $Script:PathConfig = [pscustomobject]@{ engine = @(); panel = @() }
    }
    $Script:PathConfig | Add-Member -MemberType NoteProperty -Name 'net_rules' -Value ([object[]]@($Script:NetRules)) -Force
    Save-PathConfig $Script:PathConfig
    Write-Host ""
}

function Toggle-Network($block) {
    Write-Host ""
    # 先全清再按需建: 幂等, 且无论开关都能回收历史/孤儿规则
    if ($block) {
        Write-Host "[+] 正在构建断网隔离（阻断出站）..." -ForegroundColor Yellow
        Clear-BlockRules
        Set-BlockRules
    } else {
        Write-Host "[-] 正在恢复网络..." -ForegroundColor Yellow
        Clear-BlockRules
    }
    Write-Host ""
}

# =========================================================================
#  Models
# =========================================================================

function Pull-Model {
    Write-Host ""
    Write-Host "[!] 本工具仅转发命令。" -ForegroundColor Red
    Write-Host "    不处理断网、进度或重试。" -ForegroundColor Red
    Write-Host "    下载中断请自行获取文件，放入引擎的模型目录。" -ForegroundColor Red
    Write-Host ""
    if (-not (Get-Command Invoke-PullPlugin -ErrorAction SilentlyContinue)) {
        Write-Host "[!] 当前环境未配置拉取插件。" -ForegroundColor Red
        Write-Host "    把 pull_plugin.ps1 放进 plugins\ 目录（与本脚本同级）后重试。" -ForegroundColor DarkGray
        return
    }
    $model = Read-Host "要拉取的模型名 （回车 = 取消）"
    if (-not $model) { Write-Host "[!] 已取消。" -ForegroundColor Green; return }
    Write-Host ""
    Write-Host ">>> 正在拉取: $model" -ForegroundColor Cyan
    $ok = $false
    try { $ok = Invoke-PullPlugin -ModelName $model } catch { $ok = $false }
    if (-not $ok) {
        Write-Host ""
        Write-Host "[!] 拉取失败。" -ForegroundColor Red
        Write-Host "    原因可能是：文件名拼写错误、网络断开，或当前引擎不支持在线拉取。" -ForegroundColor Red
        Write-Host "    download it yourself (HuggingFace / a mirror / network drive) and drop it into the engine models dir." -ForegroundColor Red
    }
}


function Kill-Zombies {
    Write-Host ""
    Write-Host "[!] 警告：仅强杀 AI 引擎进程。" -ForegroundColor Red
    Write-Host "    对话面板宿主不受影响。" -ForegroundColor Red
    Write-Host ""
    $names = @($Script:ProcessNames)
    if ($names.Count -gt 0) {
        Write-Host "    process_name: $($names -join ', ')" -ForegroundColor DarkGray
        $pids = @()
        foreach ($n in $names) {
            $pids += @(Get-Process -Name $n -ErrorAction SilentlyContinue | ForEach-Object { $_.Id })
        }
    } else {
        if (-not $Script:ApiPort) { Write-Host "[Fatal] paths.json 未填 engine_port，无可定位目标。" -ForegroundColor Red; return }
        Write-Host "    未设 process_name -> 按 engine_port 反查 PID $Script:ApiPort" -ForegroundColor DarkGray
        $pids = @(Get-NetTCPConnection -LocalPort $Script:ApiPort -State Listen -ErrorAction SilentlyContinue |
                  ForEach-Object { $_.OwningProcess })
    }
    $pids = @($pids | Where-Object { $_ -gt 0 } | Select-Object -Unique)
    if ($pids.Count -eq 0) {
        Write-Host "[-] 未发现引擎进程，无需终止。" -ForegroundColor Green
        return
    }
    Write-Host "    PID: $($pids -join ', ')" -ForegroundColor Yellow
    if ((Read-Host "确认？输入 YES") -ne "YES") {
        Write-Host "[!] 已取消。" -ForegroundColor Green; return
    }
    foreach ($id in $pids) { Stop-Process -Id $id -Force -ErrorAction SilentlyContinue }
    Write-Host "[-] 已终止。" -ForegroundColor Green
}

function Test-API {
    if (-not $Script:ApiPort) { Write-Host ""; Write-Host "[Fatal] paths.json 未填 engine_port。" -ForegroundColor Red; return }
    Write-Host ""; Write-Host "[+] 正在测试 127.0.0.1:$Script:ApiPort$Script:HealthEndpoint ..." -ForegroundColor Yellow
    try {
        $null = Invoke-WebRequest -Uri "http://127.0.0.1:$Script:ApiPort$Script:HealthEndpoint" -Method Get -TimeoutSec 3 -UseBasicParsing
        Write-Host "[+] 正常（HTTP 200）" -ForegroundColor Green
    } catch { Write-Host "[Fatal] connection failed! 请先启动 AI 引擎。" -ForegroundColor Red }
}

function Delete-Model-Danger {
    Write-Host ""
    Write-Host "[!] 警告：即将删除模型文件！" -ForegroundColor Red
    Write-Host "    此操作不可逆。请通过引擎或对话面板确认准确名称。" -ForegroundColor Red
    Write-Host ""
    if (-not (Get-Command Invoke-RmPlugin -ErrorAction SilentlyContinue)) {
        Write-Host "[!] 当前环境未配置删除插件。" -ForegroundColor Red
        Write-Host "    把 rm_plugin.ps1 放进 plugins\ 目录（与本脚本同级）后重试。" -ForegroundColor DarkGray
        return
    }
    $model = Read-Host "要删除的模型名 （回车 = 取消）"
    if (-not $model) { Write-Host "[!] 已取消。" -ForegroundColor Green; return }
    $confirm = Read-Host "再次输入名称以确认"
    if ($model -ne $confirm) { Write-Host ""; Write-Host "[!] 确认失败。" -ForegroundColor Green; return }
    $ok = $false
    try { $ok = Invoke-RmPlugin -ModelName $model } catch { $ok = $false }
    if ($ok) { Write-Host "[+] 已删除。" -ForegroundColor Red }
    else { Write-Host "[!] 删除失败。" -ForegroundColor Red }
}


function Open-Explorer { Start-Process explorer.exe }
function Open-TaskManager { Start-Process taskmgr.exe }

# =========================================================================
#  Main loop (table lookup)
# =========================================================================
while ($true) {
    Show-Menu
    $choice = (Read-Host "请选择").Trim().ToUpper()
    if ($choice -eq '0') {
        Write-Host ''
        Write-Host '    ___   _____  ___   ___   ___    __  ' -ForegroundColor Cyan
        Write-Host '   / __| / __\ \/ / | | __| / _ \  / /  ' -ForegroundColor Cyan
        Write-Host '   \__ \| |___ >  <  | |__ | | | |/ /   ' -ForegroundColor Cyan
        Write-Host '   |___/ \___//_/\_\ |____| \___/ /_/   ' -ForegroundColor Cyan
        Write-Host ''
        Write-Host '     [ 再见，赛博包工头！工具箱已封存。 ]' -ForegroundColor Yellow
        break
    }
    # v55: danger-zone entry. checked BEFORE table lookup (it has no Action).
    if ($choice -eq $Script:DangerEntryKey) {
        Show-DangerMenu
    } elseif ($Script:MenuIndex.ContainsKey($choice)) {
        & $Script:MenuIndex[$choice].Action
    } else {
        Write-Host ""; Write-Host "输入无效。" -ForegroundColor Red
    }
    Write-Host ""
    Write-Host "按任意键返回..."
    try { $null = $Host.UI.RawUI.ReadKey("NoEcho,IncludeKeyDown") }
    catch { Start-Sleep -Milliseconds 700 }
}