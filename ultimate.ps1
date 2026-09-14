#REQUIRES -Version 7
#"Set-ExecutionPolicy Bypass -Scope LocalMachine -Force" USE WHEN NECESSARY 

[CmdletBinding()]
param (
    [ValidateSet("All", "defender", "updates", "Edge", "usb", "contextmenu", "xbox", "drivers", 
    "registry", "hostsblock", "features", "services", "onedrive", "bcdedit", 
    "network", "appx", "power", "Component cleanup",
    "teams", "sys apps", "cursors", "schdtasks")]
    [string[]]$Section = @("All"),
    [ValidateSet("All", "defender", "updates", "Edge", "usb", "xbox", "contextmenu", "drivers", 
    "registry", "hostsblock","features", "services",
    "onedrive", "bcdedit", "network", "appx",
    "power", "Component cleanup", "teams", "sys apps", "cursors", 
    "schdtasks")]
    [string[]]$SkipSection,
    [switch]$Restore
)

if (-not ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    try {
        $argList = "-ExecutionPolicy Bypass -NoProfile -File `"$PSCommandPath`""
        if ($Section) { $argList += " -Section `"$Section`"" }
        if ($SkipSection -and $SkipSection.Count -gt 0) {
            $skipString = ($SkipSection | ForEach-Object { "`"$_`"" }) -join ","
            $argList += " -SkipSection @($skipString)"
        }
        if ($Restore) { $argList += " -Restore" }
        Start-Process pwsh.exe -ArgumentList $argList -Verb RunAs -ErrorAction Stop
    } catch {
        Write-Host ""
        Write-Host " Elevation canceled by user" -ForegroundColor Yellow
        Write-Host " [!] This script MUST run as admin." -ForegroundColor Yellow
        Write-Host ""
        Write-Host "  Error: $($_.Exception.Message)" -ForegroundColor DarkGray
        Write-Host ""
        Pause
    }
    Exit
}

$sections = @(
    @{ Key = "Defender"; Label = "Defender & Security" },
    @{ Key = "Updates"; Label = "Windows Update" },
    @{ Key = "Edge"; Label = "Microsoft Edge Removal" },
    @{ Key = "Registry"; Label = "Registry Tweaks" },
    @{ Key = "Hostsblock"; Label = "Host File" },
    @{ Key = "Usb"; Label = "USB Power Management" },
    @{ Key = "Services"; Label = "System Services" },
    @{ Key = "schdtasks"; Label = "Scheduled Tasks" },
    @{ Key = "Bcdedit"; Label = "BCDEdit Settings" },
    @{ Key = "Power"; Label = "Power Plan Options" },
    @{ Key = "Appx"; Label = "AppX Packages" },
    @{ Key = "Sys apps"; Label = "System Apps" },
    @{ Key = "Onedrive"; Label = "OneDrive Removal" },
    @{ Key = "Teams"; Label = "Microsoft Teams Removal" },
    @{ Key = "Xbox"; Label = "Xbox Removal" },
    @{ Key = "Contextmenu"; Label = "Context Menus" },
    @{ Key = "Drivers"; Label = "Drivers Management" },
    @{ Key = "Component cleanup"; Label = "Component Cleanup" },
    @{ Key = "Features"; Label = "Windows Features" },
    @{ Key = "Network"; Label = "Network Tweaks" },
    @{ Key = "Cursors"; Label = "Cursors scheme" }
)


$Script:RemoveXbox = $false

$Script:Passed    = 0
$Script:Failed    = 0
$Script:Skipped   = 0
$Script:Warnings  = 0
$Script:StartTime = Get-Date

# Pertweak reg backup . delta journal
$Script:RegBackupDir   = "$env:USERPROFILE\Desktop\ultimate_backup"
$Script:RegJournalPath = "$Script:RegBackupDir\tweak_journal.json"
$Script:RegJournal     = @()
if (Test-Path -LiteralPath $Script:RegJournalPath) {
    try { $Script:RegJournal = @(Get-Content -LiteralPath $Script:RegJournalPath -Raw -ErrorAction Stop | ConvertFrom-Json) } catch { $Script:RegJournal = @() }
}

function Save-RegJournal {
    New-Item -Path $Script:RegBackupDir -ItemType Directory -Force -ErrorAction SilentlyContinue | Out-Null
    $Script:RegJournal | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath $Script:RegJournalPath -Encoding UTF8
}

function New-RegKeyPath {
    param([string]$Path)
    if ([string]::IsNullOrEmpty($Path)) { return }
    $Path = $Path.TrimEnd('\')
    if (Test-Path -LiteralPath $Path) { return }
    # New-Item has no -LiteralPath and wildcard chars in the leaf would glob, so:
    # walk segment by segment, resolve the (escaped) parent via -Path, create the leaf via -Name (always literal)
    $segments = $Path.Split('\')
    if ($segments.Count -lt 2) { return }
    $current = $segments[0]
    for ($i = 1; $i -lt $segments.Count; $i++) {
        $current = "$current\$($segments[$i])"
        if (-not (Test-Path -LiteralPath $current)) {
            $parent = $segments[0..($i - 1)] -join '\'
            $escapedParent = $parent.Replace('`', '``').Replace('*', '`*').Replace('?', '`?').Replace('[', '`[').Replace(']', '`]')
            New-Item -Path $escapedParent -Name $segments[$i] -Force -ErrorAction SilentlyContinue | Out-Null
        }
    }
}

function Save-RegTweakBackup {
    param($E)
    if ($null -eq $E -or -not $E.P) { return }
    $id = "$($E.P)|$($E.N)"
    foreach ($j in $Script:RegJournal) { if ($j.id -eq $id) { return } }  # capture-once: keep the FIRST (pre-debloat) observation
    $rec = [ordered]@{ id = $id; path = [string]$E.P; name = [string]$E.N; type = "value"; existed = $false; value = $null; kind = $null; timestamp = (Get-Date -Format o) }
    try {
        if (Test-Path -LiteralPath $E.P) {
            $key = Get-Item -LiteralPath $E.P -ErrorAction Stop
            $valName = if ($E.N -eq "(Default)") { "" } else { [string]$E.N }
            $exists = if ($valName -eq "") { $null -ne $key.GetValue("") } else { $key.GetValueNames() -contains $valName }
            if ($exists) {
                $rec.existed = $true
                $rec.value   = $key.GetValue($valName)
                $rec.kind    = $key.GetValueKind($valName).ToString()
            }
        }
    } catch {
        $rec.existed = $false  # key itself missing — script will create it, so restore removes it
    }
    $Script:RegJournal += [pscustomobject]$rec
    Save-RegJournal
}

function Restore-RegTweaks {
    if (-not (Test-Path -LiteralPath $Script:RegJournalPath)) {
        Write-Host ""
        Write-Host "  [!] No  tweak journal found — nothing to restore." -ForegroundColor Yellow
        Write-Host ""
        return
    }
    try { $journal = @(Get-Content -LiteralPath $Script:RegJournalPath -Raw -ErrorAction Stop | ConvertFrom-Json) }
    catch { Write-Host "  [!] Journal unreadable: $($_.Exception.Message)" -ForegroundColor Red; return }
    if ($journal.Count -eq 0) { Write-Host "  [!] Journal is empty — nothing to restore." -ForegroundColor Yellow; return }

    Write-Host ""
    Write-Host "  Restoring $($journal.Count) registry tweaks from journal (newest first)..." -ForegroundColor Cyan
    $ok = 0; $fail = 0
    foreach ($r in ($journal | Sort-Object timestamp -Descending)) {
        try {
            if ($r.type -eq "regkey") {
                if ($r.backupFile -and (Test-Path -LiteralPath $r.backupFile)) {
                    & reg.exe import $r.backupFile 2>$null | Out-Null
                    if ($LASTEXITCODE -eq 0) { Write-Host "  [ OK ] Restored key: $($r.path)" -ForegroundColor Green; $ok++ }
                    else { Write-Host "  [FAIL] Could not restore key: $($r.path)" -ForegroundColor Red; $fail++ }
                } else {
                    Write-Host "  [FAIL] Key backup file missing: $($r.path)" -ForegroundColor Red; $fail++
                }
                continue
            }
            if ($r.existed) {
                $val = switch ($r.kind) {
                    "Binary"       { [byte[]]@($r.value) }
                    "DWord"        { [int]$r.value }
                    "QWord"        { [long]$r.value }
                    "MultiString"  { [string[]]@($r.value) }
                    default        { [string]$r.value }
                }
                if (-not (Test-Path -LiteralPath $r.path)) { New-RegKeyPath -Path $r.path }
                New-ItemProperty -LiteralPath $r.path -Name $r.name -Value $val -PropertyType $r.kind -Force -ErrorAction Stop | Out-Null
                Write-Host "  [ OK ] Restored: $($r.path) -> $($r.name)" -ForegroundColor Green
                $ok++
            } else {
                Remove-ItemProperty -LiteralPath $r.path -Name $r.name -ErrorAction Stop
                Write-Host "  [ OK ] Removed (was not present before): $($r.path) -> $($r.name)" -ForegroundColor Green
                $ok++
            }
        } catch {
            Write-Host "  [FAIL] $($r.path) -> $($r.name) : $($_.Exception.Message)" -ForegroundColor Red
            $fail++
        }
    }
    Write-Host ""
    Write-Host "  Restored $ok of $($journal.Count) entries ($fail failed)." -ForegroundColor Cyan
    if ($fail -eq 0 -and $ok -gt 0) {
        Remove-Item -LiteralPath $Script:RegJournalPath -Force -ErrorAction SilentlyContinue
        Get-ChildItem -LiteralPath $Script:RegBackupDir -Filter "del_*.reg" -ErrorAction SilentlyContinue | Remove-Item -Force -ErrorAction SilentlyContinue
        Write-Host "  Journal cleared." -ForegroundColor DarkGray
    }
}

if ($Restore) {
    Restore-RegTweaks
    Write-Host ""
    Pause
    Exit
}

# PowerShell 7 cannot natively load the Appx module on many builds (0x80131539).
# Ensure-Appx lazily loads the Windows PowerShell 5.1 copy via implicit remoting.
function Ensure-Appx {
    if ($PSVersionTable.PSVersion.Major -lt 7) { return }
    if (Get-Module Appx) { return }
    $oldProgress = $ProgressPreference
    try {
        $ProgressPreference = 'SilentlyContinue'
        Import-Module Appx -UseWindowsPowerShell -ErrorAction Stop -WarningAction SilentlyContinue | Out-Null
    } catch {
        Write-Step "Appx module could not be loaded — AppX operations will be skipped ($($_.Exception.Message))" "WARN"
    } finally {
        $ProgressPreference = $oldProgress
    }
}

function Show-Banner {
    Clear-Host
    $L = "═" * 66
    Write-Host ""
    Write-Host "  $L" -ForegroundColor Cyan
    Write-Host "  ██╗   ██╗██╗  ████████╗██╗███╗   ███╗ █████╗ ████████╗███████╗" -ForegroundColor Cyan
    Write-Host "  ██║   ██║██║  ╚══██╔══╝██║████╗ ████║██╔══██╗╚══██╔══╝██╔════╝" -ForegroundColor Cyan
    Write-Host "  ██║   ██║██║     ██║   ██║██╔████╔██║███████║   ██║   █████╗  " -ForegroundColor Cyan
    Write-Host "  ██║   ██║██║     ██║   ██║██║╚██╔╝██║██╔══██║   ██║   ██╔══╝  " -ForegroundColor Cyan
    Write-Host "  ╚██████╔╝███████╗██║   ██║██║ ╚═╝ ██║██║  ██║   ██║   ███████╗" -ForegroundColor Cyan
    Write-Host "   ╚═════╝ ╚══════╝╚═╝   ╚═╝╚═╝     ╚═╝╚═╝  ╚═╝   ╚═╝   ╚══════╝" -ForegroundColor Cyan
    Write-Host "  $L" -ForegroundColor Cyan
    Write-Host "  —  Optimization · Debloat · Tweaking — " -ForegroundColor White
	Write-Host "  THIS SCRIPT IS FOR ADVANCED USER, Use at your own risk" -ForegroundColor Red
    Write-Host "  $(Get-Date -Format 'dddd, yyyy-MM-dd  HH:mm:ss')" -ForegroundColor DarkGray
    Write-Host "  $L" -ForegroundColor Cyan
    Write-Host ""
}


function Write-Section {
    param([string]$Title)
    Write-Host ""
    Write-Host "  ╔══════════════════════════════════════════════════════════╗" -ForegroundColor DarkCyan
    Write-Host "  ║  $($Title.ToUpper().PadRight(56))║" -ForegroundColor DarkCyan
    Write-Host "  ╚══════════════════════════════════════════════════════════╝" -ForegroundColor DarkCyan
}

function Write-SubSection {
    param([string]$Title)
    Write-Host ""
    Write-Host "    ┄┄┄  $Title  ┄┄┄" -ForegroundColor DarkYellow
}

function Write-Step {
    param(
        [string]$Message,
        [ValidateSet("OK","FAIL","SKIP","WARN","INFO","WAIT","DETECT")]
        [string]$Status = "INFO"
    )
    $tag   = switch ($Status) {
        "OK"     { "  OK  " }
        "FAIL"   { " FAIL " }
        "SKIP"   { " SKIP " }
        "WARN"   { " WARN " }
        "INFO"   { " INFO " }
        "WAIT"   { " WAIT " }
        "DETECT" { " DTCT " }
    }
    $color = switch ($Status) {
        "OK"     { "Green"   }
        "FAIL"   { "Red"     }
        "SKIP"   { "DarkGray"}
        "WARN"   { "Yellow"  }
        "INFO"   { "Cyan"    }
        "WAIT"   { "Magenta" }
        "DETECT" { "Blue"    }
    }

    $msg = switch ($Status) {
    "FAIL" { 
        if ($Message.Length -gt 100) { $Message.Substring(0,97) + "..." }
        else { $Message.PadRight(52) }
    }
    "WARN" {
        if ($Message.Length -gt 100) { $Message.Substring(0,97) + "..." }
        else { $Message.PadRight(52) }
    }
    default {
        if ($Message.Length -gt 52) { $Message.Substring(0,49) + "..." }
        else { $Message.PadRight(52) }
    }
}

    Write-Host "    " -NoNewline
    Write-Host "[$tag]" -ForegroundColor $color -NoNewline
    Write-Host " $msg" -ForegroundColor White

    switch ($Status) {
        "OK"   { $Script:Passed++   }
        "FAIL" { $Script:Failed++   }
        "SKIP" { $Script:Skipped++  }
        "WARN" { $Script:Warnings++ }
    }
}

$HW = @{
    GPU = @(Get-CimInstance Win32_VideoController -ErrorAction SilentlyContinue | Select-Object -ExpandProperty Name)
    Audio      = (Get-CimInstance Win32_SoundDevice     -ErrorAction SilentlyContinue | Select-Object -ExpandProperty Name)
    Board      = (Get-CimInstance Win32_BaseBoard        -ErrorAction SilentlyContinue | Select-Object -First 1)
    System     = (Get-CimInstance Win32_ComputerSystem   -ErrorAction SilentlyContinue | Select-Object -First 1)
    CPU        = (Get-CimInstance Win32_Processor        -ErrorAction SilentlyContinue | Select-Object -First 1).Name
    InstalledSoftware = (Get-ItemProperty "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*",
                                          "HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\*" `
                          -ErrorAction SilentlyContinue | Where-Object { $_.DisplayName } | Select-Object -ExpandProperty DisplayName)
}

function Write-Summary {
    $elapsed = [math]::Round(((Get-Date) - $Script:StartTime).TotalSeconds, 1)
    $total   = $Script:Passed + $Script:Failed + $Script:Skipped + $Script:Warnings
    Write-Host ""
    Write-Host "  ╔══════════════════════════════════════════════════════════╗" -ForegroundColor Cyan
    Write-Host "  ║  COMPLETED — SUMMARY                                    ║" -ForegroundColor Cyan
    Write-Host "  ╠══════════════════════════════════════════════════════════╣" -ForegroundColor Cyan
    Write-Host "  ║  Total operations : $($total.ToString().PadRight(36))║" -ForegroundColor White
    Write-Host "  ║  Passed           : $($Script:Passed.ToString().PadRight(36))║" -ForegroundColor Green
    Write-Host "  ║  Skipped          : $($Script:Skipped.ToString().PadRight(36))║" -ForegroundColor DarkGray
    Write-Host "  ║  Warnings         : $($Script:Warnings.ToString().PadRight(36))║" -ForegroundColor Yellow
    $failColor = if ($Script:Failed -gt 0) { "Red" } else { "Green" }
    Write-Host "  ║  Failed           : $($Script:Failed.ToString().PadRight(36))║" -ForegroundColor $failColor
    Write-Host "  ║  Time elapsed     : $("${elapsed}s".PadRight(36))║" -ForegroundColor White
    Write-Host "  ╚══════════════════════════════════════════════════════════╝" -ForegroundColor Cyan
    Write-Host ""
}

function Download-FileWithHash {
    param(
        [string]$Url,
        [string]$Destination,
        [string]$ExpectedHash,
        [string]$Algorithm = "SHA256",
        [int]$Retries = 3
    )

    if ($WhatIf) {
        Write-Step "WOULD: Download $(Split-Path $Url -Leaf) and verify hash" "INFO"
        return $true
    }

    if (Test-Path $Destination) {
        $actualHash = (Get-FileHash -Path $Destination -Algorithm $Algorithm).Hash
        if ($actualHash -eq $ExpectedHash) {
            Write-Step "File already exists with correct hash: $(Split-Path $Destination -Leaf)" "SKIP"
            return $true
        } else {
            Write-Step "Existing file hash mismatch – re-downloading" "WARN"
            Remove-Item -Path $Destination -Force -ErrorAction SilentlyContinue
        }
    }

    $attempt = 0
    while ($attempt -lt $Retries) {
        $attempt++
        Write-Step "Downloading $(Split-Path $Url -Leaf) (attempt $attempt/$Retries)..." "WAIT"
        try {
            Invoke-WebRequest -Uri $Url -OutFile $Destination -UseBasicParsing -ErrorAction Stop
            Write-Step "Downloaded: $(Split-Path $Destination -Leaf)" "OK"
        } catch {
            Write-Step "Download failed: $($_.Exception.Message)" "FAIL"
            if ($attempt -ge $Retries) { return $false }
            Start-Sleep -Seconds 2
            continue
        }

        $actualHash = (Get-FileHash -Path $Destination -Algorithm $Algorithm).Hash
        if ($actualHash -eq $ExpectedHash) {
            Write-Step "Hash verified ($Algorithm): $actualHash" "OK"
            return $true
        } else {
            Write-Step "Hash MISMATCH! Expected: $ExpectedHash, Actual: $actualHash" "FAIL"
            Remove-Item -Path $Destination -Force -ErrorAction SilentlyContinue
            if ($attempt -ge $Retries) { return $false }
            Start-Sleep -Seconds 2
        }
    }
    return $false
}

function Test-SkipSection {
    param([string]$SectionName)
    if (-not $SkipSection) { return $false }
    if ($SkipSection -contains 'All') { return $true }
    return ($SkipSection -contains $SectionName)
}

function Invoke-Safe {
    param(
        [scriptblock]$Action,
        [string]$Description
    )
    if ($WhatIf) {
        Write-Step "WOULD: $Description" "INFO"
        return $false
    } else {
        try {
            & $Action
            return $true
        } catch {
            Write-Step "FAILED: $Description — $($_.Exception.Message)" "FAIL"
            return $false
        }
    }
}

function disablesvc {
    param([string]$Name)
    
    if ($WhatIf) {
        $svc = Get-Service -Name $Name -ErrorAction SilentlyContinue
        if ($svc) {
            Write-Step "WOULD disable: $Name (current: $($svc.Status)/$($svc.StartType))" "INFO"
            return $true
        }
        return $false
    }
    
    $svc = Get-Service -Name $Name -ErrorAction SilentlyContinue
    if (-not $svc) { return 'missing' }
    if ($svc.StartType -eq 'Disabled') { return 'already' }
    # sc.exe instead of Stop-Service/Set-Service: exit-code based, no terminating errors / transcript noise
    if ($svc.Status -ne 'Stopped') { & sc.exe stop $Name 2>$null | Out-Null }
    & sc.exe config $Name start= disabled 2>$null | Out-Null
    if ($LASTEXITCODE -ne 0) { return 'failed' }
    return 'ok'
}

function StopProcess {
    param([string]$Pattern)
    
    if ($WhatIf) {
        $procs = Get-Process -Name $Pattern -ErrorAction SilentlyContinue
        if ($procs) {
            Write-Step "WOULD kill ($($procs.Count)): $Pattern" "INFO"
            return $procs.Count
        }
        return 0
    }
    
    $procs = Get-Process -Name $Pattern -ErrorAction SilentlyContinue
    if ($procs) {
        $procs | Stop-Process -Force -ErrorAction SilentlyContinue
        return $procs.Count
    }
    return 0
}

function DisableTask {
    param([string]$TaskName, [string]$TaskPath = "\")
    
    if ($WhatIf) {
        $t = Get-ScheduledTask -TaskName $TaskName -TaskPath $TaskPath -ErrorAction SilentlyContinue
        if ($t) {
            Write-Step "WOULD disable task: $TaskName" "INFO"
            return $true
        }
        return $false
    }
    
    $t = Get-ScheduledTask -TaskName $TaskName -TaskPath $TaskPath -ErrorAction SilentlyContinue
    if ($t) {
        Disable-ScheduledTask -TaskName $TaskName -TaskPath $TaskPath -ErrorAction SilentlyContinue | Out-Null
        return $true
    }
    return $false
}

function Remove-RunEntry {
    param([string]$Pattern)
    
    if ($WhatIf) {
        $removed = 0
        $runPaths = @(
            "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Run",
            "HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\Run",
            "HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Run"
        )
        foreach ($path in $runPaths) {
            if (Test-Path $path) {
                $entries = Get-ItemProperty -Path $path -ErrorAction SilentlyContinue
                $matches = $entries.PSObject.Properties | Where-Object { $_.Name -like $Pattern }
                if ($matches) {
                    foreach ($m in $matches) {
                        Write-Step "WOULD remove run entry: $($m.Name) ($path)" "INFO"
                        $removed++
                    }
                }
            }
        }
        return $removed
    }
    
    $removed = 0
    $runPaths = @(
        "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Run",
        "HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\Run",
        "HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Run"
    )
    foreach ($path in $runPaths) {
        if (Test-Path $path) {
            $entries = Get-ItemProperty -Path $path -ErrorAction SilentlyContinue
            $entries.PSObject.Properties | Where-Object { $_.Name -like $Pattern } | ForEach-Object {
                Remove-ItemProperty -Path $path -Name $_.Name -ErrorAction SilentlyContinue
                $removed++
            }
        }
    }
    return $removed
}


Show-Banner
Remove-Item "$env:USERPROFILE\Desktop\ultimates.log" -Force -ErrorAction SilentlyContinue
Write-Host "  $L" -ForegroundColor Cyan
foreach ($g in $HW.GPU) {
Write-Step "GPU     : $g"                                "DETECT"
}
Write-Step "CPU     : $($HW.CPU)"                        "DETECT"
Write-Step "Board   : $($HW.Board.Manufacturer) $($HW.Board.Product)" "DETECT"
Write-Step "System  : $($HW.System.Manufacturer) $($HW.System.Model)" "DETECT"
foreach ($a in $HW.Audio) { Write-Step "Audio   : $a" "DETECT" }
Write-Host "  $L" -ForegroundColor Cyan
Start-Transcript -Path "$env:USERPROFILE\Desktop\ultimates.log" -Force -ErrorAction SilentlyContinue > $null

$ProgressPreference = 'SilentlyContinue'

$WhatIf = $false
while ($true) {
    $ans = Read-Host "  [?] WhatIf mode (preview only, nothing will be changed)? (Y/N)"
    if ($ans -match '^[Yy]$') { $WhatIf = $true; break }
    elseif ($ans -match '^[Nn]$') { $WhatIf = $false; break }
    else { Write-Host "   [!] Invalid input. [Y/N]" -ForegroundColor Yellow }
}
if ($WhatIf) { Write-Step "WhatIf mode enabled." "INFO" }

for ($i = 0; $i -lt $sections.Count; $i++) {
    Write-Host "[$($i + 1)] $($sections[$i].Label)"
}
$SkipSection = @()
while ($true) {
    $answer = Read-Host "Enter numbers to skip, or use 'o' to run ONLY those (e.g. o5,7), press Enter for all"

    if ($answer -eq "") { break }

    if ($answer -match '^o\d+(\s*,\s*\d+)*$' -or $answer -match '^\d+(\s*,\s*\d+)*$') {
        $onlyMode = ($answer -match '^o')
        if ($onlyMode) { $answer = $answer.Substring(1) }
        $numbers = ($answer -split ",") | ForEach-Object { [int]$_.Trim() }

        if (@($numbers | Where-Object { $_ -lt 1 -or $_ -gt $sections.Count }).Count -gt 0) {
            Write-Host "   [!] Invalid input. Numbers must be between 1 and $($sections.Count)." -ForegroundColor Yellow
            continue
        }

        if ($onlyMode) {
            for ($i = 0; $i -lt $sections.Count; $i++) {
                if ($numbers -notcontains ($i + 1)) {
                    $SkipSection += $sections[$i].Key
                }
            }
        } else {
            foreach ($num in $numbers) {
                $SkipSection += $sections[$num - 1].Key
            }
        }
        break
    }

    Write-Host "   [!] Invalid input. Use numbers (e.g. 3,7), 'o' + numbers (e.g. o5,7), or press Enter for all." -ForegroundColor Yellow
}
$doBackup = Read-Host "Create a System Restore Point and Registry Backup ? (Y/N)"
$Script:SkipBackup = ($doBackup -eq "n" -or $doBackup -eq "N")

function Invoke-WinPSCommand {
    param([Parameter(Mandatory)][scriptblock]$ScriptBlock)

    $encoded = [Convert]::ToBase64String([System.Text.Encoding]::Unicode.GetBytes($ScriptBlock.ToString()))

    $psi = New-Object System.Diagnostics.ProcessStartInfo
    $psi.FileName               = "powershell.exe"
    $psi.Arguments              = "-NoProfile -NonInteractive -ExecutionPolicy Bypass -EncodedCommand $encoded"
    $psi.RedirectStandardOutput = $true
    $psi.RedirectStandardError  = $true
    $psi.UseShellExecute        = $false

    $proc = [System.Diagnostics.Process]::Start($psi)
    $stdout = $proc.StandardOutput.ReadToEnd().Trim()
    $stderr = $proc.StandardError.ReadToEnd().Trim()
    $proc.WaitForExit()

    [PSCustomObject]@{ ExitCode = $proc.ExitCode; Output = $stdout; Error = $stderr }
}

function Ensure-RestorePoint {
    [CmdletBinding()]
    param(
        [string]$Description   = "before script",
        [int]$MinFreeSpaceMB   = 1024
    )

    if ($WhatIf) {
        Write-Step "WOULD: Create restore point '$Description'" "INFO"
        return $true
    }


    $vss = Get-Service -Name VSS -ErrorAction SilentlyContinue
    if (-not $vss) {
        return $false
    }
    if ($vss.StartType -eq 'Disabled') {
        try {
            Set-Service -Name VSS -StartupType Manual -ErrorAction Stop
        } catch {
            Write-Step "Could not re-enable VSS: $($_.Exception.Message)" "FAIL"
            return $false
        }
    }

    $driveLetter = $env:SystemDrive.TrimEnd(':')
    $sysDrive    = Get-PSDrive -Name $driveLetter -ErrorAction SilentlyContinue
    $freeMB      = if ($sysDrive) { [math]::Round($sysDrive.Free / 1MB) } else { 0 }
    if ($freeMB -lt $MinFreeSpaceMB) {
        Write-Step "Insufficient free space ($freeMB MB < $MinFreeSpaceMB MB)" "FAIL"
        return $false
    }

   $r = Invoke-WinPSCommand -ScriptBlock {
    try { Enable-ComputerRestore -Drive "$env:SystemDrive\" -ErrorAction Stop; "OK" }
    catch { "FAIL:$($_.Exception.Message)" }
}
if ($r.Output -eq "OK") {
    Write-Step "System Protection enabled on $env:SystemDrive" "OK"
} else {
    Write-Step "Could Not enable System Protection: $($r.Output)" "FAIL"
    return $false
}

    $freqPath     = "HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\SystemRestore"
    $originalFreq = $null
    try {
        $originalFreq = (Get-ItemProperty -Path $freqPath -Name SystemRestorePointCreationFrequency -ErrorAction SilentlyContinue).SystemRestorePointCreationFrequency
        New-ItemProperty -Path $freqPath -Name SystemRestorePointCreationFrequency -Value 0 -PropertyType DWord -Force -ErrorAction Stop | Out-Null
    } catch {
    }

    try {
        $r = Invoke-WinPSCommand -ScriptBlock ([scriptblock]::Create(@"
try { Checkpoint-Computer -Description '$Description' -RestorePointType MODIFY_SETTINGS -ErrorAction Stop; 'OK' }
catch { "FAIL:`$(`$_.Exception.Message)" }
"@))
        if ($r.Output -eq "OK") {
            Write-Step "Restore point created: '$Description'" "OK"
            $result = $true
        } else {
            Write-Step "Checkpoint-Computer failed: $($r.Output)" "FAIL"
            $result = $false
        }
    } finally {
    if ($null -ne $originalFreq) {
        try { 
            Set-ItemProperty -Path $freqPath -Name SystemRestorePointCreationFrequency -Value $originalFreq -ErrorAction SilentlyContinue 
        } catch {}
    } else {
        try {
            Remove-ItemProperty -Path $freqPath -Name SystemRestorePointCreationFrequency -ErrorAction SilentlyContinue
        } catch {}
    }
}

    return $result
}

$Script:Build = [int](Get-CimInstance Win32_OperatingSystem).BuildNumber
$Script:IsWin11 = $Script:Build -ge 22000



if (-not $WhatIf) {
# ══════════════════════════════════════════════════════════════════════════════
Write-Section "Choose Options"
# ══════════════════════════════════════════════════════════════════════════════
if (($Section -contains "Defender" -or $Section -contains "All") -and -not (Test-SkipSection "defender")) {
$ans = Read-Host "  [?] Disable Defender real-time protection? (Y/N)"
$Script:DefenderMode = 'Skip'
if ($ans -match '^[Yy]$') {
    Write-Host ""
    Write-Host "  [!] WARNING: This leaves Windows with NO active antivirus and" -ForegroundColor Yellow
    Write-Host "  lowers SmartScreen protection. NOT recommended for daily use." -ForegroundColor Yellow
    $conf = Read-Host "  [?] Type 'A' to confirm, anything else to keep Defender on"
    if ($conf -ceq 'A') { $Script:DefenderMode = 'Forever' }
}
}
if (($Section -contains "Updates" -or $Section -contains "All") -and -not (Test-SkipSection "updates")) {
while ($true) {
    $ans = Read-Host "   [?] Disable Windows Update? (Y/N)"
    if ($ans -match '^[Yy]$') { $Script:DisableUpdates = $true; break }
    elseif ($ans -match '^[Nn]$') { $Script:DisableUpdates = $false; break }
    else { Write-Host "   [!] Invalid input. [Y/N]" -ForegroundColor Yellow }
}
}

if (($Section -contains "registry" -or $Section -contains "All") -and -not (Test-SkipSection "registry")) {
while ($true) {
    $ans = Read-Host "   [?] Disable Core Isolation? (Y/N - may break games anti-cheat )"
    if ($ans -match '^[Yy]$') { $Script:DisableVBS = $true; break }
    elseif ($ans -match '^[Nn]$') { $Script:DisableVBS = $false; break }
    else { Write-Host "   [!] Invalid input. [Y/N]" -ForegroundColor Yellow }
}
}

if (($Section -contains "Xbox" -or $Section -contains "All") -and -not (Test-SkipSection "Xbox")) {
    while ($true) {
        $ans = Read-Host "   [?] Remove all Xbox components ? (Y/N)"
        if ($ans -match '^[Yy]$') { $Script:RemoveXbox = $true; break }
        elseif ($ans -match '^[Nn]$') { $Script:RemoveXbox = $false; break }
        else { Write-Host "   [!] Invalid input. [Y/N]" -ForegroundColor Yellow }
    }
}
}
if (-not $Script:SkipBackup) {
if (-not $WhatIf) {
# ══════════════════════════════════════════════════════════════════════════════
    Write-Section "Backup"
# ══════════════════════════════════════════════════════════════════════════════
    $timestamp = Get-Date -Format 'yyyyMMdd_HHmmss'
     $backupDir = "$env:USERPROFILE\Desktop\ultimate_backup"
if (Test-Path "$backupDir\hklm.reg") {
    Write-Step "Backup already exist." "SKIP"
} else {
    New-Item -Path $backupDir -ItemType Directory -Force | Out-Null
    & reg.exe export HKLM "$backupDir\hklm.reg" /y 2>$null | Out-Null
    & reg.exe export HKCU "$backupDir\hkcu.reg" /y 2>$null | Out-Null
    if (Test-Path "$backupDir\hklm.reg") { Write-Step "Backup saved to: $backupDir" "OK" }
    else { Write-Step "Backup failed" "FAIL" }
}
}
 $skipRP = $false
try {
    $lastRP = Get-ComputerRestorePoint -ErrorAction Stop |
              Sort-Object CreationTime -Descending |
              Select-Object -First 1
    if ($lastRP) {
        $rpTime = [System.Management.ManagementDateTimeConverter]::ToDateTime($lastRP.CreationTime)
        $hoursAgo = [math]::Round(((Get-Date) - $rpTime).TotalHours, 1)
        if ($hoursAgo -lt 24) {
            Write-Step "Recent restore point exists ($hoursAgo h ago) — skipping" "SKIP"
            $skipRP = $true
        }
    }
} catch {
}
if (-not $skipRP) {
    $rpResult = Ensure-RestorePoint -Description "Before Ultimates Script"
    if (-not $rpResult) {
        Write-Host ""
        Write-Host "  [!] Restore point can't be created." -ForegroundColor Yellow
        $ans = Read-Host "  [?] Continue without restore point? (Y/N)"
        if ($ans -notmatch '^[Yy]$') {
            Write-Host "  [-] Aborted by user." -ForegroundColor Cyan
            Stop-Transcript -ErrorAction SilentlyContinue
            Exit
        }
    }
}

} else {
    Write-Step "Backups skipped by user." "INFO"
}

if (-not (Get-PSDrive -Name HKU -ErrorAction SilentlyContinue)) {
    New-PSDrive -Name HKU -PSProvider Registry -Root HKEY_USERS -ErrorAction SilentlyContinue | Out-Null
}

function Find-InstalledSoftware { param([string]$Pattern)
    return ($HW.InstalledSoftware | Where-Object { $_ -like $Pattern }) -ne $null
}

if (-not ((Test-SkipSection "appx") -and (Test-SkipSection "edge") -and (Test-SkipSection "xbox") -and (Test-SkipSection "sys apps"))) {
# ══════════════════════════════════════════════════════════════════════════════
    if ($WhatIf) {
        Write-Step "WOULD: Start AppXSvc. " "INFO"
    } else {
        $svc = Get-Service -Name AppXSvc -ErrorAction SilentlyContinue

        if (-not $svc) {
            Write-Step "AppXSvc service not found" "FAIL"
        } elseif ($svc.Status -eq 'Running') {
        } else {
            if ($svc.StartType -eq 'Disabled') {
                try {
                    Set-Service -Name AppXSvc -StartupType Manual -ErrorAction Stop
                } catch {
                }
            }

            try {
                Start-Service -Name AppXSvc -ErrorAction Stop
                Write-Step "AppXSvc started successfully" "OK"
                $appxResult = $true
            } catch {
				
			}

                $sig = @'
using System;
using System.Runtime.InteropServices;
public class TokenPriv {
    [DllImport("advapi32.dll", SetLastError = true)]
    public static extern bool OpenProcessToken(IntPtr h, uint access, out IntPtr token);
    [DllImport("advapi32.dll", SetLastError = true)]
    public static extern bool LookupPrivilegeValue(string sys, string name, out long luid);
    [StructLayout(LayoutKind.Sequential)] public struct LUID_AND_ATTR { public long Luid; public uint Attr; }
    [StructLayout(LayoutKind.Sequential)] public struct TOKEN_PRIV { public uint Count; public LUID_AND_ATTR Priv; }
    [DllImport("advapi32.dll", SetLastError = true)]
    public static extern bool AdjustTokenPrivileges(IntPtr token, bool disableAll, ref TOKEN_PRIV newState, uint len, IntPtr prev, IntPtr ret);
    public static bool Enable(string priv) {
        IntPtr token;
        if (!OpenProcessToken(System.Diagnostics.Process.GetCurrentProcess().Handle, 0x28, out token)) return false;
        long luid;
        if (!LookupPrivilegeValue(null, priv, out luid)) return false;
        TOKEN_PRIV tp = new TOKEN_PRIV();
        tp.Count = 1; tp.Priv.Luid = luid; tp.Priv.Attr = 0x2;
        return AdjustTokenPrivileges(token, false, ref tp, 0, IntPtr.Zero, IntPtr.Zero);
    }
}
'@
                try {
                    if (-not ([System.Management.Automation.PSTypeName]'TokenPriv').Type) {
                        Add-Type -TypeDefinition $sig -ErrorAction Stop
                    }
                    [TokenPriv]::Enable("SeTakeOwnershipPrivilege") | Out-Null
                    [TokenPriv]::Enable("SeRestorePrivilege") | Out-Null

                    $subPath = "SYSTEM\CurrentControlSet\Services\AppXSvc"
                    $admins = New-Object System.Security.Principal.SecurityIdentifier("S-1-5-32-544")

                    $key = [Microsoft.Win32.Registry]::LocalMachine.OpenSubKey($subPath,
                        [Microsoft.Win32.RegistryKeyPermissionCheck]::ReadWriteSubTree,
                        [System.Security.AccessControl.RegistryRights]::TakeOwnership)
                    $acl = $key.GetAccessControl()
                    $acl.SetOwner($admins)
                    $key.SetAccessControl($acl)
                    $key.Close()

                    $key = [Microsoft.Win32.Registry]::LocalMachine.OpenSubKey($subPath,
                        [Microsoft.Win32.RegistryKeyPermissionCheck]::ReadWriteSubTree,
                        [System.Security.AccessControl.RegistryRights]::ChangePermissions)
                    $acl = $key.GetAccessControl()
                    $rule = New-Object System.Security.AccessControl.RegistryAccessRule($admins, "FullControl", "ContainerInherit", "None", "Allow")
                    $acl.SetAccessRule($rule)
                    $key.SetAccessControl($acl)
                    $key.Close()

                    $svcKey = [Microsoft.Win32.Registry]::LocalMachine.OpenSubKey(
                        "SYSTEM\CurrentControlSet\Services\AppXSvc", $true)
                    $svcKey.SetValue("Start", 3, [Microsoft.Win32.RegistryValueKind]::DWord)
                    $svcKey.Close()
                    Write-Step "AppXSvc Start value set to Manual " "OK"

                    try {
                        Start-Service -Name AppXSvc -ErrorAction Stop
                        Write-Step "AppXSvc started successfully" "OK"
                        $appxResult = $true
                    } catch {
                        Write-Step "AppXSvc is set to manual (reboot required)." "WARN"
                        $appxResult = $true
                    }
                } catch {
                    Write-Step "AppXSvc repair failed: $($_.Exception.Message)" "FAIL"
                    $appxResult = $false
                }
            }
        }
    }

function DefenderSuppression {

    $hideGuiPath = "HKLM:\SOFTWARE\Policies\Microsoft\Windows Defender"
    if (-not (Test-Path $hideGuiPath)) { New-Item -Path $hideGuiPath -Force | Out-Null }
    Set-ItemProperty -Path $hideGuiPath -Name "HideAntiSpywareUI" -Value 1 -Type DWord -Force -ErrorAction SilentlyContinue

    $healthSvc = Get-Service -Name "SecurityHealthService" -ErrorAction SilentlyContinue
    if ($healthSvc) {
        if ($healthSvc.Status -ne 'Stopped') {
            Stop-Service -Name "SecurityHealthService" -Force -ErrorAction SilentlyContinue
        }
        Set-Service -Name "SecurityHealthService" -StartupType Disabled -ErrorAction SilentlyContinue
        Write-Step "SecurityHealthService disabled" "OK"
    }

    $trayRunPath = "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Run"
    $trayRunName = "SecurityHealth"  
    if (Test-Path $trayRunPath) {
        try {
            Remove-ItemProperty -Path $trayRunPath -Name $trayRunName -ErrorAction SilentlyContinue
            Write-Step "Removed tray icon startup entry" "OK"
        } catch {}
    }

    $trayRunPathUser = "HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\Run"
    if (Test-Path $trayRunPathUser) {
        try {
            Remove-ItemProperty -Path $trayRunPathUser -Name $trayRunName -ErrorAction SilentlyContinue
        } catch {}
    }

    $notifPath = "HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\Notifications\Settings\Windows.SystemToast.SecurityAndMaintenance"
    if (-not (Test-Path $notifPath)) { New-Item -Path $notifPath -Force | Out-Null }
    Set-ItemProperty -Path $notifPath -Name "Enabled" -Value 0 -Type DWord -Force -ErrorAction SilentlyContinue

    $wscSvc = Get-Service -Name "wscsvc" -ErrorAction SilentlyContinue
    if ($wscSvc) {
        if ($wscSvc.Status -ne 'Stopped') {
            Stop-Service -Name "wscsvc" -Force -ErrorAction SilentlyContinue
        }
        Set-Service -Name "wscsvc" -StartupType Disabled -ErrorAction SilentlyContinue
    }

    Write-Step "Defender suppression applied" "OK"
}

if (($Section -contains "defender" -or $Section -contains "All") -and -not (Test-SkipSection "defender")) {
    Write-Section "Defender & Security"
    switch ($Script:DefenderMode) {
        'Skip' {
            Write-Step "Defender changes skipped" "SKIP"
        }
        'Forever' {
            if (-not $WhatIf) {
                $DefenderPolicy = @(
                    @{ P="HKLM:\SOFTWARE\Policies\Microsoft\Windows Defender";                     N="DisableAntiSpyware";          V=1; T="DWord" },
                    @{ P="HKLM:\SOFTWARE\Policies\Microsoft\Windows Defender\Real-Time Protection"; N="DisableRealtimeMonitoring"; V=1; T="DWord" },
                    @{ P="HKLM:\SOFTWARE\Policies\Microsoft\Windows Defender\Spynet";                N="SpyNetReporting";           V=0; T="DWord" },
                    @{ P="HKLM:\SOFTWARE\Policies\Microsoft\Windows Defender\Spynet";                N="SubmitSamplesConsent";      V=0; T="DWord" },
                    @{ P="HKLM:\SOFTWARE\Microsoft\Windows Defender\Features";                      N="TamperProtection";          V=0; T="DWord" }
                )
                foreach ($k in $DefenderPolicy) {
                    try {
                        $path = $k.P
                        Save-RegTweakBackup -E @{ P = $path; N = $k.N }
                        if (-not (Test-Path $path)) { New-Item -Path $path -Force -ErrorAction Stop | Out-Null }
                        Set-ItemProperty -Path $path -Name $k.N -Value $k.V -Type $k.T -Force -ErrorAction Stop
                    } catch {
                        Write-Step "Failed: $($k.N)" "FAIL"
                    }
                }
                Set-MpPreference -DisableRealtimeMonitoring $true -ErrorAction SilentlyContinue
                Set-MpPreference -ExclusionPath $env:TEMP -ErrorAction SilentlyContinue

                DefenderSuppression

                Write-Step "Windows Defender successfully disabled." "WARN"
            } else {
                Write-Step "WOULD: Disable Windows Defender" "INFO"
                DefenderSuppression
            }
        }
    }
}

if (($Section -contains "updates" -or $Section -contains "All") -and -not (Test-SkipSection "updates")) {
# ══════════════════════════════════════════════════════════════════════════════
Write-Section "Windows Update "
# ══════════════════════════════════════════════════════════════════════════════
if ($Script:DisableUpdates) {
    if ($WhatIf) {
        Write-Step "WOULD: Disable Windows Update." "INFO"
    } else {
    $UpdatePolicy = @(
        @{ P="HKLM:\SOFTWARE\Policies\Microsoft\Windows\WindowsUpdate"; N="ExcludeWUDriversInQualityUpdate"; V=1; T="DWord" },
        @{ P="HKLM:\SOFTWARE\Policies\Microsoft\Windows\WindowsUpdate"; N="NoAutoUpdate";                     V=1; T="DWord" },
        @{ P="HKLM:\SOFTWARE\Policies\Microsoft\Windows\WindowsUpdate"; N="SetDisableUXWUAccess";              V=1; T="DWord" },
        @{ P="HKLM:\SOFTWARE\Policies\Microsoft\Windows\WindowsUpdate"; N="SetUpdateNotificationLevel";        V=0; T="DWord" },
        @{ P="HKLM:\SOFTWARE\Policies\Microsoft\Windows\WindowsUpdate"; N="DeferUpgrade";                      V=1; T="DWord" },
        @{ P="HKLM:\SOFTWARE\Policies\Microsoft\Windows\WindowsUpdate"; N="DeferUpgradePeriod";                V=1; T="DWord" },
        @{ P="HKLM:\SOFTWARE\Policies\Microsoft\Windows\WindowsUpdate"; N="DeferUpdatePeriod";                 V=0; T="DWord" },
        @{ P="HKLM:\SOFTWARE\Policies\Microsoft\Windows\WindowsUpdate"; N="WUServer";        V="localserver.localdomain.wsus"; T="String" },
        @{ P="HKLM:\SOFTWARE\Policies\Microsoft\Windows\WindowsUpdate"; N="WUStatusServer";  V="localserver.localdomain.wsus"; T="String" },
        @{ P="HKLM:\SOFTWARE\Policies\Microsoft\Windows\WindowsUpdate"; N="UpdateServiceUrlAlternate"; V="wsus.localdomain.localserver"; T="String" },
        @{ P="HKLM:\SOFTWARE\Policies\Microsoft\Windows\WindowsUpdate\AU"; N="AUOptions";                       V=2; T="DWord" },
        @{ P="HKLM:\SOFTWARE\Policies\Microsoft\Windows\WindowsUpdate\AU"; N="AlwaysAutoRebootAtScheduledTime"; V=0; T="DWord" },
        @{ P="HKLM:\SOFTWARE\Policies\Microsoft\Windows\WindowsUpdate\AU"; N="AutoInstallMinorUpdates";         V=0; T="DWord" },
        @{ P="HKLM:\SOFTWARE\Policies\Microsoft\Windows\WindowsUpdate\AU"; N="NoAutoRebootWithLoggedOnUsers";   V=1; T="DWord" },
        @{ P="HKLM:\SOFTWARE\Policies\Microsoft\Windows\WindowsUpdate\AU"; N="UseWUServer";                     V=1; T="DWord" }
    )
    
    $upOK = 0; $upFail = 0
    foreach ($k in $UpdatePolicy) {
        try {
            $path = $k.P
            if (-not (Test-Path $path)) { New-Item -Path $path -Force -ErrorAction Stop | Out-Null }
            Set-ItemProperty -Path $path -Name $k.N -Value $k.V -Type $k.T -Force -ErrorAction Stop
            $upOK++
        } catch {
            $upFail++
        }
    }
    Write-Step "Applied $upOK update policies" "OK"
    if ($upFail -gt 0) { Write-Step "$upFail entries failed" "WARN" }
    Invoke-Safe -Action { Stop-Service -Name wuauserv -Force -ErrorAction Stop } -Description "stop wuauserv"
    Set-Service -Name wuauserv -StartupType Disabled -ErrorAction SilentlyContinue
    Write-Step "Windows Update service disabled" "OK"
}
    
    $updateTask = Get-ScheduledTask -TaskName "Schedule Scan" -TaskPath "\Microsoft\Windows\UpdateOrchestrator\" -ErrorAction SilentlyContinue
if ($updateTask) {
    if ($WhatIf) {
        Write-Step "WOULD: Disable update tasks." "INFO"
    } else {
        try {
            $updateTask | Disable-ScheduledTask -ErrorAction Stop | Out-Null
            Write-Step "update tasks disabled" "OK"
        } catch {
            Write-Step "Failed to disable update tasks." "FAIL"
        }
    }
}
} else {
    Write-Step "Windows Update skipped" "SKIP"
}

function Stop-EdgePDF {
    if (-not (Get-PSDrive HKCR -ErrorAction SilentlyContinue)) {
        New-PSDrive -Name HKCR -PSProvider Registry -Root HKEY_CLASSES_ROOT | Out-Null
    }
    
    $pdfPaths = @("HKCR:\.pdf", "HKCR:\.pdf\OpenWithProgids", "HKCR:\.pdf\OpenWithList")
    foreach ($path in $pdfPaths) {
        if (Test-Path $path) {
            New-ItemProperty -Path $path -Name "NoOpenWith" -Value "" -PropertyType String -Force | Out-Null
            New-ItemProperty -Path $path -Name "NoStaticDefaultVerb" -Value "" -PropertyType String -Force | Out-Null
        }
    
    }
    $edgeKey = "HKCR:\AppXd4nrz8ff68srnhf9t5a8sbjyar1cr723"
    if (Test-Path $edgeKey) {
        New-ItemProperty -Path $edgeKey -Name "NoOpenWith" -Value "" -PropertyType String -Force | Out-Null
    }
}
}

if (($Section -contains "Edge" -or $Section -contains "All") -and -not (Test-SkipSection "Edge")) {
# ══════════════════════════════════════════════════════════════════════════════
Write-Section "Microsoft Edge Removal"
# ══════════════════════════════════════════════════════════════════════════════
if ($WhatIf) {
    Write-Step "WOULD: Remove Microsoft Edge." "INFO"
} else {
    try {
        Get-Process -Name "*msedge*", "*edgeupdate*" -ErrorAction SilentlyContinue | Stop-Process -Force -ErrorAction SilentlyContinue

        $AppxScript = {
            Get-AppxPackage -AllUsers | Where-Object { $_.Name -match "MicrosoftEdge" -and $_.Name -notmatch "WebView2|EdgeDevToolsClient" } | ForEach-Object { try { $_ | Remove-AppxPackage -AllUsers -ErrorAction Stop } catch {} }
            Get-AppxProvisionedPackage -Online | Where-Object { $_.DisplayName -match "MicrosoftEdge" -and $_.DisplayName -notmatch "WebView2" } | ForEach-Object { try { $_ | Remove-AppxProvisionedPackage -Online -ErrorAction Stop | Out-Null } catch {} }
        }

        if ($PSVersionTable.PSVersion.Major -ge 7) {
            powershell.exe -NoProfile -NonInteractive -Command $AppxScript
        } else {
            & $AppxScript
        }

        $Services = @("edgeupdate", "edgeupdatem", "MicrosoftEdgeElevationService")
        foreach ($Svc in $Services) {
            if (Get-Service -Name $Svc -ErrorAction SilentlyContinue) {
                Stop-Service -Name $Svc -Force -ErrorAction SilentlyContinue
                & sc.exe delete $Svc | Out-Null
            }
        }

        Get-ScheduledTask -TaskPath "\" -ErrorAction SilentlyContinue | 
            Where-Object { $_.TaskName -match "EdgeUpdate" } | 
            Unregister-ScheduledTask -Confirm:$false -ErrorAction SilentlyContinue

        $RegPaths = @(
            "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\Microsoft Edge",
            "HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\Microsoft Edge",
            "HKLM:\SOFTWARE\Microsoft\Edge",
            "HKLM:\SOFTWARE\WOW6432Node\Microsoft\Edge",
            "HKCU:\SOFTWARE\Microsoft\Edge"
        )

        foreach ($Reg in $RegPaths) {
            if (Test-Path $Reg) {
                Remove-Item -Path $Reg -Recurse -Force -ErrorAction SilentlyContinue
            }
        }

        $UpdatePreventionPath = "HKLM:\SOFTWARE\Microsoft\EdgeUpdate"
        if (-not (Test-Path $UpdatePreventionPath)) {
            New-Item -Path $UpdatePreventionPath -Force | Out-Null
        }
        Set-ItemProperty -Path $UpdatePreventionPath -Name "DoNotUpdateToEdgeWithChromium" -Value 1 -Type DWord -Force

        $PathsToRemove = @(
            "${Env:ProgramFiles(x86)}\Microsoft\Edge",
            "${Env:ProgramFiles(x86)}\Microsoft\EdgeCore",
            "$Env:LocalAppData\Microsoft\Edge",
            "$Env:SystemRoot\SystemApps\Microsoft.MicrosoftEdge_8wekyb3d8bbwe"
        )

        foreach ($Path in $PathsToRemove) {
            if (Test-Path $Path) {
                & takeown.exe /f "$Path" /r /d Y 2>$null | Out-Null
                & icacls.exe "$Path" /grant "*S-1-5-32-544:(OI)(CI)F" /T /C /Q 2>$null | Out-Null
                Remove-Item -Path $Path -Recurse -Force -ErrorAction SilentlyContinue
            }
        }

        $EdgeExePath = "${Env:ProgramFiles(x86)}\Microsoft\Edge\Application\msedge.exe"
        if (Test-Path $EdgeExePath) {
            Write-Step "Failed to purge Microsoft Edge." "ERROR"
        } else {
            Write-Step "Microsoft Edge has been removed." "OK"
        }
    }
    catch {
        Write-Step "An error occurred during removal: $_" "ERROR"
    }
}
}


if (($Section -contains "registry" -or $Section -contains "All") -and -not (Test-SkipSection "registry")) {
if (-not $WhatIf) {
Invoke-WebRequest -Uri "https://github.com/hmdepic55-netizen/c/raw/refs/heads/main/blank.ico" -OutFile "C:\Windows\blank.ico" -ErrorAction SilentlyContinue
}
# ══════════════════════════════════════════════════════════════════════════════
Write-Section "Registry Tweaks "
# ══════════════════════════════════════════════════════════════════════════════
$Memory = (Get-CimInstance Win32_PhysicalMemory | Measure-Object Capacity -Sum).Sum / 1KB
Write-Step "Detected RAM: $([math]::Round($Memory/1MB,1)) GB  →  SvcHost threshold set" "INFO"

$VBS = @(
    @{ P="HKLM:\SYSTEM\CurrentControlSet\Control\DeviceGuard";                           N="EnableVirtualizationBasedSecurity";    V=0;        T="DWord"  },
    @{ P="HKLM:\SYSTEM\CurrentControlSet\Control\DeviceGuard\Scenarios\HypervisorEnforcedCodeIntegrity"; N="Enabled";              V=0;        T="DWord"  }
)

$Regkeys = @(
    @{ P="HKLM:\SYSTEM\CurrentControlSet\Control\PriorityControl";                       N="Win32PrioritySeparation";              V=38;       T="DWord"  },
	@{ P="HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\ContentDeliveryManager";       N="ContentDeliveryAllowed";               V=0;        T="DWord"  },
	@{ P="HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\Explorer\Advanced\People";     N="PeopleBand";                           V=0;        T="DWord"  },
    @{ P="HKLM:\SOFTWARE\Policies\Microsoft\Windows\Windows Search";                     N="AllowSearchToUseLocation";             V=0;        T="DWord"  },
    @{ P="HKLM:\SOFTWARE\Policies\Microsoft\Windows\Windows Search";                     N="ConnectedSearchUseWeb";                V=0;        T="DWord"  },
    @{ P="HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\ContentDeliveryManager";       N="OemPreInstalledAppsEnabled";           V=0;        T="DWord"  },
    @{ P="HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\ContentDeliveryManager";       N="PreInstalledAppsEnabled";              V=0;        T="DWord"  },
    @{ P="HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\ContentDeliveryManager";       N="PreInstalledAppsEverEnabled";          V=0;        T="DWord"  },
    @{ P="HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\ContentDeliveryManager";       N="SilentInstalledAppsEnabled";           V=0;        T="DWord"  },
    @{ P="HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\ContentDeliveryManager";       N="SystemPaneSuggestionsEnabled";         V=0;        T="DWord"  },
    @{ P="HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\ContentDeliveryManager";       N="SubscribedContent-310093Enabled";      V=0;        T="DWord"  },
    @{ P="HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\ContentDeliveryManager";       N="SubscribedContent-353694Enabled";      V=0;        T="DWord"  },
    @{ P="HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\ContentDeliveryManager";       N="SubscribedContent-353696Enabled";      V=0;        T="DWord"  },
    @{ P="HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\ContentDeliveryManager";       N="SubscribedContent-338388Enabled";      V=0;        T="DWord"  },
    @{ P="HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\ContentDeliveryManager";       N="RotatingLockScreenOverlayEnabled";     V=0;        T="DWord"  },
    @{ P="HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\ContentDeliveryManager";       N="RotatingLockScreenEnabled";            V=0;        T="DWord"  },
	@{ P="HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\ContentDeliveryManager";       N="SubscribedContent-314559Enabled";      V=0;        T="DWord"  },
    @{ P="HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\ContentDeliveryManager";       N="SubscribedContent-314563Enabled";      V=0;        T="DWord"  },
    @{ P="HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\ContentDeliveryManager";       N="SubscribedContent-338387Enabled";      V=0;        T="DWord"  },
    @{ P="HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\ContentDeliveryManager";       N="SubscribedContent-338389Enabled";      V=0;        T="DWord"  },
    @{ P="HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\ContentDeliveryManager";       N="SubscribedContent-338393Enabled";      V=0;        T="DWord"  },
    @{ P="HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\ContentDeliveryManager";       N="FeatureManagementEnabled";             V=0;        T="DWord"  },
    @{ P="HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\ContentDeliveryManager";       N="RemediationRequired";                  V=0;        T="DWord"  },
	@{ P="HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\Explorer\Advanced";            N="ShowSyncProviderNotifications";        V=0;        T="DWord"  },
	@{ P="HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\Privacy";                      N="TailoredExperiencesWithDiagnosticDataEnabled"; V=0; T="DWord" },
    @{ P="HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Diagnostics\DiagTrack\EventTranscriptKey"; N="EnableEventTranscript";    V=0;        T="DWord"  },
    @{ P="HKLM:\SYSTEM\CurrentControlSet\Control\WMI\AutoLogger\AutoLogger-Diagtrack-Listener"; N="Start";                         V=0;        T="DWord"  },
    @{ P="HKLM:\SYSTEM\CurrentControlSet\Control\WMI\AutoLogger\SQMLogger";              N="Start";                                V=0;        T="DWord"  },
    @{ P="HKLM:\SOFTWARE\Policies\Microsoft\Windows\AppCompat";                          N="AITEnable";                            V=0;        T="DWord"  },
    @{ P="HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\CapabilityAccessManager\ConsentStore\appDiagnostics";     N="Value";     V="Deny";   T="String" },
    @{ P="HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\CapabilityAccessManager\ConsentStore\appDiagnostics";     N="Value";     V="Deny";   T="String" },
    @{ P="HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\CapabilityAccessManager\ConsentStore\userNotificationListener"; N="Value"; V="Deny"; T="String" },
    @{ P="HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\CapabilityAccessManager\ConsentStore\userAccountInformation"; N="Value"; V="Deny";   T="String" },
    @{ P="HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\CapabilityAccessManager\ConsentStore\userAccountInformation"; N="Value"; V="Deny";   T="String" },
    @{ P="HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\DeviceAccess\Global\LooselyCoupled"; N="Value";                          V="Deny";   T="String" },
    @{ P="HKCU:\Control Panel\Accessibility\Keyboard Response";                        N="Flags";                                  V="122";     T="String" },
    @{ P="HKCU:\Control Panel\Accessibility\ToggleKeys";                               N="Flags";                                  V="58";      T="String" },
    @{ P="HKCU:\Control Panel\Mouse";                                                  N="MouseHoverTime";                         V="250";     T="String" },
    @{ P="HKCU:\SOFTWARE\Microsoft\Input\TIPC";                                        N="Enabled";                                V=0;         T="DWord" },
    @{ P="HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Device Metadata";            N="PreventDeviceMetadataFromNetwork";       V=1;         T="DWord" },
	@{ P="HKLM:\SYSTEM\CurrentControlSet\Control";                                     N="WaitToKillServiceTimeout";               V="4000";    T="String" },
    @{ P="HKCU:\Control Panel\Desktop";                                                N="LowLevelHooksTimeout";                   V=1000;      T="DWord" },
    @{ P="HKLM:\SYSTEM\CurrentControlSet\Control\Session Manager\Memory Management";   N="ClearPageFileAtShutdown";                V=0;         T="DWord" },
    @{ P="Registry::HKEY_USERS\.DEFAULT\Control Panel\Desktop";                        N="LowLevelHooksTimeout";                   V=1000;      T="DWord" },
    @{ P="HKCU:\SOFTWARE\Microsoft\Siuf\Rules";                                        N="NumberOfSIUFInPeriod";                   V=0;         T="DWord" },
    @{ P="Registry::HKEY_USERS\.DEFAULT\Control Panel\Desktop";                        N="MenuShowDelay";                          V=1;         T="DWord" },
    @{ P="HKCU:\Control Panel\Desktop";                                                N="AutoEndTasks";                           V=1;         T="DWord" },
    @{ P="HKLM:\SOFTWARE\Policies\Microsoft\Windows\CloudContent";                     N="DisableTailoredExperiencesWithDiagnosticData"; V=1; T="DWord" },
    @{ P="HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Diagnostics\DiagTrack\EventTranscriptKey"; N="EnableEventTranscript";    V=0;        T="DWord"  },
    @{ P="HKLM:\SOFTWARE\Policies\Microsoft\Windows\CloudContent";                       N="DisableThirdPartySuggestions";         V=1;        T="DWord"  },
    @{ P="HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\ContentDeliveryManager";       N="SubscribedContentEnabled";             V=0;        T="DWord"  },
    @{ P="HKLM:\SOFTWARE\Microsoft\PolicyManager\default\WiFi\AllowWiFiHotSpotReporting"; N="Value";                               V=0;        T="DWord"  },
    @{ P="HKLM:\SOFTWARE\Microsoft\PolicyManager\default\WiFi\AllowAutoConnectToWiFiSenseHotspots"; N="Value";                     V=0;        T="DWord"  },
    @{ P="HKLM:\SOFTWARE\Microsoft\WcmSvc\wifinetworkmanager\config";                    N="AutoConnectAllowedOEM";                V=0;        T="DWord"  },
	@{ P="HKCU:\SOFTWARE\Policies\Microsoft\Windows\CurrentVersion\PushNotifications";   N="NoTileApplicationNotification";        V=1;        T="DWord"  },
    @{ P="HKLM:\SYSTEM\CurrentControlSet\Control";                                       N="SvcHostSplitThresholdInKB";            V=$Memory;  T="DWord"  },
    @{ P="HKLM:\SYSTEM\CurrentControlSet\Services\Ndu";                                 N="Start";                                V=4;        T="DWord"  },
    @{ P="HKLM:\SYSTEM\CurrentControlSet\Control\Session Manager\kernel";                N="SerializeTimerExpiration";             V=0;        T="DWord"  },
    @{ P="HKLM:\SYSTEM\CurrentControlSet\Control\Session Manager\Quota System";          N="EnableCpuQuota";                       V=0;        T="DWord"  },
    @{ P="HKLM:\SYSTEM\CurrentControlSet\Control\Session Manager";                       N="DisableWpbtExecution";                 V=1;        T="DWord"  },
    @{ P="HKLM:\SYSTEM\CurrentControlSet\Control\Power";                                 N="CoalescingTimerInterval";              V=0;        T="DWord"  },
    @{ P="HKLM:\SYSTEM\CurrentControlSet\Control\Power";                                 N="EventProcessorEnabled";                V=0;        T="DWord"  },
    @{ P="HKLM:\SYSTEM\CurrentControlSet\Control\Power";                                 N="PlatformAoAcOverride";                 V=0;        T="DWord"  },
    @{ P="HKLM:\SYSTEM\CurrentControlSet\Services\mouclass\Parameters";                  N="MouseDataQueueSize";                   V=20;       T="DWord"  },
    @{ P="HKLM:\SYSTEM\CurrentControlSet\Services\kbdclass\Parameters";                  N="KeyboardDataQueueSize";                V=20;       T="DWord"  },
    @{ P="HKLM:\SYSTEM\CurrentControlSet\Control\Session Manager\Memory Management";     N="DisablePagingExecutive";               V=1;        T="DWord"  },
    @{ P="HKCU:\Control Panel\Desktop\WindowMetrics";                                    N="MinAnimate";                           V=0;        T="String" },
    @{ P="HKLM:\SYSTEM\CurrentControlSet\Control\Session Manager\Memory Management";     N="FeatureSettingsOverride";              V=3;        T="DWord"  },
    @{ P="HKLM:\SYSTEM\CurrentControlSet\Control\Session Manager\Memory Management";     N="FeatureSettingsOverrideMask";          V=3;        T="DWord"  },
    @{ P="HKLM:\SYSTEM\CurrentControlSet\Control\Session Manager\Memory Management";     N="LargeSystemCache";                     V=0;        T="DWord"  },
    @{ P="HKLM:\SYSTEM\CurrentControlSet\Control\Session Manager\Segment Heap";          N="Enabled";                              V=1;        T="DWord"  },
    @{ P="HKLM:\SYSTEM\CurrentControlSet\Control\Session Manager\Segment Heap";          N="OverrideServerSKU";                    V=1;        T="DWord"  },
    @{ P="HKLM:\SYSTEM\CurrentControlSet\Control\Session Manager\Power";                 N="HiberbootEnabled";                     V=0;        T="DWord"  },
    @{ P="HKLM:\SYSTEM\CurrentControlSet\Control\Session Manager\Power";                 N="HibernateEnabled";                     V=0;        T="DWord"  },
    @{ P="HKLM:\SYSTEM\CurrentControlSet\Control\GraphicsDrivers";                       N="HwSchMode";                            V=2;        T="DWord"  },
    @{ P="HKLM:\SYSTEM\CurrentControlSet\Control\Remote Assistance";                     N="fAllowToGetHelp";                      V=0;        T="DWord"  },
	@{ P="HKLM:\SOFTWARE\Policies\Microsoft\Psched";                                     N="NonBestEffortLimit";                   V=0;        T="DWord"  },
    @{ P="HKLM:\SYSTEM\CurrentControlSet\Control\GraphicsDrivers";                       N="DisableOverlays";                      V=1;        T="DWord"  },
    @{ P="HKLM:\SYSTEM\CurrentControlSet\Control\GraphicsDrivers\Scheduler";             N="EnablePreemption";                     V=1;        T="DWord"  },
    @{ P="HKLM:\SOFTWARE\Microsoft\Windows\Dwm";                                         N="OverlayTestMode";                      V=0;        T="DWord"  },
    @{ P="HKLM:\SOFTWARE\Microsoft\Windows\Dwm";                                         N="OverlayMinFPS";                        V=9999;     T="DWord"  },
    @{ P="HKLM:\SYSTEM\CurrentControlSet\Control\CrashControl";                          N="DisplayParameters";                    V=1;        T="DWord"  },
    @{ P="HKLM:\SYSTEM\CurrentControlSet\Control\CrashControl";                          N="DisableEmoticon";                      V=0;        T="DWord"  },

    # ── Network ──
    @{ P="HKLM:\SYSTEM\CurrentControlSet\Services\Tcpip\Parameters";                     N="MaxUserPort";                          V=65534;    T="DWord"  },
    @{ P="HKLM:\SYSTEM\CurrentControlSet\Services\Tcpip\Parameters";                     N="TcpTimedWaitDelay";                    V=30;       T="DWord"  },
    @{ P="HKLM:\SYSTEM\CurrentControlSet\Services\Tcpip\Parameters";                     N="DefaultTTL";                           V=64;       T="DWord"  },
    @{ P="HKLM:\SYSTEM\CurrentControlSet\Services\Tcpip\Parameters";                     N="TcpAckFrequency";                      V=1;        T="DWord"  },
    @{ P="HKLM:\SYSTEM\CurrentControlSet\Services\Tcpip\Parameters";                     N="TCPNoDelay";                           V=1;        T="DWord"  },
    @{ P="HKLM:\SYSTEM\CurrentControlSet\Services\Tcpip\Parameters";                     N="TcpDelAckTicks";                       V=0;        T="DWord"  },
    @{ P="HKLM:\SYSTEM\CurrentControlSet\Services\Tcpip6\Parameters";                    N="DisabledComponents";                   V=255;      T="DWord"  },
    @{ P="HKLM:\SYSTEM\CurrentControlSet\Services\AFD\Parameters";                       N="FastSendDatagramThreshold";            V=64000;    T="DWord"  },
	@{ P="HKLM:\SYSTEM\CurrentControlSet\Services\AFD\Parameters";                       N="DefaultReceiveWindow";                 V=131072;   T="DWord"  },
	@{ P="HKLM:\SYSTEM\CurrentControlSet\Services\AFD\Parameters";                       N="DefaultSendWindow";                    V=131072;   T="DWord"  },
    @{ P="HKLM:\SYSTEM\CurrentControlSet\Services\NlaSvc\Parameters\Internet";           N="EnableActiveProbing";                  V=0;        T="DWord"  },
	@{ P="HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Multimedia\SystemProfile";  N="NetworkThrottlingIndex";               V=0xFFFFFFFF; T="DWord"},

    # ── System profile ───────
    @{ P="HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Multimedia\SystemProfile";             N="SystemResponsiveness";      V=10;         T="DWord"  },
    @{ P="HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Multimedia\SystemProfile\Tasks\Games"; N="Affinity";                  V=0;          T="DWord"  },
    @{ P="HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Multimedia\SystemProfile\Tasks\Games"; N="Background Only";           V="False";      T="String" },
    @{ P="HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Multimedia\SystemProfile\Tasks\Games"; N="Clock Rate";                V=10000;      T="DWord"  },
    @{ P="HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Multimedia\SystemProfile\Tasks\Games"; N="GPU Priority";              V=8;          T="DWord"  },
    @{ P="HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Multimedia\SystemProfile\Tasks\Games"; N="Priority";                  V=6;          T="DWord"  },
    @{ P="HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Multimedia\SystemProfile\Tasks\Games"; N="Scheduling Category";       V="High";     T="String" },
    @{ P="HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Multimedia\SystemProfile\Tasks\Games"; N="SFIO Priority";             V="High";     T="String" },
    @{ P="HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Multimedia\SystemProfile\Tasks\DisplayPostProcessing"; N="Background Only"; V="False"; T="String" },
    @{ P="HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Multimedia\SystemProfile\Tasks\DisplayPostProcessing"; N="GPU Priority"; V=8;     T="DWord"  },
    @{ P="HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Multimedia\SystemProfile\Tasks\DisplayPostProcessing"; N="Priority";  V=6;        T="DWord"  },
    @{ P="HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Multimedia\SystemProfile\Tasks\DisplayPostProcessing"; N="Scheduling Category";V="High"; T="String" },
    @{ P="HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Windows";                   N="GDIProcessHandleQuota";                V=16384;    T="DWord"  },
    @{ P="HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Windows";                   N="USERProcessHandleQuota";               V=18000;    T="DWord"  },
    @{ P="HKCU:\Software\Microsoft\Windows\CurrentVersion\Search";                       N="BingSearchEnabled";                    V=0;        T="DWord"  },
    @{ P="HKCU:\Software\Microsoft\Windows\CurrentVersion\Search";                       N="CortanaConsent";                       V=0;        T="DWord"  },
    @{ P="HKLM:\SOFTWARE\Policies\Microsoft\InputPersonalization";                       N="RestrictImplicitTextCollection";       V=1;        T="DWord"  },
    @{ P="HKLM:\SOFTWARE\Policies\Microsoft\InputPersonalization";                       N="RestrictImplicitInkCollection";        V=1;        T="DWord"  },
    @{ P="HKCU:\Software\Microsoft\Speech_OneCore\Settings\OnlineSpeechPrivacy";         N="HasAccepted";                          V=0;        T="DWord"  },
	@{ P="HKLM:\Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced";            N="Start_IrisRecommendations";            V=0;        T="Dword"  },
    @{ P="HKLM:\Software\Policies\Microsoft\Windows\Explorer";                           N="NoUseStoreOpenWith";                   V=1;        T="Dword"  },
	@{ P="HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Schedule\Maintenance";      N="MaintenanceDisabled";                  V=1;        T="Dword"  },
	@{ P="HKLM:\SOFTWARE\Policies\Microsoft\OneDrive";                                   N="KFMBlockOptIn";                        V=1;        T="Dword"  },
	@{ P="HKLM:\SOFTWARE\Microsoft\Windows\Windows Error Reporting";                     N="Disabled";                             V=1;        T="Dword"  },
    @{ P="HKLM:\SOFTWARE\Policies\Microsoft\Windows\DataCollection";                     N="AllowTelemetry";                       V=0;        T="DWord"  },
    @{ P="HKLM:\SOFTWARE\Policies\Microsoft\Windows\System";                             N="DisableAcrylicBackgroundOnLogon";      V=1;        T="DWord"  },
    @{ P="HKLM:\SOFTWARE\Policies\Microsoft\Windows\System";                             N="NoRemoteRecursiveFolderAccess";        V=1;        T="DWord"  },
    @{ P="HKLM:\SOFTWARE\Microsoft\Personalization\Settings";                            N="AcceptedPrivacyPolicy";                V=0;        T="DWord"  },
    @{ P="HKLM:\SOFTWARE\Policies\Microsoft\Windows\DeliveryOptimization";               N="DODownloadMode";                       V=0;        T="DWord"  },
    @{ P="HKLM:\SOFTWARE\Policies\Microsoft\Windows\StorageSense";                       N="AllowStorageSense";                    V=0;        T="DWord"  },
    @{ P="HKLM:\SOFTWARE\Microsoft\Tracing";                                             N="MaxFileSize";                          V=0;        T="DWord"  },
    @{ P="HKLM:\SOFTWARE\Microsoft\Tracing";                                             N="EnableTracing";                        V=0;        T="DWord"  },
    @{ P="HKLM:\SOFTWARE\Microsoft\Windows\Windows Error Reporting";                     N="DontShowUI";                           V=1;        T="DWord"  },
    @{ P="HKLM:\SOFTWARE\Microsoft\Windows\Windows Error Reporting";                     N="LoggingDisabled";                      V=1;        T="DWord"  },
    @{ P="HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\DriverSearching";              N="SearchOrderConfig";                    V=0;        T="DWord"  },
    @{ P="HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Device Installer";             N="DisableCoInstallers";                  V=1;        T="DWord"  },
    @{ P="HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\System";              N="VerboseStatus";                        V=0;        T="DWord"  },
	
	# ── Edge policies ────────────────
    @{ P="HKLM:\SOFTWARE\Policies\Microsoft\EdgeUpdate";                                 N="CreateDesktopShortcutDefault";         V=0;        T="DWord"  },
    @{ P="HKLM:\SOFTWARE\Policies\Microsoft\Edge";                                       N="PersonalizationReportingEnabled";      V=0;        T="DWord"  },
    @{ P="HKLM:\SOFTWARE\Policies\Microsoft\Edge";                                       N="ShowRecommendationsEnabled";           V=0;        T="DWord"  },
    @{ P="HKLM:\SOFTWARE\Policies\Microsoft\Edge";                                       N="HideFirstRunExperience";               V=1;        T="DWord"  },
    @{ P="HKLM:\SOFTWARE\Policies\Microsoft\Edge";                                       N="UserFeedbackAllowed";                  V=0;        T="DWord"  },
    @{ P="HKLM:\SOFTWARE\Policies\Microsoft\Edge";                                       N="ConfigureDoNotTrack";                  V=1;        T="DWord"  },
    @{ P="HKLM:\SOFTWARE\Policies\Microsoft\Edge";                                       N="AlternateErrorPagesEnabled";           V=0;        T="DWord"  },
    @{ P="HKLM:\SOFTWARE\Policies\Microsoft\Edge";                                       N="EdgeCollectionsEnabled";               V=0;        T="DWord"  },
    @{ P="HKLM:\SOFTWARE\Policies\Microsoft\Edge";                                       N="EdgeShoppingAssistantEnabled";         V=0;        T="DWord"  },
    @{ P="HKLM:\SOFTWARE\Policies\Microsoft\Edge";                                       N="MicrosoftEdgeInsiderPromotionEnabled"; V=0;        T="DWord"  },
    @{ P="HKLM:\SOFTWARE\Policies\Microsoft\Edge";                                       N="ShowMicrosoftRewards";                 V=0;        T="DWord"  },
    @{ P="HKLM:\SOFTWARE\Policies\Microsoft\Edge";                                       N="WebWidgetAllowed";                     V=0;        T="DWord"  },
    @{ P="HKLM:\SOFTWARE\Policies\Microsoft\Edge";                                       N="DiagnosticData";                       V=0;        T="DWord"  },
    @{ P="HKLM:\SOFTWARE\Policies\Microsoft\Edge";                                       N="WalletDonationEnabled";                V=0;        T="DWord"  },
    @{ P="HKLM:\SOFTWARE\Policies\Microsoft\Edge\ExtensionInstallBlocklist";             N="1";                                    V="ofefcgjbeghpigppfmkologfjadafddi"; T="String"},
	
	# ── Brave policies ─────────────────────
    @{ P="HKLM:\SOFTWARE\Policies\BraveSoftware\Brave";                                  N="BraveRewardsDisabled";                 V=1;        T="DWord" },
    @{ P="HKLM:\SOFTWARE\Policies\BraveSoftware\Brave";                                  N="BraveWalletDisabled";                  V=1;        T="DWord" },
    @{ P="HKLM:\SOFTWARE\Policies\BraveSoftware\Brave";                                  N="BraveVPNDisabled";                     V=1;        T="DWord" },
    @{ P="HKLM:\SOFTWARE\Policies\BraveSoftware\Brave";                                  N="BraveStatsPingEnabled";                V=0;        T="DWord" },
    @{ P="HKLM:\SOFTWARE\Policies\BraveSoftware\Brave";                                  N="BraveNewsDisabled";                    V=1;        T="DWord" },
    @{ P="HKLM:\SOFTWARE\Policies\BraveSoftware\Brave";                                  N="BraveTalkDisabled";                    V=1;        T="DWord" },
    @{ P="HKLM:\SOFTWARE\Policies\BraveSoftware\Brave";                                  N="TorDisabled";                          V=1;        T="DWord" },
    @{ P="HKLM:\SOFTWARE\Policies\BraveSoftware\Brave";                                  N="BraveP3AEnabled";                      V=0;        T="DWord" },
    @{ P="HKLM:\SOFTWARE\Policies\BraveSoftware\Brave";                                  N="UrlKeyedAnonymizedDataCollectionEnabled"; V=0;     T="DWord" },
    @{ P="HKLM:\SOFTWARE\Policies\BraveSoftware\Brave";                                  N="SafeBrowsingExtendedReportingEnabled"; V=0;        T="DWord" },
	
	# ── Firefox policies ──────────────────────
    @{ P="HKLM:\SOFTWARE\Policies\Mozilla\Firefox";                                      N="DisableTelemetry";                     V=1;         T="DWord" },
    @{ P="HKLM:\SOFTWARE\Policies\Mozilla\Firefox";                                      N="DisableFirefoxStudies";                V=1;         T="DWord" },
    @{ P="HKLM:\SOFTWARE\Policies\Mozilla\Firefox";                                      N="DisablePocket";                        V=1;         T="DWord" },
    @{ P="HKLM:\SOFTWARE\Policies\Mozilla\Firefox";                                      N="DisableFeedbackCommands";              V=1;         T="DWord" },
    @{ P="HKLM:\SOFTWARE\Policies\Mozilla\Firefox";                                      N="DontCheckDefaultBrowser";              V=1;         T="DWord" },
    @{ P="HKLM:\SOFTWARE\Policies\Mozilla\Firefox";                                      N="NoDefaultBookmarks";                   V=1;         T="DWord" },
    @{ P="HKLM:\SOFTWARE\Policies\Mozilla\Firefox\EnableTrackingProtection";             N="Value";                                V=1;         T="DWord" },
    @{ P="HKLM:\SOFTWARE\Policies\Mozilla\Firefox\EnableTrackingProtection";             N="Locked";                               V=0;         T="DWord" },
    @{ P="HKLM:\SOFTWARE\Policies\Mozilla\Firefox\EnableTrackingProtection";             N="Cryptomining";                         V=1;         T="DWord" },
    @{ P="HKLM:\SOFTWARE\Policies\Mozilla\Firefox\EnableTrackingProtection";             N="Fingerprinting";                       V=1;         T="DWord" },
    @{ P="HKLM:\SOFTWARE\Policies\Mozilla\Firefox\UserMessaging";                        N="WhatsNew";                             V=0;         T="DWord" },
    @{ P="HKLM:\SOFTWARE\Policies\Mozilla\Firefox\UserMessaging";                        N="ExtensionRecommendations";             V=0;         T="DWord" },
    @{ P="HKLM:\SOFTWARE\Policies\Mozilla\Firefox\UserMessaging";                        N="FeatureRecommendations";               V=0;         T="DWord" },
    @{ P="HKLM:\SOFTWARE\Policies\Mozilla\Firefox\UserMessaging";                        N="UrlbarInterventions";                  V=0;         T="DWord" },
    @{ P="HKLM:\SOFTWARE\Policies\Mozilla\Firefox\UserMessaging";                        N="SkipOnboarding";                       V=1;         T="DWord" },
    @{ P="HKLM:\SOFTWARE\Policies\Mozilla\Firefox\UserMessaging";                        N="MoreFromMozilla";                      V=0;         T="DWord" },

    # ── Search ──────────
    @{ P="HKLM:\SOFTWARE\Policies\Microsoft\Windows\Windows Search";                     N="AllowCortana";                         V=0;        T="DWord"  },
    @{ P="HKLM:\SOFTWARE\Policies\Microsoft\Windows\Windows Search";                     N="DisableWebSearch";                     V=1;        T="DWord"  },
    @{ P="HKLM:\SOFTWARE\Policies\Microsoft\Windows\Windows Search";                     N="ConnectedSearchUseWeb";                V=0;        T="DWord"  },
	
    # ── Appx ِapps ──
    @{ P="HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Appx\AppxAllUserStore\Deprovisioned\Microsoft.AsyncTextService_8wekyb3d8bbwe";               N="(Default)"; V=""; T="String" },
    @{ P="HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Appx\AppxAllUserStore\Deprovisioned\Microsoft.BioEnrollment_cw5n1h2txyewy";                  N="(Default)"; V=""; T="String" },
    @{ P="HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Appx\AppxAllUserStore\Deprovisioned\Microsoft.ECApp_8wekyb3d8bbwe";                          N="(Default)"; V=""; T="String" },
    @{ P="HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Appx\AppxAllUserStore\Deprovisioned\Microsoft.LockApp_cw5n1h2txyewy";                        N="(Default)"; V=""; T="String" },
    @{ P="HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Appx\AppxAllUserStore\Deprovisioned\Microsoft.MicrosoftEdgeDevToolsClient_8wekyb3d8bbwe";    N="(Default)"; V=""; T="String" },
    @{ P="HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Appx\AppxAllUserStore\Deprovisioned\Microsoft.Windows.AddSuggestedFoldersToLibraryDialog_cw5n1h2txyewy"; N="(Default)"; V=""; T="String" },
    @{ P="HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Appx\AppxAllUserStore\Deprovisioned\Microsoft.Windows.AppRep.ChxApp_cw5n1h2txyewy";          N="(Default)"; V=""; T="String" },
    @{ P="HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Appx\AppxAllUserStore\Deprovisioned\Microsoft.Windows.AssignedAccessLockApp_cw5n1h2txyewy";  N="(Default)"; V=""; T="String" },
    @{ P="HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Appx\AppxAllUserStore\Deprovisioned\Microsoft.Windows.CallingShellApp_cw5n1h2txyewy";        N="(Default)"; V=""; T="String" },
    @{ P="HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Appx\AppxAllUserStore\Deprovisioned\Microsoft.Windows.ContentDeliveryManager_cw5n1h2txyewy"; N="(Default)"; V=""; T="String" },
    @{ P="HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Appx\AppxAllUserStore\Deprovisioned\microsoft.windows.narratorquickstart_8wekyb3d8bbwe";     N="(Default)"; V=""; T="String" },
    @{ P="HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Appx\AppxAllUserStore\Deprovisioned\Microsoft.Windows.OOBENetworkCaptivePortal_cw5n1h2txyewy"; N="(Default)"; V=""; T="String" },
    @{ P="HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Appx\AppxAllUserStore\Deprovisioned\Microsoft.Windows.OOBENetworkConnectionFlow_cw5n1h2txyewy";N="(Default)"; V=""; T="String" },
    @{ P="HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Appx\AppxAllUserStore\Deprovisioned\Microsoft.Windows.PeopleExperienceHost_cw5n1h2txyewy";     N="(Default)"; V=""; T="String" },
    @{ P="HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Appx\AppxAllUserStore\Deprovisioned\Microsoft.Windows.PinningConfirmationDialog_cw5n1h2txyewy";N="(Default)"; V=""; T="String" },
    @{ P="HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Appx\AppxAllUserStore\Deprovisioned\Microsoft.Windows.Search_cw5n1h2txyewy";                 N="(Default)"; V=""; T="String" },
    @{ P="HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Appx\AppxAllUserStore\Deprovisioned\Microsoft.Windows.SecHealthUI_cw5n1h2txyewy";            N="(Default)"; V=""; T="String" },
    @{ P="HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Appx\AppxAllUserStore\Deprovisioned\Microsoft.Windows.SecureAssessmentBrowser_cw5n1h2txyewy";N="(Default)"; V=""; T="String" },
    @{ P="HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Appx\AppxAllUserStore\Deprovisioned\Microsoft.Windows.XGpuEjectDialog_cw5n1h2txyewy";        N="(Default)"; V=""; T="String" },
    @{ P="HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Appx\AppxAllUserStore\Deprovisioned\ParentalControls_cw5n1h2txyewy";                         N="(Default)"; V=""; T="String" },
    @{ P="HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Appx\AppxAllUserStore\Deprovisioned\Windows.CBSPreview_cw5n1h2txyewy";                       N="(Default)"; V=""; T="String" },
    @{ P="HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Appx\AppxAllUserStore\Deprovisioned\Dictation";                                              N="(Default)"; V=""; T="String" },
    @{ P="HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Appx\AppxAllUserStore\Deprovisioned\Fonts";                                                  N="(Default)"; V=""; T="String" },
    @{ P="HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Appx\AppxAllUserStore\Deprovisioned\Ninja";                                                  N="(Default)"; V=""; T="String" },
    @{ P="HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Appx\AppxAllUserStore\Deprovisioned\ScreenClipping_Fonts";                                   N="(Default)"; V=""; T="String" },
    @{ P="HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Appx\AppxAllUserStore\Deprovisioned\ScreenClipping_Sounds";                                  N="(Default)"; V=""; T="String" },
    @{ P="HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\CapabilityAccessManager\ConsentStore\location";                                              N="Value";     V="Deny"; T="String" },
    @{ P="HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Sensor\Overrides\{BFA794E4-F964-4FDB-90F6-51056BFE4B44}";                                 N="SensorPermissionState"; V=0; T="DWord" },
    @{ P="HKLM:\SYSTEM\Maps";                                                                                                              N="AutoUpdateEnabled";     V=0; T="DWord" },
    @{ P="HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Explorer\FlyoutMenuSettings";                                                    N="ShowHibernateOption";   V=0; T="DWord" },
	@{ P="HKLM:\SYSTEM\CurrentControlSet\Control\Power\PowerThrottling";                                                                   N="PowerThrottlingOff";    V=1; T="DWord" },
	@{ P="HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\ImmersiveShell";                                                                 N="UseWin32BatteryFlyout"; V=1; T="DWord" },

    # ── Explorer ───────
	@{ P="HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Explorer";                     N="MaxCachedIcons";                     V=8192;                        T="string" },
	@{ P="HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\OperationStatusManager"; N="ConfirmationCheckBoxDoForAll";    V=1;                           T="dword"  },
	@{ P="HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Explorer\Shell Icons";         N="29";                                 V="%windir%\blank.ico";        T="expandstring" },
	@{ P="HKLM:\SOFTWARE\Policies\Microsoft\Windows\System";                             N="EnableActivityFeed";                 V=0;                           T="dword"  },
	@{ P="HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Explorer\VolumeCaches\Thumbnail Cache"; N="Autorun";                   V=0;                           T="Dword"  },
	@{ P="HKLM:\SOFTWARE\Policies\Microsoft\Windows\CurrentVersion\PushNotifications";   N="NoCloudApplicationNotification";     V=1;                           T="DWord"  },
    @{ P="HKLM:\SOFTWARE\Policies\Microsoft\WindowsNotepad";                             N="DisableAIFeatures";                  V=1;                           T="DWord"  },
    @{ P="HKLM:\SYSTEM\CurrentControlSet\Control\FileSystem";                            N="NtfsAllowExtendedCharacter8Dot3Rename";V=0;                         T="DWord"  },
    @{ P="HKLM:\SYSTEM\CurrentControlSet\Control\FileSystem";                            N="LongPathsEnabled";                   V=1;                           T="DWord"  },
    @{ P="Registry::HKEY_CLASSES_ROOT\DesktopBackground\Shell\RestartExplorer";          N="MUIVerb";                            V="Restart Explorer";          T="String" },
    @{ P="Registry::HKEY_CLASSES_ROOT\DesktopBackground\Shell\RestartExplorer";          N="Icon";                               V="%SystemRoot%\explorer.exe"; T="ExpandString" },
    @{ P="Registry::HKEY_CLASSES_ROOT\DesktopBackground\Shell\RestartExplorer";          N="Position";                           V="Bottom";                    T="String" },
    @{ P="Registry::HKEY_CLASSES_ROOT\DesktopBackground\Shell\RestartExplorer";          N="extended";                           V="";                          T="String" },
    @{ P="Registry::HKEY_CLASSES_ROOT\DesktopBackground\Shell\RestartExplorer\command";  N="(Default)";                          V='cmd.exe /c @echo off & echo The explorer.exe process will be terminated & echo. & taskkill /f /im explorer.exe & echo. & echo Done & echo. & echo Press any key to start explorer.exe process & pause>NUL & start explorer.exe & exit'; T="String" },
    @{ P="Registry::HKEY_CLASSES_ROOT\*\shell\GetHash";                                  N="Extended";                           V="";                          T="String" },
    @{ P="Registry::HKEY_CLASSES_ROOT\*\shell\GetHash";                                  N="Icon";                               V="imageres.dll,-5372";        T="String" },
    @{ P="Registry::HKEY_CLASSES_ROOT\*\shell\GetHash";                                  N="MUIVerb";                            V="Get Hash";                  T="String" },
    @{ P="Registry::HKEY_CLASSES_ROOT\*\shell\GetHash\command";                          N="(Default)";                          V='mshta vbscript:createobject("shell.application").shellexecute("pwsh.exe","-noexit -command ""write-host ''%1''; $algs = ''md5'', ''sha1'', ''sha256'', ''sha384'', ''sha512''; foreach($alg in $algs){get-filehash ''%1'' -algorithm $alg | select-object algorithm, hash | format-table -wrap}""","","open",3)(close)'; T="String" },
    @{ P="HKLM:\SOFTWARE\Policies\Microsoft\Windows\Explorer";                           N="HideRecommendedSection";             V=1;                           T="DWord"  },
    @{ P="HKLM:\SOFTWARE\Microsoft\PolicyManager\current\device\Start";                  N="HideRecommendedSection";             V=1;                           T="DWord"  },
    @{ P="HKLM:\SOFTWARE\Microsoft\PolicyManager\current\device\Education";              N="IsEducationEnvironment";             V=1;                           T="DWord"  },
    @{ P="Registry::HKEY_CLASSES_ROOT\*\shell\TakeOwnership";                            N="(Default)";                          V="Take Ownership";            T="String" },
    @{ P="Registry::HKEY_CLASSES_ROOT\*\shell\TakeOwnership";                            N="extended";                           V="";                          T="String" },
	@{ P="HKCU:\Software\Microsoft\Windows\CurrentVersion\Holographic";                  N="FirstRunSucceeded";                  V=0;                           T="DWord"  },
    @{ P="Registry::HKEY_CLASSES_ROOT\*\shell\TakeOwnership";                            N="HasLUAShield";                       V="";                          T="String" },
    @{ P="Registry::HKEY_CLASSES_ROOT\*\shell\TakeOwnership";                            N="NeverDefault";                       V="";                          T="String" },
    @{ P="Registry::HKEY_CLASSES_ROOT\*\shell\TakeOwnership";                            N="NoWorkingDirectory";                 V="";                          T="String" },
    @{ P="Registry::HKEY_CLASSES_ROOT\*\shell\TakeOwnership\command";                    N="(Default)";                          V='powershell.exe -windowstyle hidden -command "Start-Process cmd -ArgumentList ''/c takeown /f \""%1\"" && icacls \""%1\"" /grant *S-1-3-4:F /c /l & pause'' -Verb runAs"'; T="String" },
    @{ P="HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\Serialize";           N="StartupDelayInMSec";                 V=0;          T="DWord" },
    @{ P="HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\Serialize";           N="WaitForIdleState";                   V=0;          T="DWord" },
    @{ P="HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced";            N="ExtendedUIHoverTime";                V=0;          T="DWord" },
    @{ P="HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced";            N="ListviewAlphaSelect";                V=0;          T="DWord" },
    @{ P="HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced";            N="TaskbarEndTask";                     V=1;          T="DWord" },
    @{ P="HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced";            N="LaunchTo";                           V=1;          T="DWord" },
    @{ P="HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced";            N="IsBatteryPercentageEnabled";         V=1;          T="DWord" },
    @{ P="HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced";            N="Hidden";                             V=1;          T="DWord" },
    @{ P="HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced";            N="ShowTaskViewButton";                 V=0;          T="DWord" },
    @{ P="HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced";            N="SeparateProcess";                    V=1;          T="DWord" },
    @{ P="HKCU:\Software\Classes\CLSID\{f874310e-b6b7-47dc-bc84-b9e6b38f5903}";          N="System.IsPinnedToNameSpaceTree";     V=0;          T="DWord" },
    @{ P="HKCU:\Control Panel\Accessibility\MouseKeys";                                  N="Flags";                              V="0";        T="String" },
    @{ P="HKCU:\Control Panel\Accessibility\StickyKeys";                                 N="Flags";                              V="506";      T="String" },
    @{ P="HKCU:\Control Panel\Accessibility";                                            N="DynamicScrollbars";                  V=0;          T="DWord" },
    @{ P="HKCU:\Control Panel\Desktop";                                                  N="ScreenSaveActive";                   V="0";        T="String" },
    @{ P="HKCU:\Control Panel\Desktop";                                                  N="ScreenSaveTimeOut";                  V="0";        T="String" },
    @{ P="HKCU:\Control Panel\Desktop";                                                  N="MenuShowDelay";                      V="0";        T="String" },
    @{ P="HKCU:\Control Panel\Desktop";                                                  N="UserPreferencesMask";                V=[byte[]](158, 62, 7, 128, 18, 0, 0, 0); T="Binary" },
	@{ P="HKCU:\Control Panel\Desktop";                                                  N="HungAppTimeout";                     V="4000";     T="String" },
    @{ P="HKCU:\Control Panel\Desktop";                                                  N="WaitToKillAppTimeout";               V="4000";     T="String" },
    @{ P="HKCU:\Control Panel\Keyboard";                                                 N="InitialKeyboardIndicators";          V="2";        T="String" },
    @{ P="Registry::HKEY_USERS\.Default\Control Panel\Keyboard";                         N="InitialKeyboardIndicators";          V="2";        T="String" },
    @{ P="HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\Notifications\Settings";       N="NOC_GLOBAL_SETTING_ALLOW_NOTIFICATION_SOUND"; V=0; T="DWord" },
    @{ P="HKCU:\SOFTWARE\Policies\Microsoft\Windows\Explorer";                           N="DisableNotificationCenter";          V=1;          T="DWord" },
    @{ P="HKCU:\Software\Microsoft\Windows\CurrentVersion\PushNotifications";            N="ToastEnabled";                       V=0;          T="DWord" },
    @{ P="HKCU:\Software\Microsoft\Windows\CurrentVersion\BackgroundAccessApplications"; N="GlobalUserDisabled";                 V=1;          T="DWord" },
    @{ P="HKCU:\Software\Microsoft\Windows\CurrentVersion\AdvertisingInfo";              N="Enabled";                            V=0;          T="DWord" },
    @{ P="HKCU:\Software\Microsoft\Windows\CurrentVersion\CrossDeviceResume\Configuration"; N="IsResumeAllowed";                 V=0;          T="DWord" },
    @{ P="HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\Themes\Personalize";           N="AppsUseLightTheme";                  V=0;          T="DWord" },
    @{ P="HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\Themes\Personalize";           N="SystemUsesLightTheme";               V=0;          T="DWord" },
    @{ P="HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\Themes\Personalize";           N="ColorPrevalence";                    V=0;          T="DWord" },
    @{ P="HKCU:\SOFTWARE\Policies\Microsoft\Power\PowerSettings\f15576e8-98b7-4186-b944-eafa664402d9"; N="ACSettingIndex";       V=1;          T="DWord" },
    @{ P="HKCU:\SOFTWARE\Microsoft\Office\16.0\Outlook\Preferences";                     N="UseNewOutlook";                      V=0;          T="DWord" },
    @{ P="HKCU:\Software\Microsoft\Office\16.0\Outlook\Options\General";                 N="HideNewOutlookToggle";               V=1;          T="DWord" },
	@{ P="HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\Explorer\Advanced";            N="HideFileExt";                        V=0;          T="DWord" },
    @{ P="HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\Explorer\Advanced";            N="LaunchTo";                           V=1;          T="DWord" },
    @{ P="HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\Explorer\Advanced";            N="TaskbarAl";                          V=0;          T="DWord" },
    @{ P="HKCU:\Software\Microsoft\Windows\CurrentVersion\Search";                       N="SearchboxTaskbarMode";               V=0;          T="DWord" },
    @{ P="HKLM:\SOFTWARE\Policies\Microsoft\Windows\Explorer";                           N="DisableSearchBoxSuggestions";        V=1;          T="DWord" },
    @{ P="HKCU:\Control Panel\Desktop";                                                  N="JPEGImportQuality";                  V=100;        T="DWord" },
    @{ P="HKLM:\System\CurrentControlSet\Control\GraphicsDrivers";                       N="TdrDelay";                           V=8;          T="DWord" },
    @{ P="HKCU:\Control Panel\Mouse";                                                    N="MouseSpeed";                         V=0;          T="String" },
    @{ P="HKCU:\Control Panel\Mouse";                                                    N="MouseThreshold1";                    V=0;          T="String" },
    @{ P="HKCU:\Control Panel\Mouse";                                                    N="MouseThreshold2";                    V=0;          T="String" },
    @{ P="HKLM:\SOFTWARE\Policies\Microsoft\Windows\DataCollection";                     N="MaxTelemetryAllowed";                V=0;          T="DWord" },
    @{ P="HKLM:\SOFTWARE\Policies\Microsoft\SQMClient\Windows";                          N="CEIPEnable";                         V=0;          T="DWord" },
    @{ P="HKLM:\SOFTWARE\Policies\Microsoft\AppV\CEIP";                                  N="CEIPEnable";                         V=0;          T="DWord" },
    @{ P="HKLM:\SOFTWARE\Microsoft\PolicyManager\default\System\AllowExperimentation";   N="Value";                              V=0;          T="DWord" },
    @{ P="HKLM:\SOFTWARE\Policies\Microsoft\Windows\AppCompat";                          N="AllowTelemetry";                     V=0;          T="DWord" },
    @{ P="HKLM:\SOFTWARE\Policies\Microsoft\Windows\AppCompat";                          N="DisableUAR";                         V=1;          T="DWord" },
    @{ P="HKLM:\SOFTWARE\Policies\Microsoft\Windows\AdvertisingInfo";                    N="DisabledByGroupPolicy";              V=1;          T="DWord" },
    @{ P="HKLM:\SOFTWARE\Policies\Microsoft\Windows\CloudContent";                       N="DisableWindowsConsumerFeatures";     V=1;          T="DWord" },
    @{ P="HKLM:\SOFTWARE\Policies\Microsoft\Windows\CloudContent";                       N="DisableSoftLanding";                 V=1;          T="DWord" },
    @{ P="HKLM:\SOFTWARE\Policies\Microsoft\Windows\CloudContent";                       N="DisableCloudOptimizedContent";       V=1;          T="DWord" },
    @{ P="HKLM:\SOFTWARE\Policies\Microsoft\Windows\WindowsAI";                          N="DisableAIDataAnalysis";              V=1;          T="DWord" },
    @{ P="HKLM:\SOFTWARE\Policies\Microsoft\Windows\WindowsAI";                          N="TurnOffWindowsCopilot";              V=1;          T="DWord" },
    @{ P="HKLM:\SOFTWARE\Policies\Microsoft\InputPersonalization";                       N="AllowInputPersonalization";          V=0;          T="DWord" },
    @{ P="HKLM:\SOFTWARE\Policies\Microsoft\InputPersonalization\TrainedDataStore";      N="HarvestContacts";                    V=0;          T="DWord" },
    @{ P="HKLM:\SOFTWARE\Policies\Microsoft\Windows\TabletPC";                           N="PreventHandwritingDataSharing";      V=1;          T="DWord" },
    @{ P="HKLM:\Software\Microsoft\Windows\CurrentVersion\Policies\TextInput";           N="AllowLinguisticDataCollection";      V=0;          T="DWord" },
    @{ P="HKLM:\SOFTWARE\Policies\Microsoft\Windows\System";                             N="AllowCrossDeviceClipboard";          V=0;          T="DWord" },
    @{ P="HKLM:\SOFTWARE\Policies\Microsoft\Windows\System";                             N="UploadUserActivities";               V=0;          T="DWord" },
    @{ P="HKLM:\SOFTWARE\Policies\Microsoft\Windows\System";                             N="PublishUserActivities";              V=0;          T="DWord" },
    @{ P="HKLM:\SOFTWARE\Policies\Microsoft\Windows\WDI\{9c5a40da-b965-4fc3-8781-88dd50a6299d}"; N="ScenarioExecutionEnabled";   V=0;          T="DWord" },
    @{ P="HKLM:\SOFTWARE\Policies\Microsoft\DeviceHealthAttestationService";             N="EnableDeviceHealthAttestationService"; V=0;        T="DWord" },
    @{ P="HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\Explorer";            N="NoInstrumentation";                    V=1;        T="DWord" },
    @{ P="HKLM:\Software\Policies\Microsoft\Windows\LocationAndSensors";                 N="DisableLocation";                      V=1;        T="DWord" },
    @{ P="HKLM:\SOFTWARE\Policies\Microsoft\Windows\OOBE";                               N="DisablePrivacyExperience";             V=1;        T="DWord" },
    @{ P="HKCU:\Control Panel\International\User Profile";                               N="HttpAcceptLanguageOptOut";             V=1;        T="DWord" },
    @{ P="HKCU:\Software\Classes\Local Settings\Software\Microsoft\Windows\Shell\Bags\AllFolders\Shell"; N="FolderType";           V="NotSpecified"; T="String" },
    @{ P="HKCU:\Software\Policies\Microsoft\Office\16.0\Outlook\Options\General";        N="DoNewOutlookAutoMigration";            V=0;          T="DWord" }
)
if ($Script:IsWin11) {
    $Regkeys += @{ P="HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced"; N="TaskbarSi"; V=0; T="DWord" }
}
 $objects32 = "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Explorer\MyComputer\NameSpace\{0DB7E03F-FC29-4DC6-9020-FF41B59E513A}"
 $objects64 = "HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Explorer\MyComputer\NameSpace\{0DB7E03F-FC29-4DC6-9020-FF41B59E513A}"
if ($WhatIf) {
    Write-Step "WOULD: Remove 3D Objects folder entries" "INFO"
} else {
    New-Item -Path $Script:RegBackupDir -ItemType Directory -Force -ErrorAction SilentlyContinue | Out-Null
    foreach ($obj in @(
        @{ PS = $objects32; Reg = "HKLM\SOFTWARE\Microsoft\Windows\CurrentVersion\Explorer\MyComputer\NameSpace\{0DB7E03F-FC29-4DC6-9020-FF41B59E513A}";  File = "del_3dobjects32.reg" },
        @{ PS = $objects64; Reg = "HKLM\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Explorer\MyComputer\NameSpace\{0DB7E03F-FC29-4DC6-9020-FF41B59E513A}"; File = "del_3dobjects64.reg" }
    )) {
        if (Test-Path $obj.PS) {
            & reg.exe export $obj.Reg "$($Script:RegBackupDir)\$($obj.File)" /y 2>$null | Out-Null
            $Script:RegJournal += [pscustomobject]@{ id = "regkey|$($obj.Reg)"; type = "regkey"; path = $obj.PS; backupFile = "$($Script:RegBackupDir)\$($obj.File)"; timestamp = (Get-Date -Format o) }
            Save-RegJournal
            Remove-Item $obj.PS -Recurse -Force -EA SilentlyContinue
        }
    }
    Write-Step "3D Objects folder removed" "OK"
}

function Get-RegTweakCategory {
    param($E)
    $P = [string]$E.P
    $N = [string]$E.N

    # Whole-key AppX packages
    if ($P -like "*AppxAllUserStore*") { return "Appx Deprovision" }
    if ($P -like "*\DesktopBackground\Shell\*" -or $P -like "*\shell\TakeOwnership\*") { return "Context Menu Extras" }
    # Privacy / telemetry
    if ($P -like "*\ContentDeliveryManager*" -or
        $P -like "*\DataCollection*"          -or
        $P -like "*\Siuf\Rules*"              -or
        $P -like "*InputPersonalization*"     -or
        $P -like "*OnlineSpeechPrivacy*"      -or
        $P -like "*\CloudContent*"            -or
        $P -like "*AdvertisingInfo*"          -or
        $P -like "*\Device Metadata*"         -or
        $P -like "*Windows Error Reporting*"  -or
        $P -like "*\Tracing*"                 -or
        $P -like "*\TabletPC*"                -or
        $P -like "*\WifiSense*"               -or
        $N -in @("HarvestContacts","EnableEventTranscript","AcceptedPrivacyPolicy",
                 "HttpAcceptLanguageOptOut","DoNotShowFeedbackNotifications",
                 "TailoredExperiencesWithDiagnosticDataEnabled","Start_IrisRecommendations")) { return "Privacy & Telemetry" }
    # Security
    if ($P -like "*\DeviceGuard*" -or $P -like "*\HypervisorEnforcedCodeIntegrity*" -or
        $N -in @("DisableWpbtExecution","fAllowToGetHelp")) { return "Security & Hardening" }
    # Browser
    if ($P -like "*Policies\Microsoft\Edge*" -or $P -like "*\EdgeUpdate*" -or
        $P -like "*Policies\Mozilla*"        -or $P -like "*Firefox*"   -or
        $N -like "*Outlook*") { return "Browsers & Office" }
    # GPU
    if ($P -like "*\SystemProfile*"     -or $P -like "*GameDVR*" -or $P -like "*\Microsoft\GameBar*" -or
        $N -in @("GameDVR_Enabled","AppCaptureEnabled","NetworkThrottlingIndex",
                 "HwSchMode","DisableOverlays","OverlayTestMode","OverlayMinFPS","EnablePreemption")) { return "Gaming & GPU" }
    # Network
    if ($P -like "*\Tcpip\*" -or $P -like "*\Tcpip6\*" -or $P -like "*\AFD\*" -or
        $P -like "*\Psched*" -or $P -like "*\Ndu\*" -or $N -eq "EnableActiveProbing") { return "Network" }
    # Search / Bing / Cortana
    if ($N -in @("BingSearchEnabled","CortanaConsent","ConnectedSearchUseWeb",
                 "DisableSearchBoxSuggestions","AllowSearchToUseLocation","AllowCortana")) { return "Search & Bing" }
    # Notifications
    if ($P -like "*\PushNotifications*" -or
        $N -like "NOC_*" -or
        $N -in @("ToastEnabled","NoTileApplicationNotification","GlobalUserDisabled")) { return "Notifications" }
    # Explorer / Taskbar / Start / Themes / Accessibility
    if ($P -like "*\Explorer\Advanced*"           -or $P -like "*\Taskband*"          -or
        $P -like "*\Explorer\Start Menu*"         -or $P -like "*\Themes\*"           -or
        $P -like "*\Control Panel\Accessibility*" -or
        $N -in @("PeopleBand","ShowTaskViewButton","SeparateProcess","HideFileExt","LaunchTo",
                 "TaskbarAl","SearchboxTaskbarMode","TaskbarEndTask","ListviewAlphaSelect",
                 "ExtendedUIHoverTime","IsBatteryPercentageEnabled","Hidden",
                 "AppsUseLightTheme","SystemUsesLightTheme","ColorPrevalence",
                 "DynamicScrollbars","FolderType","NoUseStoreOpenWith",
                 "DisableNotificationCenter")) { return "Explorer & Taskbar" }
    # Drivers / storage 
    if ($N -in @("SearchOrderConfig","DriverSearching","PreventDeviceMetadataFromNetwork",
                 "DisableCoInstallers","MaintenanceDisabled","Schedule MaintenanceDisabled") -or
        $P -like "*\DeliveryOptimization*" -or $P -like "*StorageSense*" -or $P -like "*\StoragePolicy*") { return "Drivers & Maintenance" }
    # Responsiveness / memory / timers / power
    if ($P -like "*\Control Panel\Desktop*" -or
        $P -like "*\Memory Management*"     -or
        $P -like "*PriorityControl*"        -or
        $P -like "*\Session Manager*"       -or
        $P -like "*\CrashControl*"          -or
        $P -like "*\Control\FileSystem*"    -or
        $P -like "*\Services\i8042prt*"     -or $P -like "*\Services\kbdclass*" -or $P -like "*\Services\mouclass*" -or
        $N -in @("WaitToKillServiceTimeout","ClearPageFileAtShutdown","LowLevelHooksTimeout",
                 "MenuShowDelay","MouseHoverTime","AutoEndTasks","HungAppTimeout",
                 "WaitToKillAppTimeout","UserPreferencesMask","MinAnimate","ScreenSaveActive",
                 "ScreenSaveTimeOut","InitialKeyboardIndicators","SerializeTimerExpiration",
                 "CoalescingTimerInterval","EnableCpuQuota","PlatformAoAcOverride",
                 "StartupDelayInMSec","WaitForIdleState","FeatureSettingsOverride",
                 "FeatureSettingsOverrideMask","GDIProcessHandleQuota","USERProcessHandleQuota",
                 "SvcHostSplitThresholdInKB","MouseDataQueueSize","KeyboardDataQueueSize",
                 "DisablePagingExecutive","LargeSystemCache","DisplayParameters")) { return "Performance & Responsiveness" }

    return "General"
}

# --- REGISTRY ENGINE ---
$catOrder = @("Privacy & Telemetry","Performance & Responsiveness","Explorer & Taskbar","Notifications",
              "Search & Bing","Gaming & GPU","Network","Browsers & Office","Security & Hardening",
              "Drivers & Maintenance","Context Menu Extras","Appx Deprovision","General")

$regOK = 0; $regFail = 0

if ($Script:DisableVBS)                 { $Regkeys += $VBS }
$regSeen = @{}
$Regkeys = @($Regkeys | Where-Object {
    $k = "$($_.P)|$($_.N)"
    if ($regSeen.ContainsKey($k)) { $false } else { $regSeen[$k] = $true; $true }
})
$grouped = @($Regkeys | Group-Object { Get-RegTweakCategory $_ })
$ordered = @(foreach ($c in $catOrder) { $grouped | Where-Object Name -eq $c })
$ordered += @($grouped | Where-Object { $_.Name -notin $catOrder })

foreach ($grp in $ordered) {
    if (-not $grp) { continue }
    Write-SubSection "$($grp.Name) — $($grp.Count) tweak$(if ($grp.Count -gt 1) { 's' })"
    foreach ($E in $grp.Group) {
        if (-not ($E -and $E.P -and $E.N -and $E.T)) {
            $regFail++
            Write-Step "SKIPPED malformed entry: $(if ($E -and $E.P) { $E.P } else { '<no path>' })" "WARN"
            continue
        }
        if ($WhatIf) {
            Write-Step "WOULD: Set $($E.N)=$($E.V) at $($E.P)" "INFO"
            $regOK++
            continue
        }
        Save-RegTweakBackup -E $E
        if (-not (Test-Path -LiteralPath $E.P)) { New-RegKeyPath -Path $E.P }
        $r = New-ItemProperty -LiteralPath $E.P -Name $E.N -Value $E.V -PropertyType $E.T -Force -ErrorAction SilentlyContinue
        if ($r) {
            $regOK++
            Write-Host "  [+] $($E.N)" -ForegroundColor DarkGreen
            $loggedVal = if ($E.V -is [byte[]]) { ($E.V -join ',') } else { $E.V }
            Add-Content -LiteralPath "$Script:RegBackupDir\changes.log" -Value "$(Get-Date -Format g) [registry] Set $($E.P) -> $($E.N) = $loggedVal ($($E.T))" -ErrorAction SilentlyContinue
        } else {
            $regFail++
            Write-Host "  [x] $($E.N)" -ForegroundColor DarkRed
        }
    }
}

if ($WhatIf) {
    Write-Step "Previewed $regOK registry entries" "INFO"
} else {
    Write-Step "Applied $regOK registry entries" "OK"
}
if ($regFail -gt 0) { Write-Step "$regFail entries could not be applied :(" "WARN" }
if (-not $WhatIf -and $Script:RegJournal.Count -gt 0) {
    Write-Step "Per-tweak journal saved: $Script:RegJournalPath" "OK"
}
}

if (($Section -contains "hostsblock" -or $Section -contains "All") -and -not (Test-SkipSection "hostsblock")) {
# ══════════════════════════════════════════════════════════════════════════════
    Write-Section "Host File"
# ══════════════════════════════════════════════════════════════════════════════    
    if ($WhatIf) {
        Write-Step "WOULD: Update hosts file." "INFO"
    } else {
        $hostsPath = "$env:SystemRoot\System32\drivers\etc\hosts"
        $backupPath = "$env:USERPROFILE\Desktop\hosts.backup"
        
        if (Test-Path $hostsPath) {
            Copy-Item $hostsPath $backupPath -Force
            Write-Step "Backup saved to: $backupPath" "OK"
        }
        
             $urls = @()
                $urls += @{ Url = "https://raw.githubusercontent.com/crazy-max/WindowsSpyBlocker/master/data/hosts/spy.txt"; Hash = "709C00D24F5A50DAB46CE18D8B1CD175DB4593DC7F65623ED89070075A85A3A0" }

                $urls += @{ Url = "https://raw.githubusercontent.com/StevenBlack/hosts/master/hosts"; Hash = "36785F9447AE5B56498E9E73BC355529E560359DEBA452F1A208C99AB234C716" }

            
            $combinedContent = "#ultimate hosts`r`n"
            $allValid = $true
            
            foreach ($item in $urls) {
                try {
                    Write-Step "Downloading: $(Split-Path $item.Url -Leaf)" "WAIT"
                    $response = Invoke-WebRequest -Uri $item.Url -UseBasicParsing -ErrorAction Stop
                    $content = $response.Content
                    $bytes = [System.Text.Encoding]::UTF8.GetBytes($content)
                    $hash = (Get-FileHash -InputStream ([System.IO.MemoryStream]::new($bytes)) -Algorithm SHA256).Hash
                    
                    if ($hash -eq $item.Hash) {
                        Write-Step "Hash verified for $(Split-Path $item.Url -Leaf)" "OK"
                        $combinedContent += "`r`n# Source: $($item.Url)`r`n$content`r`n"
                    } else {
                        Write-Step "Hash MISMATCH for $(Split-Path $item.Url -Leaf) – expected $($item.Hash), got $hash" "FAIL"
                        $allValid = $false
                    }
                } catch {
                    Write-Step "Failed to download: $($item.Url) – $($_.Exception.Message)" "FAIL"
                    $allValid = $false
                }
            }
            
            if ($allValid) {
                $combinedContent | Set-Content $hostsPath -Encoding ASCII -Force
                Write-Step "Hosts file updated with verified content" "OK"
                ipconfig /flushdns | Out-Null
                Write-Step "DNS cache flushed" "OK"
            } else {
                Write-Step "Hosts update aborted due to hash mismatch" "FAIL"
            }
        }
    }

if (($Section -contains "usb" -or $Section -contains "All") -and -not (Test-SkipSection "usb")) {
# ══════════════════════════════════════════════════════════════════════════════
Write-Section "USB Power Management"
# ══════════════════════════════════════════════════════════════════════════════
$usbCount = 0
$usbDevices = Get-PnpDevice | Where-Object { $_.InstanceId -like "USB\ROOT*" }
foreach ($device in $usbDevices) {
    $escaped = $device.InstanceId -replace '\\', '\\'
    $wmi = Get-CimInstance -Namespace root\wmi -Query "SELECT * FROM MSPower_DeviceEnable WHERE InstanceName LIKE '%$escaped%'" -ErrorAction SilentlyContinue
    if ($wmi) {
        if ($WhatIf) {
            Write-Step "WOULD: Disable USB suspend on $($device.InstanceId)" "INFO"
        } else {
            Set-CimInstance -InputObject $wmi -Property @{Enable=$False} -ErrorAction SilentlyContinue
        }
        $usbCount++
    }
}
if ($usbCount -gt 0) {
    Write-Step "Processed USB suspend on $usbCount root controllers" "OK"
} else {
    Write-Step "No USB root controllers with suspend settings found" "SKIP"
}
}

if (($Section -contains "services" -or $Section -contains "All") -and -not (Test-SkipSection "services")) {
# ══════════════════════════════════════════════════════════════════════════════
Write-Section "Service Disable"
# ══════════════════════════════════════════════════════════════════════════════

$stopDisable = @(
    "defragsvc","DeviceAssociationService","BcastDVRUserService","BITS",
    "sysmain","WpnService","WpnUserService","MozillaMaintenance",
    "CDPSvc","CDPUserSvc","dot3svc","DPS","iphlpsvc","defragsvc",
    "diagnosticshub.standardcollector.service","diagsvc","DiagTrack","DoSvc",
    "lmhosts","diagsvc","DiagTrack","dmwappushservice",
    "OneSyncSvc","PrintNotify","PrintWorkflowUserSvc","RasMan",
    "Rmsvc","SensorDataService","SensorService","SharedAccess",
    "lfsvc","Spooler","TokenBroker","LanmanWorkstation",
	"rdbss","KSecPkg","WSAIFabricSvc"
)
foreach ($s in $stopDisable) {
    if ($WhatIf) {
        if ((disablesvc $s) -eq 'ok') { $Script:Passed++ }
    } else {
        switch (disablesvc $s) {
            'ok'      { Write-Step "disabled: $s" "OK" }
            'already' { Write-Step "already disabled: $s" "SKIP" }
            'failed'  { Write-Step "Access denied: $s" "WARN"; $Script:Warnings++ }
            default   { Write-Step "Not found: $s" "SKIP" }
        }
    }
}
}

if (($Section -contains "schdtasks" -or $Section -contains "All") -and -not (Test-SkipSection "schdtasks")) {
# ══════════════════════════════════════════════════════════════════════════════
Write-Section "Scheduled Tasks "
# ══════════════════════════════════════════════════════════════════════════════
Write-Step "Loading all scheduled tasks..." "WAIT"
$AllTasks = Get-ScheduledTask -ErrorAction SilentlyContinue
$disabledCount = 0

$TasksToNuke = @(
    # microslop trackin yo ahh
    "\Microsoft\Windows\AppID\SmartScreenSpecific",
    "\Microsoft\Windows\Flighting\OneSettings\RefreshCache",
    "\Microsoft\Windows\Management\Provisioning\Cellular",
    "\Microsoft\Windows\Customer Experience Improvement Program\Consolidator",
    "\Microsoft\Windows\Customer Experience Improvement Program\UsbCeip",
    "\Microsoft\Windows\Customer Experience Improvement Program\Proxy",
    "\Microsoft\Windows\Customer Experience Improvement Program\Uploader",
    "\Microsoft\Windows\Application Experience\Microsoft Compatibility Appraiser",
    "\Microsoft\Windows\Application Experience\ProgramDataUpdater",
    "\Microsoft\Windows\Application Experience\StartupAppTask",
    "\Microsoft\Windows\Application Experience\PcaPatchDbTask",
    "\Microsoft\Windows\Application Experience\MareBackup",
    "\Microsoft\Windows\DiskDiagnostic\Microsoft-Windows-DiskDiagnosticDataCollector",
    "\Microsoft\Windows\DiskDiagnostic\Microsoft-Windows-DiskDiagnosticResolver",
    "\Microsoft\Windows\Diagnosis\RecommendedTroubleshootingService",
    "\Microsoft\Windows\Power Efficiency Diagnostics\AnalyzeSystem",
    "\Microsoft\Windows\Maps\MapsToastTask",
    "\Microsoft\Windows\Maps\MapsUpdateTask",
    "\Microsoft\Windows\Feedback\Siuf\DmClient",
    "\Microsoft\Windows\Feedback\Siuf\DmClientOnScenarioDownload",
    "\Microsoft\Windows\Windows Error Reporting\QueueReporting",
    "\Microsoft\Windows\CloudExperienceHost\CreateObjectTask",
    "\Microsoft\Windows\SettingSync\BackgroundUploadTask",
    "\Microsoft\Windows\SettingSync\NetworkStateChangeTask",
    "\Microsoft\Windows\RetailDemo\CleanupOfflineContent",
	"\Microsoft\Office\OfficeTelemetryAgentLogOn",
    "\Microsoft\Office\OfficeTelemetryAgentFallBack",
    "\Microsoft\Office\Office 15 Subscription Heartbeat",
    "\Microsoft\Windows\Autochk\Proxy",
    "\Microsoft\Windows\Customer Experience Improvement Program\KernelCeipTask",
    "\Microsoft\Windows\Location\Notifications",
    "\Microsoft\Windows\Location\WindowsActionDialog",
    "\Microsoft\Windows\Windows Media Sharing\UpdateLibrary"
)


foreach ($Target in $TasksToNuke) {
    $LastSlash = $Target.LastIndexOf('\')
    $TaskPath = $Target.Substring(0, $LastSlash + 1)
    $TaskName = $Target.Substring($LastSlash + 1)
    $match = $AllTasks | Where-Object { $_.TaskName -eq $TaskName -and $_.TaskPath -eq $TaskPath }
    if ($match) {
        if ($WhatIf) {
            Write-Step "WOULD: Disable task $TaskName" "INFO"
            $disabledCount++
        } elseif ($match.State -eq 'Disabled') {
            Write-Step "Already disabled: $TaskName" "SKIP"
        } else {
            & schtasks.exe /Change /TN "$($match.TaskPath)$($match.TaskName)" /DISABLE 2>$null | Out-Null
            if ($LASTEXITCODE -eq 0) {
                Write-Step "Disabled: $TaskName" "OK"
                $disabledCount++
            } else {
                Write-Step "Access denied (skipped): $TaskName" "WARN"
                $Script:Warnings++
            }
        }
    }
}
if ($WhatIf) {
    Write-Step "WOULD: disable $disabledCount tasks" "INFO"
} else {
    Write-Step "disabled $disabledCount tasks" "INFO"
}
}

if (($Section -contains "bcdedit" -or $Section -contains "All") -and -not (Test-SkipSection "bcdedit")) {
# ══════════════════════════════════════════════════════════════════════════════
Write-Section "BCDedit "
# ══════════════════════════════════════════════════════════════════════════════
$bcdCommands = @(
    @{A="hypervisorlaunchtype off"; L="Hypervisor off"},
    @{A="tscsyncpolicy Enhanced";   L="TSC policy Enhanced"},
    @{A="bootmenupolicy legacy";    L="Legacy boot menu"},
    @{A="useplatformclock false";   L="Platform clock off"},
    @{A="useplatformtick true";     L="Platform tick on"},
    @{A="disabledynamictick Yes";   L="Dynamic tick disabled"}
)

if ($WhatIf) {
    $cmdList = $bcdCommands | ForEach-Object { "bcdedit /set $($_.A)" }
    Write-Step "WOULD: Run BCDEdit commands: $($cmdList -join '; ')" "INFO"
} else {
    netsh interface tcp set global autotuninglevel=normal 2>$null | Out-Null
    Write-Step "TCP autotuninglevel = normal" "OK"
    foreach ($cmd in $bcdCommands) {
        & bcdedit /set $cmd.A.Split(" ") 2>$null
        if ($LASTEXITCODE -eq 0) { Write-Step "BCDedit: $($cmd.L)" "OK" }
        else { Write-Step "BCDedit: $($cmd.L)" "WARN" }
    }
}
}

if (($Section -contains "power" -or $Section -contains "All") -and -not (Test-SkipSection "power")) {
# ══════════════════════════════════════════════════════════════════════════════
Write-Section "Power Options "
# ══════════════════════════════════════════════════════════════════════════════
$cs = Get-CimInstance Win32_ComputerSystem
 $ramBytes = $cs.TotalPhysicalMemory
 $ramMB = [math]::Round($ramBytes / 1MB)
 $pageSize = if ($ramMB -le 8192) { [math]::Round($ramMB * 1.5) }
            elseif ($ramMB -le 16384) { $ramMB }
            else { 4096 }
if ($WhatIf) {
    Write-Step "WOULD: Disable hibernation, Import a power plan, Set pagefile to $pageSize MB." "INFO"
} else {
powercfg.exe /hibernate off 2>$null | Out-Null
Write-Step "Hibernate off" "OK"

$PowerPlanBase64 = @"
cmVnZgEAAAABAAAA6jaSR3AP3QEBAAAAAwAAAAAAAAABAAAAIAAAAABAAAABAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAOe75C9ie/ERusXs9LtCImDnu+QvYnvxEbrF7PS7QiJgAAAAAOi75C9ie/ERusXs9LtCImBybXRtAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAADM2h+cAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAGhiaW4AAAAAABAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAiP///25rLADoX8wYcA/dAQAAAAD/////EAAAAAAAAAAYLAAA/////wMAAAAYAgAAmAAAAP////9IAAAAAAAAABgAAAAaAAAAAAAAACQAAABjODhkOGM5MC1lMDc0LTQ1M2EtYmE2YS04MTA4NGIzM2EwMTkAAAAAGP///3NrAACYAAAAmAAAAE4AAADQAAAAAQAEjLgAAADEAAAAAAAAABQAAAACAKQABwAAAAAQGAAZAAIAAQIAAAAAAAUgAAAAIQIAAAAaGAAAAACAAQIAAAAAAAUgAAAAIQIAAAAQGAAZAAIAAQIAAAAAAAUgAAAAIAIAAAAaGAAAAACAAQIAAAAAAAUgAAAAIAIAAAAQFAA/AA8AAQEAAAAAAAUSAAAAABoUAAAAABABAQAAAAAABRIAAAAAGhQAAAAAgAEBAAAAAAADAAAAAAEBAAAAAAAFEgAAAAEBAAAAAAAFEgAAANj///92awsAAAAAgAAAAAACAAAAAQBCAERlc2NyaXB0aW9uADEANgDY////dmsMABoAAADQAQAAAgAAAAEAOABGcmllbmRseU5hbWVFAH0A0P///2QAYQAgAGIAaQBnACAAbwBuAGUAIABzAAAARwBhAG0AaQBuAGcAAABUAGMA6P///3ZrAAAAAACAAAAAAAEAAAAAAMEu8P///4ABAACoAQAAAAIAAIj///9uayAAgScS2W8P3QEAAAAAIAAAAAgAAAAAAAAAwAgAAP////8AAAAA/////5gAAAD/////SAAAAAAAAAAAAAAAAAAAAAAAAAAkAAAAMDAxMmVlNDctOTA0MS00YjVkLTliNzctNTM1ZmJhOGIxNDQyAAAAAPD///9sZgEAsAkAADRjNzmI////bmsgAIvZEdlvD90BAAAAACgCAAAAAAAAAAAAAP//////////AgAAAIgDAACYAAAA/////wAAAAAAAAAAHAAAAAQAAAAAAAAAJAAAADY3MzhlMmM0LWU4YTUtNGE0Mi1iMTZhLWUwNDBlNzY5NzU2ZQAAAADw////KAQAAFAEAAA2NzM42P///3ZrDgAEAACAAAAAAAQAAAABAGUAQUNTZXR0aW5nSW5kZXh0ANj///92aw4ABAAAgAAAAAAEAAAAAQBBAERDU2V0dGluZ0luZGV4LQDw////OAMAAGADAAAAAAAAiP///25rIACL2RHZbw/dAQAAAAAoAgAAAAAAAAAAAAD//////////wIAAAAoAwAAmAAAAP////8AAAAAAAAAABwAAAAEAAAAAAAAACQAAAA2YjAxM2EwMC1mNzc1LTRkNjEtOTAzNi1hNjJmN2U3YTZhNWIAAAAA+P///xgFAADw////uAUAAOAFAAA2YjAx2P///3ZrDgAEAACA0AcAAAQAAAABAC0AQUNTZXR0aW5nSW5kZXhCANj///92aw4ABAAAgGQAAAAEAAAAAQA5AERDU2V0dGluZ0luZGV4fQCI////bmsgAIvZEdlvD90BAAAAACgCAAAAAAAAAAAAAP//////////AQAAABAEAACYAAAA/////wAAAAAAAAAAHAAAAAQAAAAAAAAAJAAAADgwZTNjNjBlLWJiOTQtNGFkOC1iYmUwLTBkMzE5NWVmYzY2MwAAAADY////dmsOAAQAAIDQBwAABAAAAAEAEBdBQ1NldHRpbmdJbmRleBco2P///3ZrDgAEAACAHgAAAAQAAAABAGkARENTZXR0aW5nSW5kZXgyAIj///9uayAAnAAS2W8P3QEAAAAAKAIAAAAAAAAAAAAA//////////8CAAAAGAQAAJgAAAD/////AAAAAAAAAAAcAAAABAAAAAAAAAAkAAAAZDNkNTVlZmQtYzFmZi00MjRlLTlkYzMtNDQxYmU3ODMzMDEwAAAAANj///92aw4ABAAAgCBOAAAEAAAAAQA4AEFDU2V0dGluZ0luZGV4OADY////dmsOAAQAAIDoAwAABAAAAAEALQBEQ1NldHRpbmdJbmRleDQAiP///25rIACBJxLZbw/dAQAAAAAoAgAAAAAAAAAAAAD//////////wIAAADoBgAAmAAAAP////8AAAAAAAAAABwAAAAEAAAAAAAAACQAAABkNjM5NTE4YS1lNTZkLTQzNDUtOGFmMi1iOWYzMmZiMjYxMDkAAAAA2P///3ZrDgAEAACAMgAAAAQAAAABABAXRENTZXR0aW5nSW5kZXgXKPj///+ABgAA+P///ygKAAD4////yAwAANj///92aw4ABAAAgGQAAAAEAAAAAQBwAERDU2V0dGluZ0luZGV4RgDw////8AQAAMAGAAAAAAAAiP///25rIACBJxLZbw/dAQAAAAAoAgAAAAAAAAAAAAD//////////wEAAACYBwAAmAAAAP////8AAAAAAAAAABwAAAAEAAAAAAAAACQAAABkYWI2MDM2Ny01M2ZlLTRmYmMtODI1ZS01MjFkMDY5ZDI0NTYAAAAA2P///3ZrDgAEAACAZAAAAAQAAAABADEARENTZXR0aW5nSW5kZXgtAPj///9wBwAAiP///25rIACBJxLZbw/dAQAAAAAoAgAAAAAAAAAAAAD//////////wEAAABACAAAmAAAAP////8AAAAAAAAAABwAAAAEAAAAAAAAACQAAABkYmM5ZTIzOC02ZGU5LTQ5ZTMtOTJjZC04YzJiNDk0NmI0NzIAAAAA2P///3ZrDgAEAACAZAAAAAQAAAABAC0ARENTZXR0aW5nSW5kZXg1APj///8YCAAAiP///25rIACBJxLZbw/dAQAAAAAoAgAAAAAAAAAAAAD//////////wEAAACoBgAAmAAAAP////8AAAAAAAAAABwAAAAEAAAAAAAAACQAAABmYzk1YWY0ZC00MGU3LTRiNmQtODM1YS01NmQxMzFkYmM4MGUAAAAAoP///2xmCACwAgAANjczOJgDAAA2YjAxeAQAADgwZTNABQAAZDNkNQgGAABkNjM5+AYAAGRhYjagBwAAZGJjOUgIAABmYzk1AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAiP///25rIACBJxLZbw/dAQAAAAAgAAAAAQAAAAAAAACgAgAA/////wAAAAD/////mAAAAP////9IAAAAAAAAAAAAAAAAAAAAAAAAACQAAAAwMmY4MTViNS1hNWNmLTRjODQtYmYyMC02NDlkMWY3NWQzZDgAAAAA8P///2xmAQDwCgAAMzA5ZPj///8ADwAAiP///25rIACBJxLZbw/dAQAAAAAgCQAAAAAAAAAAAAD//////////wEAAACwBgAAmAAAAP////8AAAAAAAAAABwAAAAEAAAAAAAAACQAAAA0Yzc5M2U3ZC1hMjY0LTQyZTEtODdkMy03YTBkMmY1MjNjY2QAAAAA2P///3ZrDgAEAACAAAAAAAQAAAABAGUARENTZXR0aW5nSW5kZXhpAIj///9uayAAgScS2W8P3QEAAAAAIAAAAAEAAAAAAAAAmAkAAP////8AAAAA/////5gAAAD/////SAAAAAAAAAAAAAAAAAAAAAAAAAAkAAAAMGQ3ZGJhZTItNDI5NC00MDJhLWJhOGUtMjY3NzdlODQ4OGNkAAAAAPD////IDwAAIBAAADI1ZGbw////IA4AAEgOAAAwZDdk+P///6APAACI////bmsgAIEnEtlvD90BAAAAAFAKAAAAAAAAAAAAAP//////////AgAAALgLAACYAAAA/////wAAAAAAAAAAHAAAAAQAAAAAAAAAJAAAADMwOWRjZTliLWJlZjQtNDExOS05OTIxLWE4NTFmYjEyZjBmNAAAAADY////dmsOAAQAAIABAAAABAAAAAEALQBBQ1NldHRpbmdJbmRleEMA2P///3ZrDgAEAACAAQAAAAQAAAABAEIARENTZXR0aW5nSW5kZXh9APD///9oCwAAkAsAAAAAAACI////bmsgAIEnEtlvD90BAAAAACAAAAABAAAAAAAAALgMAAD/////AAAAAP////+YAAAA/////0gAAAAAAAAAAAAAAAAAAAAAAAAAJAAAADE5Y2JiOGZhLTUyNzktNDUwZS05ZmFjLThhM2Q1ZmVkZDBjMQAAAACI////bmsgAIEnEtlvD90BAAAAAMgLAAAAAAAAAAAAAP//////////AQAAALgGAACYAAAA/////wAAAAAAAAAAHAAAAAQAAAAAAAAAJAAAADEyYmJlYmU2LTU4ZDYtNDYzNi05NWJiLTMyMTdlZjg2N2MxYQAAAADw////bGYBAEAMAAAxMmJi2P///3ZrDgAEAACAAgAAAAMAAAABADYARENTZXR0aW5nSW5kZXgAAIj///9uayAAg04S2W8P3QEAAAAAIAAAAAUAAAAAAAAAiBEAAP////8AAAAA/////5gAAAD/////SAAAAAAAAAAAAAAAAAAAAAAAAAAkAAAAMjM4YzlmYTgtMGFhZC00MWVkLTgzZjQtOTdiZTI0MmM4ZjIwAAAAANj///92aw4ABAAAgGDqAAAEAAAAAQB6ZkRDU2V0dGluZ0luZGV4+T/o////bGYCABAWAABjMzZmiBYAAGQ1MDKI////bmsgAINOEtlvD90BAAAAAPAMAAAAAAAAAAAAAP//////////AgAAANgKAACYAAAA/////wAAAAAAAAAAHAAAAAQAAAAAAAAAJAAAADI1ZGZhMTQ5LTVkZDEtNDczNi1iNWFiLWU4YTM3YjViODE4NwAAAADY////dmsOAAQAAIABAAAABAAAAAEAemZBQ1NldHRpbmdJbmRlePk/2P///3ZrDgAEAACAAAAAAAQAAAABAGUARENTZXR0aW5nSW5kZXhfAIj///9uayAAg04S2W8P3QEAAAAA8AwAAAAAAAAAAAAA//////////8BAAAAqAkAAJgAAAD/////AAAAAAAAAAAcAAAABAAAAAAAAAAkAAAAMjlmNmMxZGItODZkYS00OGM1LTlmZGItZjJiNjdiMWY0NGRhAAAAAPD////AEAAA6BAAADI1ZGb4////kBMAANj///92aw4ABAAAgAAAAAAEAAAAAQA4AERDU2V0dGluZ0luZGV4NACI////bmsgAINOEtlvD90BAAAAAPAMAAAAAAAAAAAAAP//////////AgAAAMgKAACYAAAA/////wAAAAAAAAAAHAAAAAQAAAAAAAAAJAAAADk0YWM2ZDI5LTczY2UtNDFhNi04MDlmLTYzNjNiYTIxYjQ3ZQAAAADY////dmsOAAQAAIABAAAABAAAAAEAZZBEQ1NldHRpbmdJbmRleIY/2P///3ZrDgAEAACAAAAAAAQAAAABAAAAQUNTZXR0aW5nSW5kZXhcAPD///9AEgAAaBIAAAAAAABoYmluABAAAAAQAAAAAAAAAAAAAAAAAAAAAAAAAAAAANj///92aw4ABAAAgAEAAAAEAAAAAQByAERDU2V0dGluZ0luZGV4ewCI////bmsgAINOEtlvD90BAAAAAPAMAAAAAAAAAAAAAP//////////AgAAAOgOAACYAAAA/////wAAAAAAAAAAHAAAAAQAAAAAAAAAJAAAAGJkM2I3MThhLTA2ODAtNGQ5ZC04YWIyLWUxZDJiNGFjODA2ZAAAAADY////dmsOAAQAAIAAAAAABAAAAAEAMwBBQ1NldHRpbmdJbmRleDAA2P///3ZrDgAEAACAAQAAAAQAAAABADcARENTZXR0aW5nSW5kZXg1AIj///9uayAAg04S2W8P3QEAAAAA8AwAAAAAAAAAAAAA//////////8BAAAA6AoAAJgAAAD/////AAAAAAAAAAAcAAAABAAAAAAAAAAkAAAAZDRjMWQ0YzgtZDVjYy00M2QzLWI4M2UtZmM1MTIxNWNiMDRkAAAAAMD///9sZgUAqA0AADI1ZGZwDgAAMjlmNigPAAA5NGFjSBAAAGJkM2IQEQAAZDRjMQAAAAAAAAAAAAAAAAAAAACI////bmsgAINOEtlvD90BAAAAACAAAAAAAAAAAAAAAP//////////AgAAAPAPAACYAAAA/////wAAAAAAAAAAHAAAAAQAAAAAAAAAJAAAADI0NWQ4NTQxLTM5NDMtNDQyMi1iMDI1LTEzYTc4NGY2NzliNwAAAADY////dmsOAAQAAIABAAAABAAAAAEAZQBBQ1NldHRpbmdJbmRleF8A2P///3ZrDgAEAACAAQAAAAQAAAABADMARENTZXR0aW5nSW5kZXgwAIj///9uayAAg04S2W8P3QEAAAAAIAAAAAMAAAAAAAAA6BQAAP////8AAAAA/////5gAAAD/////SAAAAAAAAAAAAAAAAAAAAAAAAAAkAAAAMmE3Mzc0NDEtMTkzMC00NDAyLThkNzctYjJiZWJiYTMwOGEzAAAAAIj///9uayAAg04S2W8P3QEAAAAAkBIAAAAAAAAAAAAA//////////8BAAAA+A4AAJgAAAD/////AAAAAAAAAAAcAAAABAAAAAAAAAAkAAAANDhlNmI3YTYtNTBmNS00NzgyLWE1ZDQtNTNiYjhmMDdlMjI2AAAAAPj///9IFAAA+P///xAVAADY////dmsOAAQAAIAAAAAABAAAAAEAQwBBQ1NldHRpbmdJbmRleEUAiP///25rIACDThLZbw/dAQAAAACQEgAAAAAAAAAAAAD//////////wEAAACAEwAAmAAAAP////8AAAAAAAAAABwAAAAEAAAAAAAAACQAAAA0OThjMDQ0YS0yMDFiLTQ2MzEtYTUyMi01Yzc0NGVkNGU2NzgAAAAA+P///wAXAAD4////iBkAAPj///9oDQAA2P///3ZrDgAEAACAAAAAAAQAAAABAEUARENTZXR0aW5nSW5kZXgzAIj///9uayAAg04S2W8P3QEAAAAAkBIAAAAAAAAAAAAA//////////8BAAAAiBMAAJgAAAD/////AAAAAAAAAAAcAAAABAAAAAAAAAAkAAAAZDRlOThmMzEtNWZmZS00Y2UxLWJlMzEtMWIzOGIzODRjMDA5AAAAANj///9sZgMACBMAADQ4ZTa4EwAANDk4Y3AUAABkNGU5AAAAAAAAAADY////dmsOAAQAAIAAAAAABAAAAAEARABBQ1NldHRpbmdJbmRleGEAiP///25rIABrdRLZbw/dAQAAAAAgAAAAAgAAAAAAAACQDQAA/////wAAAAD/////mAAAAP////9IAAAAAAAAAAAAAAAAAAAAAAAAACQAAAAyZTYwMTEzMC01MzUxLTRkOWQtOGUwNC0yNTI5NjZiYWQwNTQAAAAA8P///8AtAADoLQAAMTdhYdj///92aw4ABAAAgHUDAAAEAAAAAQB6ZkFDU2V0dGluZ0luZGV4+T/Y////dmsOAAQAAIAdAQAABAAAAAEAyi5EQ1NldHRpbmdJbmRleH2tiP///25rIABrdRLZbw/dAQAAAAA4FQAAAAAAAAAAAAD//////////wEAAABAFAAAmAAAAP////8AAAAAAAAAABwAAAAEAAAAAAAAACQAAABjMzZmMGViNC0yOTg4LTRhNzAtOGVlZS0wODg0ZmMyYzI0MzMAAAAAiP///25rIABrdRLZbw/dAQAAAAA4FQAAAAAAAAAAAAD//////////wEAAAAwFAAAmAAAAP////8AAAAAAAAAABwAAAAEAAAAAAAAACQAAABkNTAyZjdlZS0xZGM3LTRlZmQtYTU1ZC1mMDRiNmY1YzA1NDUAAAAA2P///3ZrDgAEAACAAAAAAAQAAAABADQAQUNTZXR0aW5nSW5kZXhCAIj///9uayAAa3US2W8P3QEAAAAAIAAAAAEAAAAAAAAAGBgAAP////8AAAAA/////5gAAAD/////SAAAAAAAAAAAAAAAAAAAAAAAAAAkAAAANDg2NzJmMzgtN2E5YS00YmIyLThiZjgtM2Q4NWJlMTlkZTRlAAAAAIj///9uayAAa3US2W8P3QEAAAAAKBcAAAAAAAAAAAAA//////////8CAAAAeBgAAJgAAAD/////AAAAAAAAAAAcAAAABAAAAAAAAAAkAAAANzNjZGU2NGQtZDcyMC00YmIyLWE4NjAtYzc1NWFmZTc3ZWYyAAAAAPD///9sZgEAoBcAADczY2TY////dmsOAAQAAIBLAAAABAAAAAEAMwBBQ1NldHRpbmdJbmRleEEA2P///3ZrDgAEAACAMgAAAAQAAAABADEARENTZXR0aW5nSW5kZXgAAPD///8oGAAAUBgAAAAAAACI////bmsgAGt1EtlvD90BAAAAACAAAAABAAAAAAAAAHgZAAD/////AAAAAP////+YAAAA/////0gAAAAAAAAAAAAAAAAAAAAAAAAAJAAAADUwMWE0ZDEzLTQyYWYtNDQyOS05ZmQxLWE4MjE4YzI2OGUyMAAAAACI////bmsgAGt1EtlvD90BAAAAAIgYAAAAAAAAAAAAAP//////////AQAAADgUAACYAAAA/////wAAAAAAAAAAHAAAAAQAAAAAAAAAJAAAAGVlMTJmOTA2LWQyNzctNDA0Yi1iNmRhLWU1ZmExYTU3NmRmNQAAAADw////bGYBAAAZAABlZTEy2P///3ZrDgAEAACAAgAAAAQAAAABAEIARENTZXR0aW5nSW5kZXhEAIj///9uayAAaZwS2W8P3QEAAAAAIAAAABYAAAAAAAAA+CcAAP////8AAAAA/////5gAAAD/////SAAAAAAAAAAAAAAAAAAAAAAAAAAkAAAANTQ1MzMyNTEtODJiZS00ODI0LTk2YzEtNDdiNjBiNzQwZDAwAAAAAIj///9uayAAa3US2W8P3QEAAAAAsBkAAAAAAAAAAAAA//////////8CAAAAABsAAJgAAAD/////AAAAAAAAAAAcAAAABAAAAAAAAAAkAAAAMDZjYWRmMGUtNjRlZC00NDhhLTg5MjctY2U3YmY5MGViMzVkAAAAAPD///+gGwAAyBsAADA2Y2HY////dmsOAAQAAIAUAAAABAAAAAEAQgBBQ1NldHRpbmdJbmRleEQA2P///3ZrDgAEAACAWgAAAAQAAAABAG4ARENTZXR0aW5nSW5kZXhOAPD///+wGgAA2BoAAAAAAACI////bmsgAGt1EtlvD90BAAAAALAZAAAAAAAAAAAAAP//////////AgAAAKAaAACYAAAA/////wAAAAAAAAAAHAAAAAQAAAAAAAAAJAAAADBjYzViNjQ3LWMxZGYtNDYzNy04OTFhLWRlYzM1YzMxODU4MwAAAADw////kBwAALgcAAAwNmNh+P///2gcAADY////dmsOAAQAAIBkAAAABAAAAAEAewBBQ1NldHRpbmdJbmRleDQA2P///3ZrDgAEAACASwAAAAQAAAABAEEARENTZXR0aW5nSW5kZXg2AIj///9uayAAa3US2W8P3QEAAAAAsBkAAAAAAAAAAAAA//////////8CAAAAiBsAAJgAAAD/////AAAAAAAAAAAcAAAABAAAAAAAAAAkAAAAMTJhMGFiNDQtZmUyOC00ZmE5LWIzYmQtNGI2NGY0NDk2MGE2AAAAANj///92aw4ABAAAgAMAAAAEAAAAAQCo8URDU2V0dGluZ0luZGV4L1fY////dmsOAAQAAIAFAAAABAAAAAEANABBQ1NldHRpbmdJbmRleDMA2P///3ZrDgAEAACAHgAAAAQAAAABADAARENTZXR0aW5nSW5kZXhpAIj///9uayAAa3US2W8P3QEAAAAAsBkAAAAAAAAAAAAA//////////8CAAAAqB0AAJgAAAD/////AAAAAAAAAAAcAAAABAAAAAAAAAAkAAAAMTJhMGFiNDQtZmUyOC00ZmE5LWIzYmQtNGI2NGY0NDk2MGE3AAAAANj///92aw4ABAAAgAoAAAAEAAAAAQAtAEFDU2V0dGluZ0luZGV4NQDY////dmsOAAQAAIAeAAAABAAAAAEAOQBEQ1NldHRpbmdJbmRleH0A8P///1gdAACAHQAAAAAAAIj///9uayAAa3US2W8P3QEAAAAAsBkAAAAAAAAAAAAA//////////8BAAAAmBsAAJgAAAD/////AAAAAAAAAAAcAAAABAAAAAAAAAAkAAAAMmRkZDVhODQtNWE3MS00MzdlLTkxMmEtZGIwYjhjNzg4NzMyAAAAANj///92aw4ABAAAgAAAAAAEAAAAAQCo8UFDU2V0dGluZ0luZGV4L1f4////MB4AAPD////AHwAAcCEAADM2NjiI////bmsgAGt1EtlvD90BAAAAALAZAAAAAAAAAAAAAP//////////AQAAABAfAACYAAAA/////wAAAAAAAAAAHAAAAAQAAAAAAAAAJAAAADM2Njg3ZjllLWUzYTUtNGRiZi1iMWRjLTE1ZWIzODFjNjg2MwAAAADY////dmsOAAQAAIAwAAAABAAAAAEAdgBEQ1NldHRpbmdJbmRleGkA+P///+geAACI////bmsgAGt1EtlvD90BAAAAALAZAAAAAAAAAAAAAP//////////AQAAALgfAACYAAAA/////wAAAAAAAAAAHAAAAAQAAAAAAAAAJAAAADM2Njg3ZjllLWUzYTUtNGRiZi1iMWRjLTE1ZWIzODFjNjg2NAAAAADY////dmsOAAQAAIAwAAAABAAAAAEANQBEQ1NldHRpbmdJbmRleC0A+P///5AfAADY////dmsOAAQAAIABAAAABAAAAAEAZQBBQ1NldHRpbmdJbmRleHsA+P///xAiAAD4////sCIAAPj///9YJAAAaGJpbgAgAAAAEAAAAAAAAAAAAAAAAAAAAAAAAAAAAACI////bmsgAGt1EtlvD90BAAAAALAZAAAAAAAAAAAAAP//////////AQAAAFgeAACYAAAA/////wAAAAAAAAAAHAAAAAQAAAAAAAAAJAAAADNiMDRkNGZkLTFjYzctNGYyMy1hYjFjLWQxMzM3ODE5YzRiYgAAAADY////dmsOAAQAAIBLAAAABAAAAAEAqPFBQ1NldHRpbmdJbmRleC9X2P///3ZrDgAEAACAFAAAAAQAAAABAOQURENTZXR0aW5nSW5kZXj4MvD///+YIAAAwCAAADQ2NWWI////bmsgAGt1EtlvD90BAAAAALAZAAAAAAAAAAAAAP//////////AgAAAGAeAACYAAAA/////wAAAAAAAAAAHAAAAAQAAAAAAAAAJAAAADQwZmJlZmM3LTJlOWQtNGQyNS1hMTg1LTBjZmQ4NTc0YmFjNgAAAADY////dmsOAAQAAIAAAAAABAAAAAEANABEQ1NldHRpbmdJbmRleEEAiP///25rIABrdRLZbw/dAQAAAACwGQAAAAAAAAAAAAD//////////wEAAADoHwAAmAAAAP////8AAAAAAAAAABwAAAAEAAAAAAAAACQAAAA0NWJjYzA0NC1kODg1LTQzZTItODYwNS1lZTBlYzZlOTZiNTkAAAAA2P///3ZrDgAEAACAOwAAAAQAAAABAFwARENTZXR0aW5nSW5kZXhUAIj///9uayAAa3US2W8P3QEAAAAAsBkAAAAAAAAAAAAA//////////8BAAAA8B8AAJgAAAD/////AAAAAAAAAAAcAAAABAAAAAAAAAAkAAAANDY1ZTFmNTAtYjYxMC00NzNhLWFiNTgtMDBkMTA3N2RjNDE4AAAAANj///92aw4ABAAAgAAAAAAEAAAAAQA2AERDU2V0dGluZ0luZGV4RgCI////bmsgAGmcEtlvD90BAAAAALAZAAAAAAAAAAAAAP//////////AgAAAOggAACYAAAA/////wAAAAAAAAAAHAAAAAQAAAAAAAAAJAAAADRiOTJkNzU4LTVhMjQtNDg1MS1hNDcwLTgxNWQ3OGFlZTExOQAAAADY////dmsOAAQAAIAAAAAABAAAAAEAqPFEQ1NldHRpbmdJbmRleC9X+P///1AjAADY////dmsOAAQAAIACAAAABAAAAAEA5BRBQ1NldHRpbmdJbmRlePgy2P///3ZrDgAEAACAAgAAAAQAAAABAIGYRENTZXR0aW5nSW5kZXjEl/D///+AIwAAqCMAADk0M2OI////bmsgAGmcEtlvD90BAAAAALAZAAAAAAAAAAAAAP//////////AQAAAPgfAACYAAAA/////wAAAAAAAAAAHAAAAAQAAAAAAAAAJAAAADRkMmIwMTUyLTdkNWMtNDk4Yi04OGUyLTM0MzQ1MzkyYTJjNQAAAADY////dmsOAAQAAIAeAAAABAAAAAEARQBEQ1NldHRpbmdJbmRleDEAiP///25rIABpnBLZbw/dAQAAAACwGQAAAAAAAAAAAAD//////////wEAAAAgJQAAmAAAAP////8AAAAAAAAAABwAAAAEAAAAAAAAACQAAAA2MTliNzUwNS0wMDNiLTRlODItYjdhNi00ZGQyOWMzMDA5NzEAAAAA2P///3ZrDgAEAACAYwAAAAQAAAABAEQAQUNTZXR0aW5nSW5kZXhjAPj////4JAAAiP///25rIABpnBLZbw/dAQAAAACwGQAAAAAAAAAAAAD//////////wIAAADwJQAAmAAAAP////8AAAAAAAAAABwAAAAEAAAAAAAAACQAAAA3YjIyNDg4My1iM2NjLTRkNzktODE5Zi04Mzc0MTUyY2JlN2MAAAAA2P///3ZrDgAEAACAXwAAAAQAAAABAC0AQUNTZXR0aW5nSW5kZXgzANj///92aw4ABAAAgCgAAAAEAAAAAQA2AERDU2V0dGluZ0luZGV4IgDw////oCUAAMglAAAAAAAAiP///25rIABpnBLZbw/dAQAAAACwGQAAAAAAAAAAAAD//////////wIAAADIJgAAmAAAAP////8AAAAAAAAAABwAAAAEAAAAAAAAACQAAAA4OTNkZWU4ZS0yYmVmLTQxZTAtODljNi1iNTVkMDkyOTk2NGMAAAAA2P///3ZrDgAEAACAZAAAAAQAAAABAC0AQUNTZXR0aW5nSW5kZXg5ANj///92aw4ABAAAgEsAAAAEAAAAAQA1AERDU2V0dGluZ0luZGV4dgDw////eCYAAKAmAAAAAAAAiP///25rIABpnBLZbw/dAQAAAACwGQAAAAAAAAAAAAD//////////wEAAAB4JwAAmAAAAP////8AAAAAAAAAABwAAAAEAAAAAAAAACQAAAA5NDNjOGNiNi02ZjkzLTQyMjctYWQ4Ny1lOWEzZmVlYzA4ZDEAAAAA2P///3ZrDgAEAACAVQAAAAQAAAABAEIARENTZXR0aW5nSW5kZXgwAPj///9QJwAAiP///25rIABpnBLZbw/dAQAAAACwGQAAAAAAAAAAAAD//////////wEAAAB4IwAAmAAAAP////8AAAAAAAAAABwAAAAEAAAAAAAAACQAAAA5NGQzYTYxNS1hODk5LTRhYzUtYWUyYi1lNGQ4ZjYzNDM2N2YAAAAAKP///2xmFgAoGgAAMDZjYRAbAAAwY2M18BsAADEyYTDgHAAAMTJhMLgdAAAyZGRkcB4AADM2NjgYHwAAMzY2OCAgAAAzYjA0+CAAADQwZmKYIQAANDViYzgiAAA0NjVl2CIAADRiOTLgIwAANGQyYoAkAAA2MTliKCUAADdiMjIAJgAAODkzZNgmAAA5NDNjgCcAADk0ZDPQKAAAYmUzM0gpAABjN2JlICoAAGRmZDHIKgAAZTAwMAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAiP///25rIABpnBLZbw/dAQAAAACwGQAAAAAAAAAAAAD//////////wIAAADQIwAAmAAAAP////8AAAAAAAAAABwAAAAEAAAAAAAAACQAAABiZTMzNzIzOC0wZDgyLTQxNDYtYTk2MC00ZjM3NDlkNDcwYzcAAAAAiP///25rIABpnBLZbw/dAQAAAACwGQAAAAAAAAAAAAD//////////wIAAAAQKgAAmAAAAP////8AAAAAAAAAABwAAAAEAAAAAAAAACQAAABjN2JlMDY3OS0yODE3LTRkNjktOWQwMi01MTlhNTM3ZWQwYzYAAAAA2P///3ZrDgAEAACAAAAAAAQAAAABAFwAQUNTZXR0aW5nSW5kZXg5ANj///92aw4ABAAAgAAAAAAEAAAAAQAtAERDU2V0dGluZ0luZGV4NgDw////wCkAAOgpAAAAAAAAiP///25rIABpnBLZbw/dAQAAAACwGQAAAAAAAAAAAAD//////////wEAAADAKgAAmAAAAP////8AAAAAAAAAABwAAAAEAAAAAAAAACQAAABkZmQxMGQxNy1kNWViLTQ1ZGQtODc3YS05YTM0ZGRkMTVjODIAAAAA2P///3ZrDgAEAACACgAAAAQAAAABADEARENTZXR0aW5nSW5kZXg3APj///+YKgAAiP///25rIABpnBLZbw/dAQAAAACwGQAAAAAAAAAAAAD//////////wIAAACQKwAAmAAAAP////8AAAAAAAAAABwAAAAEAAAAAAAAACQAAABlMDAwNzMzMC1mNTg5LTQyZWQtYTQwMS01ZGRiMTBlNzg1ZDMAAAAA2P///3ZrDgAEAACAAAAAAAQAAAABAAAAQUNTZXR0aW5nSW5kZXhcANj///92aw4ABAAAgAAAAAAEAAAAAQAxAERDU2V0dGluZ0luZGV4LQDw////QCsAAGgrAAAAAAAAiP///25rIABpnBLZbw/dAQAAAAAgAAAABAAAAAAAAACILgAA/////wAAAAD/////mAAAAP////9IAAAAAAAAAAAAAAAAAAAAAAAAACQAAAA3NTE2Yjk1Zi1mNzc2LTQ0NjQtOGM1My0wNjE2N2Y0MGNjOTkAAAAAcP///2xmEAAoAgAAMDAxMiAJAAAwMmY4UAoAADBkN2TICwAAMTljYvAMAAAyMzhjyBEAADI0NWSQEgAAMmE3MzgVAAAyZTYwKBcAADQ4NjeIGAAANTAxYbAZAAA1NDUzoCsAADc1MTYgMAAAODYxOZg0AAA5NTk2UDYAAGRlODMwOAAAZTczYQAAAAAAAAAAiP///25rIABpnBLZbw/dAQAAAACgKwAAAAAAAAAAAAD//////////wIAAAAgLQAAmAAAAP////8AAAAAAAAAABwAAAAEAAAAAAAAACQAAAAxN2FhYTI5Yi04YjQzLTRiOTQtYWFmZS0zNWY2NGRhYWYxZWUAAAAA8P///8AVAADoFQAAAAAAAIj///9uayAAaZwS2W8P3QEAAAAAoCsAAAAAAAAAAAAA//////////8CAAAAsBUAAJgAAAD/////AAAAAAAAAAAcAAAABAAAAAAAAAAkAAAAM2MwYmMwMjEtYzhhOC00ZTA3LWE5NzMtNmIxNGNiY2IyYjdlAAAAAPD///+wLgAA2C4AADE3YWH4////EDEAANj///92aw4ABAAAgAAAAAAEAAAAAQAzAEFDU2V0dGluZ0luZGV4LQDY////dmsOAAQAAIAAAAAABAAAAAEANQBEQ1NldHRpbmdJbmRleDcAiP///25rIABpnBLZbw/dAQAAAACgKwAAAAAAAAAAAAD//////////wIAAACoLQAAmAAAAP////8AAAAAAAAAABwAAAAEAAAAAAAAACQAAAA2ODRjM2U2OS1hNGY3LTQwMTQtODc1NC1kNDUxNzlhNTYxNjcAAAAA2P///2xmBACoLAAAMTdhYTAtAAAzYzBiEC4AADY4NGMALwAAYWRlZNj///92aw4ABAAAgAEAAAAEAAAAAQAyAEFDU2V0dGluZ0luZGV4NADY////dmsOAAQAAIAAAAAABAAAAAEAZQBEQ1NldHRpbmdJbmRleEUAiP///25rIACJwxLZbw/dAQAAAACgKwAAAAAAAAAAAAD//////////wIAAADILwAAmAAAAP////8AAAAAAAAAABwAAAAEAAAAAAAAACQAAABhZGVkNWU4Mi1iOTA5LTQ2MTktOTk0OS1mNWQ3MWRhYzBiY2IAAAAA2P///3ZrDgAEAACAZAAAAAQAAAABAEQARENTZXR0aW5nSW5kZXhCANj///92aw4ABAAAgGQAAAAEAAAAAQB7AEFDU2V0dGluZ0luZGV4NADw////eC8AAKAvAAAAAAAA+P///7AxAAD4////eDIAAPj///8YMwAA+P///1AyAAD4////cDQAAGhiaW4AMAAAABAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAiP///25rIACJwxLZbw/dAQAAAAAgAAAABgAAAAAAAAC4MwAA/////wAAAAD/////mAAAAP////9IAAAAAAAAAAAAAAAAAAAAAAAAACQAAAA4NjE5YjkxNi1lMDA0LTRkZDgtOWI2Ni1kYWU4NmY4MDY2OTgAAAAAiP///25rIACJwxLZbw/dAQAAAAAgMAAAAAAAAAAAAAD//////////wEAAAC4LQAAmAAAAP////8AAAAAAAAAABwAAAAEAAAAAAAAACQAAAA0NjhmZTdlNS0xMTU4LTQ2ZWMtODhiYy01Yjk2YzllNDRmZDAAAAAA2P///3ZrDgAEAACAAAAAAAQAAAABAFwAQUNTZXR0aW5nSW5kZXgxAIj///9uayAAicMS2W8P3QEAAAAAIDAAAAAAAAAAAAAA//////////8BAAAA2C8AAJgAAAD/////AAAAAAAAAAAcAAAABAAAAAAAAAAkAAAANDljYjExYTUtNTZlMi00YWZiLTlkMzgtM2RmNDc4NzJlMjFiAAAAANj///92aw4ABAAAgEsAAAAEAAAAAQA0AERDU2V0dGluZ0luZGV4RACI////bmsgAInDEtlvD90BAAAAACAwAAAAAAAAAAAAAP//////////AQAAAOAvAACYAAAA/////wAAAAAAAAAAHAAAAAQAAAAAAAAAJAAAADYwYzA3ZmUxLTA1NTYtNDVjZi05OTAzLWQ1NmUzMjIxMDI0MgAAAADY////dmsOAAQAAIAFAAAABAAAAAEA8NJEQ1NldHRpbmdJbmRleMq02P///3ZrDgAEAACAhAMAAAQAAAABAAAARENTZXR0aW5nSW5kZXhcAIj///9uayAAicMS2W8P3QEAAAAAIDAAAAAAAAAAAAAA//////////8BAAAA6C8AAJgAAAD/////AAAAAAAAAAAcAAAABAAAAAAAAAAkAAAAODIwMTE3MDUtZmI5NS00ZDQ2LThkMzUtNDA0MmIxZDIwZGVmAAAAANj///92aw4ABAAAgAEAAAAEAAAAAQAtAERDU2V0dGluZ0luZGV4OACI////bmsgAInDEtlvD90BAAAAACAwAAAAAAAAAAAAAP//////////AQAAAPAvAACYAAAA/////wAAAAAAAAAAHAAAAAQAAAAAAAAAJAAAADlmZTUyN2JlLTFiNzAtNDhkYS05MzBkLTdiY2YxN2I0NDk5MAAAAADA////bGYGAJgwAAA0NjhmODEAADQ5Y2LYMQAANjBjMKAyAAA4MjAxQDMAADlmZTX4MwAAYzc2MwAAAAAAAAAAiP///25rIACJwxLZbw/dAQAAAAAgMAAAAAAAAAAAAAD//////////wEAAAD4LwAAmAAAAP////8AAAAAAAAAABwAAAAEAAAAAAAAACQAAABjNzYzZWU5Mi03MWU4LTQxMjctODRlYi1mNmVkMDQzYTNlM2QAAAAA2P///3ZrDgAEAACALAEAAAQAAAABADYARENTZXR0aW5nSW5kZXg0AIj///9uayAAicMS2W8P3QEAAAAAIAAAAAIAAAAAAAAAEDYAAP////8AAAAA/////5gAAAD/////SAAAAAAAAAAAAAAAAAAAAAAAAAAkAAAAOTU5NmZiMjYtOTg1MC00MWZkLWFjM2UtZjdjM2MwMGFmZDRiAAAAAIj///9uayAAicMS2W8P3QEAAAAAmDQAAAAAAAAAAAAA//////////8AAAAA/////5gAAAD/////AAAAAAAAAAAAAAAAAAAAAAAAAAAkAAAAMDM2ODA5NTYtOTNiYy00Mjk0LWJiYTYtNGUwZjA5YmI3MTdmAAAAAPj///8oNgAA+P///1A3AACI////bmsgAKLqEtlvD90BAAAAAJg0AAAAAAAAAAAAAP//////////AQAAAIg1AACYAAAA/////wAAAAAAAAAAHAAAAAQAAAAAAAAAJAAAADM0YzdiOTlmLTlhNmQtNGIzYy04ZGM3LWI2NjkzYjc4Y2VmNAAAAADo////bGYCABA1AAAwMzY4mDUAADM0YzfY////dmsOAAQAAIABAAAAAwAAAAEAQQBEQ1NldHRpbmdJbmRleEIAiP///25rIACi6hLZbw/dAQAAAAAgAAAAAgAAAAAAAADwNwAA/////wAAAAD/////mAAAAP////9IAAAAAAAAAAAAAAAAAAAAAAAAACQAAABkZTgzMDkyMy1hNTYyLTQxYWYtYTA4Ni1lM2EyYzZiYWQyZGEAAAAAiP///25rIACi6hLZbw/dAQAAAABQNgAAAAAAAAAAAAD//////////wEAAACQNQAAmAAAAP////8AAAAAAAAAABwAAAAEAAAAAAAAACQAAAA1YzViYjM0OS1hZDI5LTRlZTItOWQwYi0yYjI1MjcwZjdhODEAAAAA+P///wg4AAAIAAAANWM1Ytj///92aw4ABAAAgAEAAAAEAAAAAQAtAERDU2V0dGluZ0luZGV4MwCI////bmsgAKLqEtlvD90BAAAAAFA2AAAAAAAAAAAAAP//////////AQAAAEA3AACYAAAA/////wAAAAAAAAAAHAAAAAQAAAAAAAAAJAAAAGU2OTY1M2NhLWNmN2YtNGYwNS1hYTczLWNiODMzZmE5MGFkNAAAAADo////bGYCAMg2AAA1YzVieDcAAGU2OTbY////dmsOAAQAAIAUAAAABAAAAAEAAABEQ1NldHRpbmdJbmRleAAAiP///25rIACi6hLZbw/dAQAAAAAgAAAAAgAAAAAAAAAIOgAA/////wAAAAD/////mAAAAP////9IAAAAAAAAAAAAAAAAAAAAAAAAACQAAABlNzNhMDQ4ZC1iZjI3LTRmMTItOTczMS04YjIwNzZlODg5MWYAAAAAiP///25rIACi6hLZbw/dAQAAAAAwOAAAAAAAAAAAAAD//////////wIAAACAOQAAmAAAAP////8AAAAAAAAAABwAAAAEAAAAAAAAACQAAAA2MzdlYTAyZi1iYmNiLTQwMTUtOGUyYy1hMWM3YjljMGI1NDYAAAAA8P///yA6AABIOgAANjM3Zdj///92aw4ABAAAgAEAAAAEAAAAAQAAAEFDU2V0dGluZ0luZGV4AADY////dmsOAAQAAIABAAAABAAAAAEAAABEQ1NldHRpbmdJbmRleAAA8P///zA5AABYOQAAAAAAAIj///9uayAAouoS2W8P3QEAAAAAMDgAAAAAAAAAAAAA//////////8CAAAAIDkAAJgAAAD/////AAAAAAAAAAAcAAAABAAAAAAAAAAkAAAAZDg3NDJkY2ItM2U2YS00YjNjLWIzZmUtMzc0NjIzY2RjZjA2AAAAAOj///9sZgIAqDgAADYzN2WQOQAAZDg3NNj///92aw4ABAAAgAAAAAAEAAAAAQBbikFDU2V0dGluZ0luZGV4XvDY////dmsOAAQAAIABAAAABAAAAAEA3sxEQ1NldHRpbmdJbmRleAAAkAUAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA=
"@

$PowerPlanGUID     = "88888888-8888-8888-8888-888888888888"
$TempPowerPlanPath = "$env:TEMP\da big one.pow"

try {
    $Bytes = [Convert]::FromBase64String($PowerPlanBase64)
    [IO.File]::WriteAllBytes($TempPowerPlanPath, $Bytes)

     $importResult = & powercfg.exe -import $TempPowerPlanPath $PowerPlanGUID 2>&1 | Out-String
    if ($LASTEXITCODE -ne 0) {
        # .pow import can fail on newer builds — fall back to duplicating the built-in High Performance scheme
        Write-Step "Custom plan import failed — falling back to High Performance" "WARN"
        $dupResult = & powercfg.exe -duplicatescheme 8c5e7fda-e8bf-4a96-9a85-a6e23a8c635c 2>&1 | Out-String
        if ($dupResult -match '([0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12})') { $PowerPlanGUID = $Matches[1] }
    }

    & powercfg.exe -setactive $PowerPlanGUID 2>$null | Out-Null
    if ($LASTEXITCODE -ne 0) { Write-Step "Failed to activate power plan" "WARN" }

    if (Test-Path $TempPowerPlanPath) { Remove-Item $TempPowerPlanPath -Force -ErrorAction SilentlyContinue }
} catch {
	    Write-Step "Power plan import failed: $($_.Exception.Message)" "WARN"
}

powercfg -setacvalueindex scheme_current sub_processor cppmflags 0   2>$null | Out-Null
powercfg -setacvalueindex scheme_current sub_processor cpmincores 100 2>$null | Out-Null
powercfg -setactive scheme_current 2>$null | Out-Null

Remove-ItemProperty -Path "HKCU:\Control Panel\Desktop" -Name "SCRNSAVE.EXE" -ErrorAction SilentlyContinue
Write-Step "Screensaver entry removed" "OK"

if ($cs.AutomaticManagedPagefile) {
    Set-CimInstance -InputObject $cs -Property @{AutomaticManagedPagefile=$false} -ErrorAction SilentlyContinue
}
 $pf = Get-CimInstance Win32_PageFileSetting | Where-Object { $_.Name -like "C:*" }
if ($pf) {
    Set-CimInstance -InputObject $pf -Property @{InitialSize=$pageSize; MaximumSize=$pageSize} -ErrorAction SilentlyContinue
} else {
    New-CimInstance -ClassName Win32_PageFileSetting `
        -Property @{Name="C:\pagefile.sys"; InitialSize=$pageSize; MaximumSize=$pageSize} `
        -ErrorAction SilentlyContinue | Out-Null
}
Write-Step "Pagefile set to $pageSize MB (RAM: $ramMB MB)" "OK"

}
}

if (($Section -contains "appx" -or $Section -contains "All") -and -not (Test-SkipSection "appx")) {
# ══════════════════════════════════════════════════════════════════════════════
Write-Section "AppX Bloat Removal"
# ══════════════════════════════════════════════════════════════════════════════
if ($WhatIf) {
    Write-Step "WOULD: Remove AppX packages." "INFO"
} else {
Write-Step "Launching subpowershell..." "WAIT"

 $AppXScriptPayload = @'
 $WarningPreference = $InformationPreference = 'SilentlyContinue'
 $ErrorActionPreference = 'SilentlyContinue'

function Write-SubStep ($App, $Status) {
    Write-Host "  [-] ${Status}: $App" -ForegroundColor Cyan
}

 $WhitelistedApps = 'Microsoft.ScreenSketch|Microsoft.Paint3D|Microsoft.WindowsCalculator|Microsoft.WindowsStore|Microsoft.Windows.Photos|CanonicalGroupLimited.UbuntuonWindows|Microsoft.MSPaint|Microsoft.WindowsCamera|\.NET|Framework|Microsoft.HEIFImageExtension|Microsoft.ScreenSketch|Microsoft.StorePurchaseApp|Microsoft.VP9VideoExtensions|Microsoft.WebMediaExtensions|Microsoft.WebpImageExtension|Microsoft.DesktopAppInstaller|WindSynthBerry|MIDIBerry|Slack|Microsoft.VCLibs.140.00|Microsoft.UI.Xaml|Microsoft.Services.Store.Engagement|Microsoft.OneDriveSync|Microsoft.WindowsTerminal'

 $NonRemovable = '1527c705-839a-4832-9118-54d4Bd6a0c89|c5e2524a-ea46-4f67-841f-6a9465d9d515|E2A4F912-2574-4A75-9BB0-0D023378592B|F46D4000-FD22-4DB4-AC8E-4E1DDDE828FE|InputApp|Microsoft.AAD.BrokerPlugin|Microsoft.AccountsControl|Microsoft.BioEnrollment|Microsoft.CredDialogHost|Microsoft.ECApp|Microsoft.LockApp|Microsoft.MicrosoftEdgeDevToolsClient|Microsoft.MicrosoftEdge|Microsoft.PPIProjection|Microsoft.Win32WebViewHost|Microsoft.Windows.Apprep.ChxApp|Microsoft.Windows.AssignedAccessLockApp|Microsoft.Windows.CapturePicker|Microsoft.Windows.CloudExperienceHost|Microsoft.Windows.ContentDeliveryManager|Microsoft.Windows.NarratorQuickStart|Microsoft.Windows.ParentalControls|Microsoft.Windows.PeopleExperienceHost|Microsoft.Windows.PinningConfirmationDialog|Microsoft.Windows.SecHealthUI|Microsoft.Windows.SecureAssessmentBrowser|Microsoft.Windows.ShellExperienceHost|Microsoft.Windows.XGpuEjectDialog|Windows.CBSPreview|windows.immersivecontrolpanel|Windows.PrintDialog|Microsoft.VCLibs.140.00|Microsoft.Services.Store.Engagement|Microsoft.UI.Xaml.2.0|*Nvidia*'

Get-Process Widget -EA SilentlyContinue | Stop-Process -Force -EA SilentlyContinue
Write-SubStep "Windows Widgets Platform" "Removing"
Get-AppxPackage WidgetsPlatformRuntime -AllUsers -EA SilentlyContinue | ForEach-Object { try { $_ | Remove-AppxPackage -AllUsers -ErrorAction Stop } catch {} }
Get-AppxPackage Client.WebExperience   -AllUsers -EA SilentlyContinue | ForEach-Object { try { $_ | Remove-AppxPackage -AllUsers -ErrorAction Stop } catch {} }

 $TargetApps = @(
    "Microsoft.WindowsFeedbackHub",
    "Microsoft.BingNews",
    "Microsoft.BingSearch",
    "Microsoft.BingWeather",
    "Microsoft.StartExperiencesApp",
    "Microsoft.Copilot",
    "Clipchamp.Clipchamp",
    "Microsoft.Todos",
    "Microsoft.PowerAutomateDesktop",
    "Microsoft.MicrosoftSolitaireCollection",
    "Microsoft.WindowsSoundRecorder",
    "Microsoft.Windows.DevHome",
    "Microsoft.OutlookForWindows",
    "Microsoft.WindowsAlarms",
    "Microsoft.GetHelp",
    "Microsoft.ZuneMusic",
    "Microsoft.ZuneVideo",
    "Microsoft.Getstarted",
    "Microsoft.People",
    "Microsoft.YourPhone",
    "Microsoft.WindowsMaps",
    "MicrosoftCorporationII.QuickAssist",
    "MSTeams",
    "Microsoft.MicrosoftOfficeHub"
)

 $removedCount = 0
foreach ($App in $TargetApps) {
    $ShortName = $App -replace "Microsoft\.", ""
    $pkg = Get-AppxPackage -Name $App -AllUsers -EA SilentlyContinue
    if ($pkg) {
        Write-SubStep $ShortName "Removing"
        try { $pkg | Remove-AppxPackage -AllUsers -ErrorAction Stop } catch { }
        $removedCount++
    }
    Get-AppxProvisionedPackage -Online -EA SilentlyContinue |
        Where-Object { $_.PackageName -like "*$App*" -or $_.DisplayName -eq $App } |
        ForEach-Object { try { $_ | Remove-AppxProvisionedPackage -Online -ErrorAction Stop | Out-Null } catch {} }
}
Write-SubStep "$removedCount targeted apps removed" "Done"

 $sweepCount = 0
Get-AppxPackage -AllUsers | Where-Object {
    $_.Name -NotMatch $WhitelistedApps -and $_.Name -NotMatch $NonRemovable
} | ForEach-Object {
    Write-SubStep $_.Name "Sweep removing"
    try { Remove-AppxPackage -Package $_.PackageFullName -AllUsers -ErrorAction Stop } catch { }
    $sweepCount++
}

Get-AppxProvisionedPackage -Online | Where-Object {
    $_.PackageName -NotMatch $WhitelistedApps -and $_.PackageName -NotMatch $NonRemovable -and $_.DisplayName -NotMatch $NonRemovable
} | ForEach-Object {
    Remove-AppxProvisionedPackage -Online -PackageName $_.PackageName -EA SilentlyContinue
}
Write-SubStep "$sweepCount apps swept" "Done"

if (-not (Get-PSDrive HKCR -EA SilentlyContinue)) {
    New-PSDrive -Name HKCR -PSProvider Registry -Root HKEY_CLASSES_ROOT | Out-Null
}

 $residualKeys = @(
    "HKCR:\Extensions\ContractId\Windows.BackgroundTasks\PackageId",
    "HKCR:\Extensions\ContractId\Windows.File\PackageId",
    "HKCR:\Extensions\ContractId\Windows.Launch\PackageId",
    "HKCR:\Extensions\ContractId\Windows.PreInstalledConfigTask\PackageId",
    "HKCR:\Extensions\ContractId\Windows.Protocol\PackageId",
    "HKCR:\Extensions\ContractId\Windows.ShareTarget\PackageId"
)

 $residualCount = 0
foreach ($basePath in $residualKeys) {
    if (Test-Path $basePath) {
        Get-ChildItem $basePath -EA SilentlyContinue | ForEach-Object {
            $shouldDelete = $false
            $pkgName = $_.PSChildName
            if ($pkgName -NotMatch $WhitelistedApps -and $pkgName -NotMatch $NonRemovable) {
                try {
                    Remove-Item $_.PSPath -Recurse -Force -EA Stop
                    $residualCount++
                } catch {}
            }
        }
    }
}
Write-SubStep "$residualCount registry keys cleaned" "Done"

 $criticalApps = @(
    "Microsoft.WindowsStore",
    "Microsoft.WindowsCalculator",
    "Microsoft.Windows.Photos",
    "Microsoft.DesktopAppInstaller"
)

foreach ($app in $criticalApps) {
    $pkg = Get-AppxPackage -AllUsers -Name $app -EA SilentlyContinue | Select-Object -First 1
    if (-not $pkg) {
        $provPkg = Get-AppxProvisionedPackage -Online -EA SilentlyContinue | Where-Object { $_.DisplayName -eq $app } | Select-Object -First 1
        if ($provPkg -and $provPkg.InstallLocation) {
            $manifest = Join-Path $provPkg.InstallLocation "AppXManifest.xml"
            if (Test-Path $manifest) {
                try {
                    Add-AppxPackage -Register $manifest -DisableDevelopmentMode -EA Stop
                    Write-SubStep $app "Re-installed (was missing)"
                } catch {}
            }
        }
    }
}

 $cloudStore = "HKCU:\Software\Microsoft\Windows\CurrentVersion\CloudStore"
if (Test-Path $cloudStore) {
    Stop-Process -Name explorer -Force -EA SilentlyContinue
    Remove-Item $cloudStore -Recurse -Force -EA SilentlyContinue
    Start-Sleep -Milliseconds 500
    Start-Process explorer.exe
    Write-SubStep "CloudStore cleared." "Done"
}
'@

 $EncodedCommand = [Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($AppXScriptPayload))
powershell.exe -NoProfile -ExecutionPolicy Bypass -EncodedCommand $EncodedCommand

Write-Step "AppX removal finished" "OK"
}
}

if (($Section -contains "sys apps" -or $Section -contains "All") -and -not (Test-SkipSection "sys apps")) {
# ══════════════════════════════════════════════════════════════════════════════
Write-Section "SystemApps stripping"
# ══════════════════════════════════════════════════════════════════════════════
 $SafeToDelete = @(
    "C:\Windows\SystemApps\Microsoft.AsyncTextService_8wekyb3d8bbwe",
    "C:\Windows\SystemApps\Microsoft.ECApp_8wekyb3d8bbwe",
    "C:\Windows\SystemApps\Microsoft.MicrosoftEdgeDevToolsClient_8wekyb3d8bbwe",
    "C:\Windows\SystemApps\Microsoft.Windows.AddSuggestedFoldersToLibraryDialog_cw5n1h2txyewy",
    "C:\Windows\SystemApps\Microsoft.Windows.AppRep.ChxApp_cw5n1h2txyewy",
    "C:\Windows\SystemApps\Microsoft.Windows.AssignedAccessLockApp_cw5n1h2txyewy",
    "C:\Windows\SystemApps\Microsoft.Windows.CallingShellApp_cw5n1h2txyewy",
    "C:\Windows\SystemApps\Microsoft.Windows.ContentDeliveryManager_cw5n1h2txyewy",
    "C:\Windows\SystemApps\microsoft.windows.narratorquickstart_8wekyb3d8bbwe",
    "C:\Windows\SystemApps\Microsoft.Windows.PeopleExperienceHost_cw5n1h2txyewy",
    "C:\Windows\SystemApps\Microsoft.Windows.PinningConfirmationDialog_cw5n1h2txyewy",
    "C:\Windows\SystemApps\Microsoft.Windows.SecureAssessmentBrowser_cw5n1h2txyewy",
    "C:\Windows\SystemApps\Microsoft.Windows.XGpuEjectDialog_cw5n1h2txyewy",
    "C:\Windows\SystemApps\ParentalControls_cw5n1h2txyewy",
    "C:\Windows\SystemApps\Windows.CBSPreview_cw5n1h2txyewy",
    "C:\Windows\SystemApps\MicrosoftWindows.Client.CBS_cw5n1h2txyewy\Assets\Dictation",
    "C:\Windows\SystemApps\MicrosoftWindows.Client.CBS_cw5n1h2txyewy\Assets\Fonts",
    "C:\Windows\SystemApps\MicrosoftWindows.Client.CBS_cw5n1h2txyewy\Assets\Ninja",
    "C:\Windows\SystemApps\MicrosoftWindows.Client.CBS_cw5n1h2txyewy\ScreenClipping\Assets\Fonts",
    "C:\Windows\SystemApps\MicrosoftWindows.Client.CBS_cw5n1h2txyewy\ScreenClipping\Assets\Sounds"
)

 $Win10Only = @(
    "C:\Windows\SystemApps\Microsoft.BioEnrollment_cw5n1h2txyewy",
    "C:\Windows\SystemApps\Microsoft.LockApp_cw5n1h2txyewy"
)

if ($Script:IsWin11) {
    $ShiToDelete = $SafeToDelete
    Write-Step "skipping LockApp and BioEnrollment" "INFO"
} else {
    $ShiToDelete = $SafeToDelete + $Win10Only
}

$ProcessMapping = @{
    "Microsoft.BioEnrollment_cw5n1h2txyewy"               = "BioEnrollmentHost"
    "Microsoft.LockApp_cw5n1h2txyewy"                     = "LockApp"
    "Microsoft.Windows.ContentDeliveryManager_cw5n1h2txyewy" = "BackgroundTransferHost"
    "Microsoft.Windows.SecHealthUI_cw5n1h2txyewy"         = "SecHealthUI"
}

$sysAppsDeleted = 0
$sysAppsFailed = 0

foreach ($folder in $ShiToDelete) {
    if (Test-Path -Path $folder) {
        $leafName = Split-Path $folder -Leaf
        if ($leafName -match "^(Dictation|Fonts|Ninja|Sounds)$") {
            $leafName = "CBS_cw5n1h2txyewy\...\$leafName"
        }

        $folderName = Split-Path $folder -Leaf
        $possibleProc = ""

        if ($ProcessMapping.ContainsKey($folderName)) {
            $possibleProc = $ProcessMapping[$folderName]
        } else {
            $possibleProc = $folderName.Split('_')[0]
            if ($possibleProc -match "Microsoft\.Windows\.(.*)") { 
                $possibleProc = $Matches[1] 
            } elseif ($possibleProc -match "Microsoft\.(.*)") { 
                $possibleProc = $Matches[1] 
            }
        }
        
        if ($possibleProc) {
            $procs = Get-Process -Name $possibleProc -ErrorAction SilentlyContinue
            if ($procs) {
                Write-Step "Terminating active process: $possibleProc" "WAIT"
                $procs | Stop-Process -Force -ErrorAction SilentlyContinue -PassThru | Wait-Process -Timeout 2 -ErrorAction SilentlyContinue
            }
        }

        Write-Step "Taking ownership for: $leafName" "WAIT"
        
        & takeown.exe /f "$folder" /r /d y 2>$null | Out-Null
        & icacls.exe "$folder" /grant administrators:F /t /c /q 2>$null | Out-Null
        
 $result = Invoke-Safe -Action { 
    Remove-Item -Path "$folder" -Recurse -Force -ErrorAction Stop 
} -Description "delete $leafName"

if ($result -and -not (Test-Path -Path $folder)) {
    Write-Step "Deleted: $leafName" "OK"
    $sysAppsDeleted++
} else {
    Write-Step "Failed to completely delete: $leafName" "FAIL"
    $sysAppsFailed++
}
    } else {
        $leafName = Split-Path $folder -Leaf
        if ($leafName -match "^(Dictation|Fonts|Ninja|Sounds)$") { $leafName = "...\\$leafName" }
        Write-Step "Already gone: $leafName" "SKIP"
    }
}

if ($sysAppsDeleted -gt 0) {
    $Script:Passed += $sysAppsDeleted
}
if ($sysAppsFailed -gt 0) {
    $Script:Failed += $sysAppsFailed
    Write-Step "$sysAppsFailed apps left behind (safe mode may help)" "WARN"
}
}

if (($Section -contains "onedrive" -or $Section -contains "All") -and -not (Test-SkipSection "onedrive")) {
# ══════════════════════════════════════════════════════════════════════════════
Write-Section "OneDrive Removal"
# ══════════════════════════════════════════════════════════════════════════════
if ($WhatIf) {
    Write-Step "WOULD: Uninstall OneDrive." "INFO"
} else {
$OneDriveInstalled = $false

$CheckPaths = @(
    "$env:SystemRoot\System32\OneDriveSetup.exe",
    "$env:SystemRoot\SysWOW64\OneDriveSetup.exe",
    "$env:LocalAppData\Microsoft\OneDrive\OneDrive.exe",
    "$env:ProgramData\Microsoft OneDrive"
)

foreach ($p in $CheckPaths) {
    if (Test-Path $p) {
        $OneDriveInstalled = $true
        break
    }
}

if (-not $OneDriveInstalled) {
    Write-Step "OneDrive is already uninstalled." "SKIP"
} else {
    Stop-Process -Name "OneDrive" -Force -ErrorAction SilentlyContinue
    Write-Step "OneDrive process killed" "OK"

    foreach ($s in @("$env:SystemRoot\System32\OneDriveSetup.exe","$env:SystemRoot\SysWOW64\OneDriveSetup.exe")) {
        if (Test-Path $s) {
            Start-Process $s -ArgumentList "/uninstall" -Wait -ErrorAction SilentlyContinue
            Write-Step "Uninstalled: $s" "OK"
        } else { 
            Write-Step "Not found: $(Split-Path $s -Leaf)" "SKIP" 
        }
    }

    @("$env:LocalAppData\Microsoft\OneDrive","$env:ProgramData\Microsoft OneDrive","$env:UserProfile\OneDrive") | ForEach-Object {
        if (Test-Path $_) { 
            Remove-Item $_ -Recurse -Force -EA SilentlyContinue
            Write-Step "Removed: $(Split-Path $_ -Leaf)" "OK" 
        } else { 
            Write-Step "Already gone: $(Split-Path $_ -Leaf)" "SKIP" 
        }
    }

    foreach ($svc in @("OneSyncSvc","OneSyncSvc_")) {
        Get-Service -Name "$svc*" -ErrorAction SilentlyContinue | ForEach-Object {
            switch (disablesvc $_.Name) {
                'ok'      { Write-Step "OneDrive svc disabled: $($_.Name)" "OK" }
                'already' { Write-Step "OneDrive svc already disabled: $($_.Name)" "SKIP" }
            }
        }
    }
}
}
}

if (($Section -contains "teams" -or $Section -contains "All") -and -not (Test-SkipSection "teams")) {
# ══════════════════════════════════════════════════════════════════════════════
Write-Section "Teams Removal"
# ══════════════════════════════════════════════════════════════════════════════
if ($WhatIf) {
    Write-Step "WOULD: Uninstall Teams." "INFO"
} else {

$tp = "$Env:LocalAppData\Microsoft\Teams\Update.exe"
if (Test-Path $tp) {
    Start-Process $tp -ArgumentList "-uninstall" -Wait -EA SilentlyContinue
    Remove-Item (Split-Path $tp) -Recurse -Force -EA SilentlyContinue
    Write-Step "Teams uninstalled" "OK"
} else { Write-Step "Teams not found" "SKIP" }
}
}

if (($Section -contains "Xbox" -or $Section -contains "All") -and -not (Test-SkipSection "Xbox")) {
# ══════════════════════════════════════════════════════════════════════════════
    Write-Section "Xbox removal"
# ══════════════════════════════════════════════════════════════════════════════
	if ($Script:RemoveXbox) {
    $xboxProcesses = @("XboxApp", "XboxGameBar", "XboxGamingOverlay", "XboxIdentityProvider", "XboxLive")
    foreach ($proc in $xboxProcesses) {
        if ($WhatIf) {
            Write-Step "WOULD: Stop process $proc" "INFO"
        } else {
            Get-Process -Name $proc -ErrorAction SilentlyContinue | Stop-Process -Force -ErrorAction SilentlyContinue
            Write-Step "Stopped process: $proc" "OK"
        }
    }

    $xboxServices = @(
        "XblAuthManager",     
        "XblGameSave",         
        "xboxgip",            
        "XboxGipSvc",          
        "XboxNetApiSvc"        
    )
    foreach ($svc in $xboxServices) {
        switch (disablesvc $svc) {
            'ok'      { Write-Step "Service disabled: $svc" "OK" }
            'already' { Write-Step "Service already disabled: $svc" "SKIP" }
            'failed'  { Write-Step "Service access denied: $svc" "WARN"; $Script:Warnings++ }
            default   { Write-Step "Service not found: $svc" "SKIP" }
        }
    }

    $xboxTasks = @(
        @{Name="XblGameSaveTask";        Path="\Microsoft\XblGameSave\"},
        @{Name="XblGameSaveTaskLogon";   Path="\Microsoft\XblGameSave\"}
    )
    foreach ($task in $xboxTasks) {
        if (DisableTask $task.Name $task.Path) {
            Write-Step "Task disabled: $($task.Name)" "OK"
        } else {
            Write-Step "Task not found: $($task.Name)" "SKIP"
        }
    }

    if ($WhatIf) {
        Write-Step "WOULD: Remove Xbox AppX packages" "INFO"
    } else {
        Ensure-Appx
        $xboxAppx = @(
            "Microsoft.Xbox.TCUI",
            "Microsoft.XboxApp",
            "Microsoft.XboxGameCallableUI",
            "Microsoft.XboxGamingOverlay",
            "Microsoft.XboxIdentityProvider",
            "Microsoft.XboxSpeechToTextOverlay",
            "Microsoft.GamingApp"
        )
        foreach ($app in $xboxAppx) {
            $pkg = Get-AppxPackage -Name $app -AllUsers -ErrorAction SilentlyContinue
            if ($pkg) {
                try { $pkg | Remove-AppxPackage -AllUsers -ErrorAction Stop } catch { }
                Write-Step "Removed AppX: $app" "OK"
            } else {
                Write-Step "AppX not found: $app" "SKIP"
            }
            $prov = Get-AppxProvisionedPackage -Online -ErrorAction SilentlyContinue | Where-Object { $_.PackageName -like "*$app*" }
            if ($prov) {
                $prov | Remove-AppxProvisionedPackage -Online -ErrorAction SilentlyContinue
            }
        }
    }

    $xboxRegKeys = @(
        @{ P="HKCU:\System\GameConfigStore"; N="GameDVR_Enabled"; V=0; T="DWord" },
        @{ P="HKCU:\Software\Microsoft\Windows\CurrentVersion\GameDVR"; N="AppCaptureEnabled"; V=0; T="DWord" },
        @{ P="HKCU:\Software\Microsoft\Windows\CurrentVersion\GameDVR"; N="AudioCaptureEnabled"; V=0; T="DWord" },
        @{ P="HKCU:\Software\Microsoft\Windows\CurrentVersion\GameDVR"; N="CursorCaptureEnabled"; V=0; T="DWord" },
        @{ P="HKCU:\Software\Microsoft\Windows\CurrentVersion\GameDVR"; N="MicrophoneCaptureEnabled"; V=0; T="DWord" },
        @{ P="HKCU:\Software\Microsoft\GameBar"; N="AllowAutoGameMode"; V=0; T="DWord" },
        @{ P="HKCU:\Software\Microsoft\GameBar"; N="AutoGameModeEnabled"; V=0; T="DWord" },
        @{ P="HKCU:\Software\Microsoft\GameBar"; N="ShowStartupPanel"; V=0; T="DWord" },
        @{ P="HKCU:\Software\Microsoft\GameBar"; N="UseNexusForGameBarEnabled"; V=0; T="DWord" },
        @{ P="HKCU:\Software\Microsoft\XboxLive"; N="XboxLive"; V=0; T="DWord" }
    )

    $regOK = 0
    foreach ($entry in $xboxRegKeys) {
        if ($WhatIf) {
            Write-Step "WOULD: Set $($entry.N)=$($entry.V) at $($entry.P)" "INFO"
            $regOK++
            continue
        }
        try {
            if (-not (Test-Path $entry.P)) { New-Item -Path $entry.P -Force -ErrorAction Stop | Out-Null }
            Set-ItemProperty -Path $entry.P -Name $entry.N -Value $entry.V -Type $entry.T -Force -ErrorAction Stop
            $regOK++
        } catch {
            Write-Step "Failed to set $($entry.N)" "FAIL"
        }
    }
    Write-Step "Applied $regOK Xbox registry tweaks" "OK"
} else {
        Write-Step "Xbox removal skipped." "SKIP"
    }
}

if (($Section -contains "contextmenu" -or $Section -contains "All") -and -not (Test-SkipSection "contextmenu")) {
# ══════════════════════════════════════════════════════════════════════════════
    Write-Section "Context menus"
# ══════════════════════════════════════════════════════════════════════════════
if ($WhatIf) {
    Write-Step "WOULD: Apply Context Menu tweaks (classic menu, remove Defender/Sharing/Cast/GiveAccess handlers, SendTo cleanup)" "INFO"
} else {
if ($Script:IsWin11) {
    if ($WhatIf) {
        Write-Step "WOULD: Restore classic context menu." "INFO"
    } else {
    $ctxt = "HKCU:\Software\Classes\CLSID\{86ca1aa0-34aa-4e8b-a509-50c905bae2a2}\InprocServer32"
    if (-not (Test-Path $ctxt)) { New-Item -Path $ctxt -Force -EA SilentlyContinue | Out-Null }
    Set-ItemProperty -Path $ctxt -Name "(Default)" -Value "" -Force -EA SilentlyContinue
    Write-Step "Classic context menu restored" "OK"
} 
} else {
    Write-Step "not on Windows11." "SKIP"
}


    $defenderEntries = @(
        "HKCR:\*\shellex\ContextMenuHandlers\EPP",
        "HKCR:\*\shellex\ContextMenuHandlers\{09A47860-11B0-4DA5-AFA5-26D86198A780}",  
        "HKCR:\Folder\shellex\ContextMenuHandlers\EPP",
        "HKCR:\Drive\shellex\ContextMenuHandlers\EPP"
    )

    foreach ($key in $defenderEntries) {
        if (Test-Path $key) {
            if ($WhatIf) {
                Write-Step "WOULD: Remove Defender context menu: $key" "INFO"
            } else {
                Remove-Item -Path $key -Recurse -Force -ErrorAction SilentlyContinue
                Write-Step "Removed Defender context menu: $key" "OK"
            }
        } else {
            Write-Step "Defender context menu already gone: $key" "SKIP"
        }
    }

    $Entries = @(
        "HKCR:\*\shellex\ContextMenuHandlers\Sharing",
		"HKCR:\*\shellex\ContextMenuHandlers\Cast",
        "HKCR:\Folder\shellex\ContextMenuHandlers\Cast",
        "HKCR:\Folder\shellex\ContextMenuHandlers\Sharing"
    )
    foreach ($key in $Entries) {
        if (Test-Path $key) {
            if ($WhatIf) {
                Write-Step "WOULD: Remove Share entry: $key" "INFO"
            } else {
                Remove-Item -Path $key -Recurse -Force -ErrorAction SilentlyContinue
                Write-Step "Removed entry: $key" "OK"
            }
        } else {
            Write-Step "$key entry already gone." "SKIP"
        }
    }

    $giveAccessEntries = @(
        "HKCR:\*\shellex\ContextMenuHandlers\GiveAccess",
        "HKCR:\Folder\shellex\ContextMenuHandlers\GiveAccess"
    )
    foreach ($key in $giveAccessEntries) {
        if (Test-Path $key) {
            if ($WhatIf) {
                Write-Step "WOULD: Remove Give access entry: $key" "INFO"
            } else {
                Remove-Item -Path $key -Recurse -Force -ErrorAction SilentlyContinue
                Write-Step "Removed Give access entry: $key" "OK"
            }
        } else {
            Write-Step "Give access entry already gone: $key" "SKIP"
        }
    }

    $sendToPaths = @(
        "$env:APPDATA\Microsoft\Windows\SendTo\Fax Recipient.lnk",
        "$env:APPDATA\Microsoft\Windows\SendTo\Bluetooth File Transfer.lnk"
    )
    foreach ($path in $sendToPaths) {
        if (Test-Path $path) {
            if ($WhatIf) {
                Write-Step "WOULD: Remove SendTo shortcut: $path" "INFO"
            } else {
                Remove-Item -Path $path -Force -ErrorAction SilentlyContinue
                Write-Step "Removed SendTo shortcut: $path" "OK"
            }
        } else {
            Write-Step "SendTo shortcut already gone: $path" "SKIP"
        }
    }

    $desktopDefender = "HKCR:\DesktopBackground\Shell\WindowsDefender"
    if (Test-Path $desktopDefender) {
        if ($WhatIf) {
            Write-Step "WOULD: Remove Defender desktop context menu: $desktopDefender" "INFO"
        } else {
            Remove-Item -Path $desktopDefender -Recurse -Force -ErrorAction SilentlyContinue
            Write-Step "Removed Defender desktop context menu" "OK"
        }
    } else {
        Write-Step "Defender desktop entry already gone" "SKIP"
    }
}
}

if (($Section -contains "drivers" -or $Section -contains "All") -and -not (Test-SkipSection "drivers")) {
 # ══════════════════════════════════════════════════════════════════════════════
Write-Section "Driver Store Cleanup"
# ══════════════════════════════════════════════════════════════════════════════
Write-Step "getting orphaned drivers.." "WAIT"

$AllDrivers = pnputil.exe /enum-drivers | Select-String -Pattern "Published Name:\s*(oem\d+\.inf)" | ForEach-Object { $_.Matches.Groups[1].Value }

$ActiveDrivers = pnputil.exe /enum-devices /drivers | Select-String -Pattern "Driver Name:\s*(oem\d+\.inf)" | ForEach-Object { $_.Matches.Groups[1].Value } | Select-Object -Unique

if ($null -eq $AllDrivers) { $AllDrivers = @() }
if ($null -eq $ActiveDrivers) { $ActiveDrivers = @() }

$UnusedDrivers = Compare-Object -ReferenceObject $AllDrivers -DifferenceObject $ActiveDrivers -PassThru -ErrorAction SilentlyContinue
if ($WhatIf) {
    Write-Step "WOULD: Remove $($UnusedDrivers.Count) driver packages" "INFO"
} else {

if ($UnusedDrivers -and $UnusedDrivers.Count -gt 0) {
    Write-Step "Found $($UnusedDrivers.Count) useless driver packages" "INFO"
    Write-Step "Purging useless drivers..." "WAIT"

    $drvRemoved = 0
    $drvFailed  = 0

    foreach ($drv in $UnusedDrivers) {
        $result = & pnputil.exe /delete-driver $drv /uninstall 2>$null
        if ($LASTEXITCODE -eq 0) {
            $drvRemoved++
        } else {
            $drvFailed++
        }
    }

    if ($drvRemoved -gt 0) { Write-Step "Successfully removed : $drvRemoved drivers" "OK" }
    if ($drvFailed -gt 0)  { Write-Step "Kept (System Locked) : $drvFailed drivers" "INFO" }
} else {
    Write-Step "No useless drivers found." "SKIP"
}
}
}

if (($Section -contains "Component cleanup" -or $Section -contains "All") -and -not (Test-SkipSection "Component cleanup")) {
# ══════════════════════════════════════════════════════════════════════════════
Write-Section "Component Cleanup"
# ══════════════════════════════════════════════════════════════════════════════
if ($WhatIf) {
    Write-Step "WOULD: Start a compoment cleanup operation." "INFO"
} else {
foreach ($dir in @($Env:Temp, "$Env:SystemRoot\Temp")) {
    if (Test-Path $dir) {
        Get-ChildItem -Path $dir -Recurse -EA SilentlyContinue |
            Remove-Item -Recurse -Force -EA SilentlyContinue > $null 2>&1
        Write-Step "Cleaned: $dir" "OK"
    }
}

Write-Step "DISM cleanup (takes decades)..." "WAIT"
Dism.exe /online /Cleanup-Image /StartComponentCleanup /ResetBase 
if ($LASTEXITCODE -eq 0) {
    Write-Step "DISM cleanup done" "OK"
} else {
    Write-Step "DISM cleanup failed (exit code $LASTEXITCODE)" "WARN"
}

try {
    $storageState = dism.exe /Online /Get-ReservedStorageState /English | Out-String
    
    if ($storageState -match "State : Enabled") {
        Write-Step "Disabling reserved storage..." "WAIT"
        
        dism.exe /Online /Set-ReservedStorageState /State:Disabled /Quiet | Out-Null
        
        if ($LASTEXITCODE -eq 0) {
            Write-Step "Reserved Storage disabled" "OK"
        } else {
            Write-Step "Failed to disable Reserved Storage" "WARN"
        }
    } else {
        Write-Step "Reserved Storage already disabled" "SKIP"
    }
} catch {
    Write-Step "Error processing Reserved Storage" "WARN"
}

Stop-Service -Name "wuauserv" -Force -EA SilentlyContinue

$downloadPath = "C:\Windows\SoftwareDistribution\Download"
if (Test-Path $downloadPath) {
    Remove-Item -Path "$downloadPath\*" -Recurse -Force -EA SilentlyContinue
    Write-Step "Windows Update cache flushed successfully" "OK"
} else {
    Write-Step "cache folder not found" "SKIP"
}

Write-Step "Disabling indexing..." "WAIT"
 $wsearch = Get-Service -Name WSearch -ErrorAction SilentlyContinue
if ($wsearch) {
    if ($wsearch.Status -eq 'Running') {
        Stop-Service -Name WSearch -Force -ErrorAction SilentlyContinue
    }
    Set-Service -Name WSearch -StartupType Disabled -ErrorAction SilentlyContinue
    Write-Step "WSearch service disabled" "OK"
} else {
    Write-Step "WSearch svc not found" "SKIP"
}
attrib.exe +I "C:\*" /D *> $null
Write-Step "Done." "OK"
}
}

if (($Section -contains "features" -or $Section -contains "All") -and -not (Test-SkipSection "features")) {
# ══════════════════════════════════════════════════════════════════════════════
Write-Section "Optional Windows Features"
# ══════════════════════════════════════════════════════════════════════════════
$featureList = @(
    "Recall", "HyperV", "Microsoft-Hyper-V-All", "LegacyComponents", "DirectPlay",
    "MediaPlayback", "WindowsMediaPlayer", "Printing-Foundation-Features",
    "Printing-Foundation-InternetPrinting-Client", "Printing-XPSServices-Features",
    "FaxServicesClientPackage", "WorkFolders-Client", "Microsoft-Windows-Subsystem-Linux",
    "VirtualMachinePlatform", "Windows-Identity-Foundation", "IIS-WebServerRole-Package",
    "Msmq-Container", "TFTP", "TelnetClient", "SmbDirect"
)

foreach ($feature in $featureList) {
    if ($WhatIf) {
        Write-Step "WOULD: Disable feature $feature" "INFO"
        continue
    }
    $f = Get-WindowsOptionalFeature -Online -FeatureName $feature -ErrorAction SilentlyContinue
    if ($f -and $f.State -eq "Enabled") {
        Disable-WindowsOptionalFeature -FeatureName $feature -Online -NoRestart -ErrorAction SilentlyContinue -WarningAction SilentlyContinue | Out-Null
        Write-Step "Disabled feature: $feature" "OK"
    } else {
        Write-Step "Already off : $feature" "SKIP"
    }
}
}

if (($Section -contains "network" -or $Section -contains "All") -and -not (Test-SkipSection "network")) {
# ══════════════════════════════════════════════════════════════════════════════
Write-Section "Network optimization"
# ══════════════════════════════════════════════════════════════════════════════
 if ($WhatIf) {
        Write-Step "WOULD: Apply Network optimization." "INFO"
    } else {
# NetTCPIP/NetAdapter auto-load fails on some builds (remoteIpMoProxy temp path).
# IMPORTANT: Get-Command finds these cmdlets WITHOUT loading the module, so we must
# do real imports and check Get-Module (loaded state), then fall back to WinPS 5.1 copies.
if (-not (Get-Module NetTCPIP)) {
    try { Import-Module NetTCPIP -ErrorAction Stop -WarningAction SilentlyContinue | Out-Null } catch { }
}
if (-not (Get-Module NetTCPIP)) {
    try { Import-Module NetTCPIP -UseWindowsPowerShell -ErrorAction Stop -WarningAction SilentlyContinue | Out-Null } catch { }
}
if (-not (Get-Module NetAdapter)) {
    try { Import-Module NetAdapter -ErrorAction Stop -WarningAction SilentlyContinue | Out-Null } catch { }
}
if (-not (Get-Module NetAdapter)) {
    try { Import-Module NetAdapter -UseWindowsPowerShell -ErrorAction Stop -WarningAction SilentlyContinue | Out-Null } catch { }
}
if (-not (Get-Module DnsClient)) {
    try { Import-Module DnsClient -ErrorAction Stop -WarningAction SilentlyContinue | Out-Null } catch { }
    if (-not (Get-Module DnsClient)) {
        try { Import-Module DnsClient -UseWindowsPowerShell -ErrorAction Stop -WarningAction SilentlyContinue | Out-Null } catch { }
    }
}
if (Get-Module NetTCPIP) {
Set-NetTCPSetting -SettingName internet -AutoTuningLevelLocal normal     -ErrorAction SilentlyContinue
Set-NetTCPSetting -SettingName internet -ScalingHeuristics disabled      -ErrorAction SilentlyContinue
netsh int tcp set supplemental internet congestionprovider=CUBIC 2>$null | Out-Null
Set-NetOffloadGlobalSetting -ReceiveSegmentCoalescing disabled           -ErrorAction SilentlyContinue
Set-NetOffloadGlobalSetting -ReceiveSideScaling enabled                  -ErrorAction SilentlyContinue
Set-NetTCPSetting -SettingName internet -InitialRto 2000                 -ErrorAction SilentlyContinue
Set-NetTCPSetting -SettingName internet -MinRto 200                      -ErrorAction SilentlyContinue
Set-NetTCPSetting -SettingName internet -MaxSynRetransmissions 2         -ErrorAction SilentlyContinue
Set-NetTCPSetting -SettingName internet -NonSackRttResiliency disabled   -ErrorAction SilentlyContinue
Set-NetTCPSetting -SettingName internet -EcnCapability disabled          -ErrorAction SilentlyContinue
Write-Step "TCP stack tuned." "OK"
} else {
    Write-Step "Skipped TCP tuning — NetTCPIP module unavailable" "FAIL"
}

netsh interface teredo set state disabled 2>$null | Out-Null
if (Get-Module NetAdapter) {
Disable-NetAdapterBinding -Name "*" -ComponentID ms_tcpip6 -Confirm:$false -ErrorAction SilentlyContinue
Write-Step "Teredo off · IPv6 disabled" "OK"
} else {
    Write-Step "adapter binding skip — NetAdapter module unavailable." "FAIL"
}

if (Get-Module NetAdapter) {
$adapter = Get-NetAdapter | Where-Object {
    $_.Status -eq "Up" -and
    $_.InterfaceDescription -notlike "*Virtual*" -and
    $_.InterfaceDescription -notlike "*Bluetooth*" -and
    $_.InterfaceDescription -notlike "*Loopback*"
} | Sort-Object -Property LinkSpeed -Descending | Select-Object -First 1

if ($adapter) {
    Write-Step "Adapter: $($adapter.InterfaceDescription)" "INFO"
    if (Get-Module DnsClient) {
        Set-DnsClientServerAddress -InterfaceIndex $adapter.InterfaceIndex -ServerAddresses ("1.1.1.1","1.0.0.1") -ErrorAction SilentlyContinue
        Write-Step "DNS → Cloudflare" "OK"
    } else {
        netsh interface ip set dns name="$($adapter.Name)" source=static addr=1.1.1.1 validate=no 2>$null | Out-Null
        netsh interface ip add dns name="$($adapter.Name)" addr=1.0.0.1 index=2 validate=no 2>$null | Out-Null
        Write-Step "DNS → Cloudflare (via netsh)" "OK"
    }
    Disable-NetAdapterPowerManagement -Name $adapter.Name -ErrorAction SilentlyContinue
    Write-Step "NIC power management disabled" "OK"
    @(
        @{D="Energy Efficient Ethernet"; V="Disabled"       },
        @{D="Green Ethernet";            V="Disabled"       },
        @{D="Flow Control";              V="Disabled"       },
        @{D="Interrupt Moderation";      V="Disabled"       },
        @{D="Receive Side Scaling";      V="Enabled"        },
        @{D="IPv4 Checksum Offload";     V="Rx & Tx Enabled"}
    ) | ForEach-Object {
        Set-NetAdapterAdvancedProperty -Name $adapter.Name -DisplayName $_.D -DisplayValue $_.V -ErrorAction SilentlyContinue
        Write-Step "NIC: $($_.D) → $($_.V)" "OK"
    }
} else {
    Write-Step "No active adapter found" "WARN"
}
} else {
    Write-Step "Skipped adapter tweaks — NetAdapter module unavailable" "FAIL"
}
}
}

if (($Section -contains "cursors" -or $Section -contains "All") -and -not (Test-SkipSection "cursors")) {
# ══════════════════════════════════════════════════════════════════════════════
Write-Section "Cursor Scheme"
# ══════════════════════════════════════════════════════════════════════════════
if ($WhatIf) {
    Write-Step "WOULD: Apply new cursor scheme (download, extract, apply to all users)" "INFO"
} else {
$cursorDir = "$env:SystemRoot\Cursors\cursors"
    New-Item -Path $cursorDir -ItemType Directory -Force | Out-Null

    $cursorZip = "$env:Temp\cursors.zip"
    $cursorUrl = "https://github.com/hmdepic55-netizen/c/raw/refs/heads/main/cursors.zip"
    $cursorHash = "BC44A3CE84B4DCE5E2C55E1346A35C747595C60549CD61EBC8905E338BA63523"

if (Download-FileWithHash -Url $cursorUrl -Destination $cursorZip -ExpectedHash $cursorHash) {
    Write-Step "cursors.zip verified" "OK"
        $sevenZip = "${Env:ProgramFiles}\7-Zip\7z.exe"
        $extractTemp = "$env:Temp\cursors_extract"
        New-Item -Path $extractTemp -ItemType Directory -Force | Out-Null

        if (Test-Path $sevenZip) {
            & $sevenZip x $cursorZip "-o$extractTemp" -y | Out-Null
        } else {
            Expand-Archive -Path $cursorZip -DestinationPath $extractTemp -Force -EA SilentlyContinue
        }

        Get-ChildItem -Path $extractTemp -Recurse -Include *.cur,*.ani -EA SilentlyContinue | ForEach-Object {
            Copy-Item -Path $_.FullName -Destination "$cursorDir\$($_.Name)" -Force -EA SilentlyContinue
        }

        Remove-Item $cursorZip -Force -EA SilentlyContinue
        Remove-Item $extractTemp -Recurse -Force -EA SilentlyContinue

        if (Test-Path "$cursorDir\arrow_no_tail_smaller.cur") {
            Write-Step "Cursor pack extracted" "OK"
        } else {
            Write-Step "Cursor pack extraction failed" "WARN"
        }
    } else {
        Write-Step "Cursor pack download failed" "WARN"
    }

    $gotCursors = Test-Path "$cursorDir\arrow_no_tail_smaller.cur"

    if (-not $gotCursors) {
        Write-Step "Skipping cursor scheme — no cursor files found" "SKIP"
    } else {

        $cursors = @{
            "Arrow"="$cursorDir\arrow_no_tail_smaller.cur"; "Hand"="$cursorDir\link_v2.cur"
            "Wait"="$cursorDir\busy.ani"; "AppStarting"="$cursorDir\working_no_tail.ani"
            "No"="$cursorDir\unavailable.cur"; "NWPen"="$cursorDir\pen.cur"
            "Help"="$cursorDir\help_no_tail.cur"; "IBeam"="$cursorDir\beam_v2.cur"
            "Crosshair"="$cursorDir\cross.cur"; "SizeAll"="$cursorDir\move_v2.cur"
            "SizeNS"="$cursorDir\vertical_v2.cur"; "SizeWE"="$cursorDir\horizontal_v2.cur"
            "SizeNESW"="$cursorDir\diagonal_2.cur"; "SizeNWSE"="$cursorDir\diagonal_1.cur"
            "UpArrow"="$cursorDir\special.cur"
        }

        function Set-CursorKeys {
            param([string]$RegPath)
            foreach ($name in $cursors.Keys) {
                Set-ItemProperty -Path $RegPath -Name $name -Value $cursors[$name] -Type String -Force -EA SilentlyContinue
            }
            Set-ItemProperty -Path $RegPath -Name "(Default)"      -Value "no tail" -Type String -Force -EA SilentlyContinue
            Set-ItemProperty -Path $RegPath -Name "Scheme Source"  -Value 1  -Type DWord -Force -EA SilentlyContinue
            Set-ItemProperty -Path $RegPath -Name "CursorBaseSize" -Value 32 -Type DWord -Force -EA SilentlyContinue
        }

        Set-CursorKeys -RegPath "HKCU:\Control Panel\Cursors"
        if (-not ([System.Management.Automation.PSTypeName]'CursorRefresh.WinAPI').Type) {
    Add-Type -MemberDefinition @"
[DllImport("user32.dll", EntryPoint="SystemParametersInfo")]
public static extern bool SystemParametersInfo(uint uiAction, uint uiParam, uint pvParam, uint fWinIni);
"@ -Name WinAPI -Namespace CursorRefresh
}
        [CursorRefresh.WinAPI]::SystemParametersInfo(0x0057, 0, 0, 0x01 -bor 0x02) | Out-Null
        Write-Step "Cursor scheme applied for current user" "OK"

        try {
            & reg.exe load "HKU\DefaultCursorTemp" "C:\Users\Default\NTUSER.DAT" | Out-Null
            Set-CursorKeys -RegPath "Registry::HKEY_USERS\DefaultCursorTemp\Control Panel\Cursors"
            Write-Step "Cursor scheme set as default for new users" "OK"
        } catch {
            Write-Step "Default profile cursor update failed: $($_.Exception.Message)" "WARN"
        } finally {
            [gc]::Collect()
            & reg.exe unload "HKU\DefaultCursorTemp" | Out-Null
        }

        $profileListPath = "HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\ProfileList"
        $profiles = Get-ChildItem $profileListPath -EA SilentlyContinue | Where-Object { $_.PSChildName -match '^S-1-5-21-' }

        foreach ($p in $profiles) {
            $sid = $p.PSChildName
            $imagePath = (Get-ItemProperty -Path $p.PSPath -Name ProfileImagePath -EA SilentlyContinue).ProfileImagePath
            if (-not $imagePath -or -not (Test-Path $imagePath)) { continue }

            $userName = Split-Path $imagePath -Leaf
            if ($sid -eq ([Security.Principal.WindowsIdentity]::GetCurrent()).User.Value) {
                Write-Step "Skipping $userName (already applied - current user)" "SKIP"
                continue
            }

            if (Test-Path "Registry::HKEY_USERS\$sid") {
                Set-CursorKeys -RegPath "Registry::HKEY_USERS\$sid\Control Panel\Cursors"
                Write-Step "Cursor scheme applied for $userName (live session)" "OK"
            } else {
                $hiveFile = "$imagePath\NTUSER.DAT"
                if (-not (Test-Path $hiveFile)) {
                    Write-Step "$userName - NTUSER.DAT not found, skipped" "WARN"
                    continue
                }
                try {
                    & reg.exe load "HKU\TempCursor_$sid" $hiveFile 2>$null | Out-Null
                    Set-CursorKeys -RegPath "Registry::HKEY_USERS\TempCursor_$sid\Control Panel\Cursors"
                    Write-Step "Cursor scheme applied for $userName (offline)" "OK"
                } catch {
                    Write-Step "$userName - failed: $($_.Exception.Message)" "WARN"
                } finally {
                    [gc]::Collect()
                    & reg.exe unload "HKU\TempCursor_$sid" 2>$null | Out-Null
                }
            }
        }
    }
}
}

if (-not $WhatIf) {
	$icon= read-host "Do you want to clear icon cache? ( recommended) [Y/N]"
	if ($icon -match '^[Yy]$') {
    Stop-Process -Name "explorer" -Force -EA SilentlyContinue
    Remove-Item "$env:LOCALAPPDATA\Microsoft\Windows\Explorer\iconcache*" -Force -Recurse -EA SilentlyContinue
    Write-Step "Icon cache cleared" "OK"
    Start-Process "explorer.exe"
} 
}

if ($Script:DefenderMode -eq 'Session') {
    if (-not $WhatIf) {
        Write-Section "Restoring Defender"
        Set-MpPreference -DisableRealtimeMonitoring $false -ErrorAction SilentlyContinue
        Remove-MpPreference -ExclusionPath $env:TEMP -ErrorAction SilentlyContinue
        Write-Step "Real-time protection re-enabled." "OK"
    } else {
        Write-Step "WOULD: Re‑enable Defender real‑time protection (session restore)" "INFO"
    }
}

Write-Summary  

if (-not $WhatIf) {
    Write-Host ""
    Write-Host "  ╔══════════════════════════════════════════════════════════╗" -ForegroundColor Yellow
    Write-Host "  ║   A restart is recommended to apply all changes.         ║" -ForegroundColor Yellow
    Write-Host "  ║   Always Willing to beat microslop, log saved to desktop.║" -ForegroundColor Yellow
    Write-Host "  ╚══════════════════════════════════════════════════════════╝" -ForegroundColor Yellow
    Write-Host ""

    while ($true) {
        $choice = Read-Host "  [?] Restart now? (Y/N)"
        if ($choice -match '^[Yy]$') {
            Write-Step "Restarting system..." "WAIT"
            Stop-Transcript -ErrorAction SilentlyContinue   
            Restart-Computer -Force
            break
        }
        elseif ($choice -match '^[Nn]$') {
            Write-Step "bye bye. muah" "SKIP"
            Stop-Transcript -ErrorAction SilentlyContinue
            break
        }
        else {
            Write-Host "  [!] Invalid input. i guess bro..." -ForegroundColor Yellow
        }
    }
} else {
    Write-Host ""
    Write-Host "  ╔══════════════════════════════════════════════════════════╗" -ForegroundColor Yellow
    Write-Host "  ║          No changes were made                            ║" -ForegroundColor Yellow
    Write-Host "  ║          Log saved to desktop.                           ║" -ForegroundColor Yellow
    Write-Host "  ╚══════════════════════════════════════════════════════════╝" -ForegroundColor Yellow
    Write-Host ""
    Stop-Transcript -ErrorAction SilentlyContinue
}
