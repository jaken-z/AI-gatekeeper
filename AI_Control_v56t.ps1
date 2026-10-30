# =========================================================================
#  AI Local Stack Control Center  v5.6t (ASCII diagnostic build)
#  Baseline: v4.7 (verified running on this machine)
#  This build is 100% ASCII on purpose:
#    - if it runs  -> the v48 CJK build failed due to encoding
#    - if it fails -> real logic bug in my code, need different fix
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
# v5.6a: config-only -- no scan / no process / no auto sources
$Script:PathSource = @{ Engine = "config"; Panel = "config" }

function Update-LegacyConfigKeys {
    param($Config)
    if (-not $Config) { return $false }
    $changed = $false
    # legacy key -> generic key (read old, write new; no manual re-entry needed)
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
    # 78/79: model_dir / engine_env are no longer managed here; drop dead keys
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
        Write-Host "[!] paths.json parse failed, ignored." -ForegroundColor Yellow
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
        Write-Host "[!] paths.json write failed: $($_.Exception.Message)" -ForegroundColor Red
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
    if (-not (Test-Path -LiteralPath $Path)) { $r.Msg = "path not found";    return $r }
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
# --- Engine interface slots (v5.6t): all from paths.json ---
# no factory defaults: pass what is configured, bare-launch if unset (engine args are not our business)
$Script:EngineArgs     = if ($Script:PathConfig -and $Script:PathConfig.engine_args)     { @($Script:PathConfig.engine_args | ForEach-Object { [string]$_ }) } else { @() }
$Script:ApiPort        = if ($Script:PathConfig -and $Script:PathConfig.engine_port)        { [int]$Script:PathConfig.engine_port }          else { $null }
$Script:HealthEndpoint = if ($Script:PathConfig -and $Script:PathConfig.health_endpoint) { [string]$Script:PathConfig.health_endpoint } else { "/api/tags" }
$Script:ProcessNames   = if ($Script:PathConfig -and $Script:PathConfig.process_name)    { @($Script:PathConfig.process_name) }        else { @() }

# --- Firewall rule name prefix (v5.6t): locked, NOT configurable ---
# The prefix is never exposed to the user: "AI_Block_*" is the single source
#   for menu 5 deletion / the README manual script / the status-bar rule count.
#   If the prefix were configurable, all three break and orphans are unrecoverable.
$Script:RulePrefix = "AI_Block_"
# block targets (104): net_rules is the only source; empty = block nothing, no engine/panel fallback
$Script:NetRules = @()
if ($Script:PathConfig -and $Script:PathConfig.net_rules) {
    foreach ($r in @($Script:PathConfig.net_rules)) {
        if ($r) { $Script:NetRules += [string]$r }
    }
}


# --- Plugin loading (v5.6t): silent; one broken plugin must not break the panel ---
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
    Write-Host "============= SELFTEST : list only, no changes =============" -ForegroundColor Cyan

    Write-Host ""
    Write-Host "[AI Engine exe]" -ForegroundColor Yellow
    if ($Script:EngineExes.Count -eq 0) {
        Write-Host "  none found" -ForegroundColor Red
    } else {
        Write-Host "  source: $($Script:PathSource['Engine'])" -ForegroundColor DarkGray
        $Script:EngineExes | ForEach-Object { Write-Host "  $($_)" -ForegroundColor Green }
    }

    Write-Host ""
    Write-Host "[Chat Panel exe]" -ForegroundColor Yellow
    if ($Script:PanelExes.Count -eq 0) {
        Write-Host "  none found" -ForegroundColor Red
    } else {
        Write-Host "  source: $($Script:PathSource['Panel'])" -ForegroundColor DarkGray
        $Script:PanelExes | ForEach-Object { Write-Host "  $($_)" -ForegroundColor Green }
        $bad = @($Script:PanelExes | Where-Object { $_ -match '\.(cmd|bat)$' })
        if ($bad.Count -gt 0) {
            Write-Host "  [!] that is a launcher script, not an exe - rule would be dead" -ForegroundColor Red
        }
    }

    Write-Host ""
    Write-Host "[Firewall rules]" -ForegroundColor Yellow
    $r = Get-NetFirewallRule -DisplayName "$($Script:RulePrefix)*" -ErrorAction SilentlyContinue
    if ($r) {
        $r | ForEach-Object {
            $c = if ($_.Enabled -eq 'True') { "Red" } else { "DarkGray" }
            Write-Host "  $($_.DisplayName)  Enabled=$($_.Enabled)" -ForegroundColor $c
        }
    } else { Write-Host "  $($Script:RulePrefix)* : absent" -ForegroundColor DarkGray }

    Write-Host ""
    Write-Host "[AI Engine processes]" -ForegroundColor Yellow
    $names = @($Script:ProcessNames)
    if ($names.Count -gt 0) {
        foreach ($n in $names) {
            $p = @(Get-Process -Name $n -ErrorAction SilentlyContinue)
            if ($p.Count -gt 0) { $p | ForEach-Object { Write-Host "  $($_.ProcessName)  PID $($_.Id)" -ForegroundColor Green } }
        }
    } elseif ($Script:ApiPort -and (Test-PortOpen -Port $Script:ApiPort)) {
        Write-Host "  something is listening on port $Script:ApiPort" -ForegroundColor Green
    } else { Write-Host "  no AI Engine process running" -ForegroundColor DarkGray }

    Write-Host ""
    Write-Host "[Loopback]" -ForegroundColor Yellow
    if (-not $Script:ApiPort) {
        Write-Host "  engine_port not set in paths.json - skipped" -ForegroundColor DarkGray
    } else {
        try {
            $null = Invoke-WebRequest -Uri "http://127.0.0.1:$Script:ApiPort$Script:HealthEndpoint" -Method Get -TimeoutSec 3 -UseBasicParsing
            Write-Host "  127.0.0.1:$Script:ApiPort OK (HTTP 200)" -ForegroundColor Green
        } catch { Write-Host "  127.0.0.1:$Script:ApiPort no response (service down?)" -ForegroundColor Red }
    }

    Write-Host ""
    Write-Host "======================================================" -ForegroundColor Cyan
    Write-Host "Confirm paths above, then run without -SelfTest." -ForegroundColor Cyan
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
        $engineStatus = "[NO PORT] engine_port not set"; $engineColor = "Red"
    } elseif (Test-EngineRunning) {
        if (Test-PortOpen -Port $Script:ApiPort) { $engineStatus = "[Run] $Script:ApiPort"; $engineColor = "Green" }
        else { $engineStatus = "[Stop] No response"; $engineColor = "Yellow" }
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
    @{ Group = "engine";    Text = "Start AI Engine";              Action = { Start-Engine } }
    @{ Group = "engine";    Text = "Stop AI Engine (free VRAM)";   Action = { Stop-Engine } }
    @{ Group = "engine";    Text = "Start Chat Panel";             Action = { Start-Panel } }
    @{ Group = "network";   Text = "Block outbound";            Action = { Toggle-Network $true } }
    @{ Group = "network";   Text = "Restore network";           Action = { Toggle-Network $false } }
    @{ Group = "network";   Text = "Test API";                  Action = { Test-API } }
    @{ Group = "network";   Text = "Add network rule";          Action = { Add-NetRule } }
    @{ Group = "sysconfig"; Text = "Specify engine path";       Action = { Set-ManualPath -IsEngine $true } }
    @{ Group = "sysconfig"; Text = "Specify panel path";        Action = { Set-ManualPath -IsEngine $false } }
    @{ Group = "sysconfig"; Text = "Verify paths (6 layers)";   Action = { Invoke-PathAudit } }
    @{ Group = "escape";    Text = "Open Explorer";             Action = { Open-Explorer } }
    @{ Group = "escape";    Text = "Open Task Manager";         Action = { Open-TaskManager } }
)
$Script:MenuIndex = @{}


$DangerActions = @(
    @{ Group = "danger";    Text = "Force-kill AI Engine";         Action = { Kill-Zombies } }
    @{ Group = "danger";    Text = "Delete a model";            Action = { Delete-Model-Danger } }
    @{ Group = "danger";    Text = "Pull a model";              Action = { Pull-Model } }
    
    
    
)

$MenuOrder  = @("engine", "network", "sysconfig", "escape")
$DangerGroup = "danger"

# menu numbers are computed at render time: not from MenuIndex ($Script:MenuIndex is built
#   after the status bar, so it is empty on the first pass), never hardcoded
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
    if ($isDanger) { Write-Host "   (these require confirmation)" -ForegroundColor DarkGray }

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
    Write-Host "        AI Local Stack Control Center  v5.6t (ASCII build)" -ForegroundColor Cyan
    Write-Host "=========================================================================" -ForegroundColor Cyan
    Write-Host " network : " -NoNewline; Write-Host $status.NetStatus -ForegroundColor $status.NetColor
    Write-Host " AI Engine : " -NoNewline; Write-Host $status.EngineStatus -ForegroundColor $status.EngineColor
    Write-Host " Chat Panel : " -NoNewline; Write-Host $status.PanelStatus -ForegroundColor $status.PanelColor
    Write-Host " hardware: " -NoNewline; Write-Host "[$($status.GpuInfo)] | [$($status.RamInfo)]" -ForegroundColor Magenta
    Write-Host "-------------------------------------------------------------------------" -ForegroundColor DarkGray
    Write-Host " AI Engine : " -NoNewline
    if ($Script:EngineExe) {
        Write-Host ("{0}  ({1} found, src: {2})" -f $Script:EngineExe, $Script:EngineExes.Count, $Script:PathSource["Engine"]) -ForegroundColor DarkGray
    } else { Write-Host ("not found (use {0}, or -SelfTest)" -f (Get-MenuNo "Specify engine path")) -ForegroundColor Red }
    Write-Host " Chat Panel : " -NoNewline
    if ($Script:PanelPath) {
        Write-Host ("{0}  ({1} found, src: {2})" -f $Script:PanelPath, $Script:PanelExes.Count, $Script:PathSource["Panel"]) -ForegroundColor DarkGray
    } else { Write-Host ("not found (use {0}, or -SelfTest)" -f (Get-MenuNo "Specify panel path")) -ForegroundColor Red }
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
    Write-Host ("  {0}. >>> Danger zone (A-{1}) <<<" -f $Script:DangerEntryKey, (Get-LetterKey $DangerActions.Count)) -ForegroundColor Yellow
    Write-Host "  0. Exit"
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
        Write-Host "        !!! DANGER ZONE !!!  (can kill / delete)" -ForegroundColor Red
        Write-Host "=========================================================================" -ForegroundColor Red
        Write-Host "  [!] Every action here is destructive and irreversible." -ForegroundColor Red
        Write-Host "      Read the red warning at the top of each action before you type." -ForegroundColor Red
        Write-Host ""
        $null = Show-MenuGroup -Group $DangerGroup -StartNo 1 -Items $DangerActions
        Write-Host "=========================================================================" -ForegroundColor Red
        Write-Host "  0. Back to main menu"
        Write-Host "=========================================================================" -ForegroundColor Red
        $dc = (Read-Host "danger zone select").Trim().ToUpper()
        if ($dc -eq '0') { return }
        if ($Script:MenuIndex.ContainsKey($dc)) {
            $it = $Script:MenuIndex[$dc]
            Write-Host ""
            Write-Host "  [!] about to run: $($it.Text)" -ForegroundColor Red
            if ((Read-Host "  press Enter to proceed, or type n to cancel") -ne "") {
                Write-Host "[!] cancelled." -ForegroundColor DarkGray; continue
            }
            & $it.Action
            Write-Host ""
            Read-Host "done. press Enter to return to the danger list" | Out-Null
            continue
        }
        Write-Host ""; Write-Host "invalid input." -ForegroundColor Red
    }
}

# =========================================================================
#  Specify path
#  Process names split by choice (v4.12.1 hardcoded both, causing cross-talk)
# =========================================================================
function Set-ManualPath {
    param([bool]$IsEngine)
    Write-Host ""
    Write-Host "============= Specify path =============" -ForegroundColor Cyan

    $isEngine = $IsEngine
    $label    = if ($isEngine) { "Engine" } else { "Panel" }
    $kind     = if ($isEngine) { "Engine" } else { "Panel" }
    # v5.6a: no process grab -- type the absolute path, or cancel
    $picked = Read-Host "  full path (e.g. D:\my-engine\engine.exe)"
    if (-not $picked) { Write-Host "[!] cancelled." -ForegroundColor DarkGray; return }

    Write-Host ""
    Write-Host "  verifying: $picked" -ForegroundColor Yellow
    $v = Test-ExePath -Path $picked -Kind $kind
    Write-Host "  1 file exists : $(if ($v.Level -ge 1) { 'pass' } else { 'FAIL - ' + $v.Msg })"
    Write-Host "  2 is exe      : $(if ($v.Level -ge 2) { 'pass' } else { 'FAIL - ' + $v.Msg })"
    Write-Host "  3 link resolve: $(if ($v.Real -ne $v.Path) { 'symlink -> ' + $v.Real } else { 'no link / resolved' })"
    Write-Host "  4 version     : $($v.Warn)"
    Write-Host "  5 hardlinks   : $(if ($v.HardLinks.Count -gt 1) { $v.HardLinks.Count.ToString() + ' found' } else { 'disabled' })"
    Write-Host "  6 behavior    : $(if ($v.Ok) { 'pass' } else { $v.Msg })"

    if ($v.Level -lt 2) {
        Write-Host ""
        Write-Host "[Fatal] cannot build a valid rule from this path. Save cancelled." -ForegroundColor Red
        return
    }

    $save = @($v.Real)
    if ($v.HardLinks.Count -gt 1) {
        Write-Host ""
        Write-Host "  found $($v.HardLinks.Count) equivalent names, include all?" -ForegroundColor Yellow
        if ((Read-Host "  (enter = no)") -in @("y", "Y")) { $save = $v.HardLinks }
    }

    $cfg = if ($Script:PathConfig) { $Script:PathConfig }
           else { [PSCustomObject]@{ engine = @(); panel = @() } }
    $cfg | Add-Member -MemberType NoteProperty -Name $(if ($isEngine) { 'engine' } else { 'panel' }) -Value ([object[]]$save) -Force

    Write-Host ""
    if ((Read-Host "  write to paths.json? (enter = yes)") -ne "n") {
        if (Save-PathConfig $cfg) {
            Write-Host "[+] saved: $Script:ConfigFile" -ForegroundColor Green
            Write-Host "  recorded : $($save[0])" -ForegroundColor DarkGray
            Write-Host "  state    : level $($v.Level)/6  $(if ($v.Ok) { 'usable' } else { $v.Msg + ' (path still recorded)' })" -ForegroundColor DarkGray
        }
    } else { Write-Host "[!] not saved (in-memory only)." -ForegroundColor Yellow }

    $save = @($save)
    if ($isEngine) { $Script:EngineExes = $save; $Script:EngineExe = $save[0] }
    else           { $Script:PanelExes = $save; $Script:PanelPath = $save[0] }
    $Script:PathSource[$label] = "manual"
}

function Invoke-PathAudit {
    Write-Host ""
    Write-Host "============= Path audit =============" -ForegroundColor Cyan
    foreach ($k in @(
        @{ Label = "AI Engine"; Kind = "Engine"; List = $Script:EngineExes; Src = $Script:PathSource["Engine"] },
        @{ Label = "Chat Panel"; Kind = "Panel"; List = $Script:PanelExes; Src = $Script:PathSource["Panel"] }
    )) {
        Write-Host ""
        Write-Host "[$($k.Label)]  source: $($k.Src)" -ForegroundColor Yellow
        if (-not $k.List -or $k.List.Count -eq 0) {
            Write-Host "  not found" -ForegroundColor Red
            continue
        }
        foreach ($p in $k.List) {
            $v = Test-ExePath -Path $p -Kind $k.Kind
            $c = if ($v.Ok) { "Green" } elseif ($v.Level -ge 2) { "Yellow" } else { "Red" }
            Write-Host "  $p" -ForegroundColor $c
            Write-Host "     level $($v.Level)/6  $(if ($v.Ok) { 'usable' } else { $v.Msg })" -ForegroundColor $c
            if ($v.Real -ne $v.Path) { Write-Host "     symlink target: $($v.Real)" -ForegroundColor DarkGray }
        }
    }
    Write-Host ""
}

# =========================================================================
#  Engine ops
# =========================================================================
function Start-Panel {
    if ($Script:PanelPath -and (Test-Path -LiteralPath $Script:PanelPath)) {
        Write-Host ""; Write-Host "[+] starting Chat Panel..." -ForegroundColor Yellow
        Start-Process -FilePath $Script:PanelPath `
            -RedirectStandardOutput "$LogDir\panel_out.log" `
            -RedirectStandardError  "$LogDir\panel_err.log"
    } else {
        Write-Host ""; Write-Host ("[!] Chat Panel not found - use menu {0}." -f (Get-MenuNo "Specify panel path")) -ForegroundColor Yellow
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
            Write-Host "[WARN] VRAM high: >85% used, start may fail." -ForegroundColor Red
            Write-Host "       ($used / $total MB)" -ForegroundColor Yellow
            Start-Sleep -Seconds 2
        }
    } catch { }
}

function Start-Engine {
    if (Test-EngineRunning) {
        Write-Host ""; Write-Host "[!] AI Engine already running." -ForegroundColor Yellow; return
    }
    Check-VramSafety
    if (-not $Script:EngineExe) {
        Write-Host ""; Write-Host "[Fatal] no AI Engine exe." -ForegroundColor Red; return
    }
    $exe = @($Script:EngineExe)
    if ($exe.Count -eq 0 -or -not $exe[0]) {
        Write-Host ""; Write-Host "[Fatal] empty path." -ForegroundColor Red; return
    }
    $exe = [string]$exe[0]
    if (-not (Test-Path -LiteralPath $exe)) {
        Write-Host ""; Write-Host "[Fatal] path gone: $exe" -ForegroundColor Red; return
    }

    if (-not $Script:ApiPort) {
        Write-Host ""; Write-Host "[Fatal] engine_port not set in paths.json - cannot verify startup." -ForegroundColor Red; return
    }

    Write-Host ""
    Write-Host "[+] starting AI Engine in background..." -ForegroundColor Yellow
    Write-Host "    $exe" -ForegroundColor DarkGray
    try {
        Start-Process -FilePath $exe -ArgumentList $Script:EngineArgs -WindowStyle Hidden `
            -RedirectStandardError  "$LogDir\engine_error.log" `
            -RedirectStandardOutput "$LogDir\engine_stdout.log"
    } catch {
        Write-Host "[Fatal] start failed: $($_.Exception.Message)" -ForegroundColor Red
        return
    }
    $ok = $false
    for ($i = 0; $i -lt 10; $i++) {
        if (Test-PortOpen -Port $Script:ApiPort) { $ok = $true; break }
        Start-Sleep -Milliseconds 300
    }
    if (-not $ok) {
        Write-Host "[Fatal] Port $Script:ApiPort dead after 10s." -ForegroundColor Red
        Write-Host "Check: $LogDir\engine_error.log" -ForegroundColor Yellow
        return
    }
    Write-Host "[+] started, port $Script:ApiPort up" -ForegroundColor Green
}

function Stop-Engine {
    Write-Host ""; Write-Host "[+] stopping AI Engine and freeing VRAM..." -ForegroundColor Yellow
    $names = @($Script:ProcessNames)
    if ($names.Count -gt 0) {
        foreach ($n in $names) { Stop-Process -Name $n -Force -ErrorAction SilentlyContinue }
    } else {
        if (-not $Script:ApiPort) { Write-Host "[Fatal] engine_port not set in paths.json - cannot resolve PID." -ForegroundColor Red; return }
        $pids = @(Get-NetTCPConnection -LocalPort $Script:ApiPort -State Listen -ErrorAction SilentlyContinue |
                  ForEach-Object { $_.OwningProcess } | Where-Object { $_ -gt 0 } | Select-Object -Unique)
        foreach ($id in $pids) { Stop-Process -Id $id -Force -ErrorAction SilentlyContinue }
    }
    Write-Host "[-] stopped." -ForegroundColor Green
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
        Write-Host "  [OK] no rule to clear" -ForegroundColor Green
    }
}

function Set-BlockRules {
    if ($Script:NetRules.Count -eq 0) {
        Write-Host "  [Fatal] net_rules is empty - nothing to block." -ForegroundColor Red
        Write-Host "          Add net_rules in paths.json, or use menu: Add network rule" -ForegroundColor Yellow
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
            Write-Host "  [Fatal] cannot create rule: $name" -ForegroundColor Red
            Write-Host "          $($_.Exception.Message)" -ForegroundColor DarkGray
            continue
        }
        $check = Get-NetFirewallRule -DisplayName $name -ErrorAction SilentlyContinue
        if ($check -and $check.Enabled -eq 'True') {
            Write-Host "  [OK] blocked: $exe" -ForegroundColor Green
        } else {
            Write-Host "  [Fatal] rule did NOT take effect: $exe" -ForegroundColor Red
        }
    }
}

function Add-NetRule {
    Write-Host ""
    Write-Host "  [!] Editing/deleting paths.json while blocked leaves orphan rules." -ForegroundColor Red
    Write-Host "      Remove them in Windows Firewall, or use the script in README:" -ForegroundColor Red
    Write-Host '      Get-NetFirewallRule -DisplayName "AI_Block_*" | Remove-NetFirewallRule' -ForegroundColor Red
    Write-Host ""
    Write-Host "============= Add Network Rule =============" -ForegroundColor Cyan
    Write-Host "Format (one entry in net_rules of paths.json):" -ForegroundColor DarkGray
    Write-Host '  "D:\path\to\program.exe"' -ForegroundColor DarkGray
    Write-Host ""
    Write-Host "Current rules:" -ForegroundColor DarkGray
    if ($Script:NetRules.Count -eq 0) { Write-Host "  (empty)" -ForegroundColor DarkGray }
    else { $Script:NetRules | ForEach-Object { Write-Host "  $_" -ForegroundColor DarkGray } }
    Write-Host ""
    $p = Read-Host "Full program path (Enter = cancel)"
    if ([string]::IsNullOrWhiteSpace($p)) { Write-Host "  cancelled"; return }
    $p = $p.Trim([char]34).Trim()
    if (-not (Test-Path -LiteralPath $p)) {
        Write-Host "  [Fatal] path not found: $p" -ForegroundColor Red; return
    }
    if ($Script:NetRules -contains $p) {
        Write-Host "  already exists, skipped"; return
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
    # clear everything first, then create what is needed: idempotent, reclaims stale/orphan rules either way
    if ($block) {
        Write-Host "[+] building air-gap (outbound block)..." -ForegroundColor Yellow
        Clear-BlockRules
        Set-BlockRules
    } else {
        Write-Host "[-] restoring network..." -ForegroundColor Yellow
        Clear-BlockRules
    }
    Write-Host ""
}

# =========================================================================
#  Models
# =========================================================================

function Pull-Model {
    Write-Host ""
    Write-Host "[!] this tool only forwards the command." -ForegroundColor Red
    Write-Host "    it does NOT handle network drops, progress or retries." -ForegroundColor Red
    Write-Host "    if the download breaks, get the file yourself and drop it into the engine models dir." -ForegroundColor Red
    Write-Host ""
    if (-not (Get-Command Invoke-PullPlugin -ErrorAction SilentlyContinue)) {
        Write-Host "[!] no pull plugin configured for this environment." -ForegroundColor Red
        Write-Host "    drop a pull_plugin.ps1 into plugins\ (next to this script) and retry." -ForegroundColor DarkGray
        return
    }
    $model = Read-Host "model name to pull (enter = cancel)"
    if (-not $model) { Write-Host "[!] cancelled." -ForegroundColor Green; return }
    Write-Host ""
    Write-Host ">>> pulling: $model" -ForegroundColor Cyan
    $ok = $false
    try { $ok = Invoke-PullPlugin -ModelName $model } catch { $ok = $false }
    if (-not $ok) {
        Write-Host ""
        Write-Host "[!] pull failed." -ForegroundColor Red
        Write-Host "    could be: typo in the name, no network, or this engine cannot pull online." -ForegroundColor Red
        Write-Host "    download it yourself (HuggingFace / a mirror / network drive) and drop it into the engine models dir." -ForegroundColor Red
    }
}


function Kill-Zombies {
    Write-Host ""
    Write-Host "[!] WARNING: force-kill ENGINE processes only." -ForegroundColor Red
    Write-Host "    Chat Panel host is NOT touched." -ForegroundColor Red
    Write-Host ""
    $names = @($Script:ProcessNames)
    if ($names.Count -gt 0) {
        Write-Host "    process_name: $($names -join ', ')" -ForegroundColor DarkGray
        $pids = @()
        foreach ($n in $names) {
            $pids += @(Get-Process -Name $n -ErrorAction SilentlyContinue | ForEach-Object { $_.Id })
        }
    } else {
        if (-not $Script:ApiPort) { Write-Host "[Fatal] engine_port not set in paths.json - nothing to resolve." -ForegroundColor Red; return }
        Write-Host "    process_name not set -> resolve PID by engine_port $Script:ApiPort" -ForegroundColor DarkGray
        $pids = @(Get-NetTCPConnection -LocalPort $Script:ApiPort -State Listen -ErrorAction SilentlyContinue |
                  ForEach-Object { $_.OwningProcess })
    }
    $pids = @($pids | Where-Object { $_ -gt 0 } | Select-Object -Unique)
    if ($pids.Count -eq 0) {
        Write-Host "[-] no engine process found. nothing to kill." -ForegroundColor Green
        return
    }
    Write-Host "    PIDs: $($pids -join ', ')" -ForegroundColor Yellow
    if ((Read-Host "confirm? type YES") -ne "YES") {
        Write-Host "[!] cancelled." -ForegroundColor Green; return
    }
    foreach ($id in $pids) { Stop-Process -Id $id -Force -ErrorAction SilentlyContinue }
    Write-Host "[-] killed." -ForegroundColor Green
}

function Test-API {
    if (-not $Script:ApiPort) { Write-Host ""; Write-Host "[Fatal] engine_port not set in paths.json." -ForegroundColor Red; return }
    Write-Host ""; Write-Host "[+] testing 127.0.0.1:$Script:ApiPort$Script:HealthEndpoint ..." -ForegroundColor Yellow
    try {
        $null = Invoke-WebRequest -Uri "http://127.0.0.1:$Script:ApiPort$Script:HealthEndpoint" -Method Get -TimeoutSec 3 -UseBasicParsing
        Write-Host "[+] OK (HTTP 200)" -ForegroundColor Green
    } catch { Write-Host "[Fatal] connection failed! Start AI Engine first." -ForegroundColor Red }
}

function Delete-Model-Danger {
    Write-Host ""
    Write-Host "[!] WARNING: about to delete model files!" -ForegroundColor Red
    Write-Host "    this is irreversible. confirm the exact name via the engine or the chat panel." -ForegroundColor Red
    Write-Host ""
    if (-not (Get-Command Invoke-RmPlugin -ErrorAction SilentlyContinue)) {
        Write-Host "[!] no remove plugin configured for this environment." -ForegroundColor Red
        Write-Host "    drop an rm_plugin.ps1 into plugins\ (next to this script) and retry." -ForegroundColor DarkGray
        return
    }
    $model = Read-Host "model name to delete (enter = cancel)"
    if (-not $model) { Write-Host "[!] cancelled." -ForegroundColor Green; return }
    $confirm = Read-Host "type the name again to confirm"
    if ($model -ne $confirm) { Write-Host ""; Write-Host "[!] confirm failed." -ForegroundColor Green; return }
    $ok = $false
    try { $ok = Invoke-RmPlugin -ModelName $model } catch { $ok = $false }
    if ($ok) { Write-Host "[+] deleted." -ForegroundColor Red }
    else { Write-Host "[!] delete failed." -ForegroundColor Red }
}


function Open-Explorer { Start-Process explorer.exe }
function Open-TaskManager { Start-Process taskmgr.exe }

# =========================================================================
#  Main loop (table lookup)
# =========================================================================
while ($true) {
    Show-Menu
    $choice = (Read-Host "select").Trim().ToUpper()
    if ($choice -eq '0') {
        Write-Host ''
        Write-Host '    ___   _____  ___   ___   ___    __  ' -ForegroundColor Cyan
        Write-Host '   / __| / __\ \/ / | | __| / _ \  / /  ' -ForegroundColor Cyan
        Write-Host '   \__ \| |___ >  <  | |__ | | | |/ /   ' -ForegroundColor Cyan
        Write-Host '   |___/ \___//_/\_\ |____| \___/ /_/   ' -ForegroundColor Cyan
        Write-Host ''
        Write-Host '     [ Goodbye, cyber-contractor! Toolbox sealed. ]' -ForegroundColor Yellow
        break
    }
    # v55: danger-zone entry. checked BEFORE table lookup (it has no Action).
    if ($choice -eq $Script:DangerEntryKey) {
        Show-DangerMenu
    } elseif ($Script:MenuIndex.ContainsKey($choice)) {
        & $Script:MenuIndex[$choice].Action
    } else {
        Write-Host ""; Write-Host "invalid input." -ForegroundColor Red
    }
    Write-Host ""
    Write-Host "press any key to return..."
    try { $null = $Host.UI.RawUI.ReadKey("NoEcho,IncludeKeyDown") }
    catch { Start-Sleep -Milliseconds 700 }
}