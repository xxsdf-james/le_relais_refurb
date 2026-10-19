<#
  perf-test.ps1 - Le Relais PC refurbishment, HP upgrade test (2026-10).

  Measures how fast one hardware setup is in ways a class notices (boot,
  app launch while Windows is still loading, cold and warm app launch),
  repeated over several reboots, so setups can be compared with numbers:
  HP 8 GB + HDD vs HP 8 GB + SSD vs a Dell OptiPlex 9030 / M900z reference.
  For THROWAWAY test installs only: it creates an auto-logon account whose
  password sits in the registry in clear text (that is how Windows
  auto-logon works).

  Modes (run from an elevated Windows PowerShell unless noted):

    -Setup -Label H1 [-Runs 6]
        Creates local admin "perftest", turns on auto-logon for it, registers
        the logon task, copies this script to C:\ProgramData\RefurbPerf.
        Label = the setup under test (H1, H2, REF-9030, ...): letters,
        digits, - and _ only. Restart afterwards.
    (task) -Cycle
        Run by the logon task, as perftest, NOT elevated (a normal user
        session, like a student's). First logon = warm-up: open Word,
        Excel and Edge once by hand, click through their first-run
        screens, then press Enter. Every later logon = one measured cycle,
        then a restart, until -Runs cycles are done.
    -Monitor [-Minutes 30] [-Tag routine]   (elevation not needed)
        Logs disk and memory counters every 5 s, e.g. during the manual
        30-minute class routine. Feeds the 16 GB question: if available
        memory stays high and pages input/sec stays near 0, more RAM has
        nothing to fix.
    -Report [-SkipWinsat]
        Adds Windows' own boot timings (Diagnostics-Performance event 100),
        runs "winsat disk" (needs the desktop: run -Report at the machine's
        screen, not over SSH), summarises everything, writes
        results\report-<label>.csv and prints it with a SHA-256 to check
        after copying it off the machine. On the laptop:
          printf '%s' "$(tr -d '\r' < report-H1.csv)" | sha256sum
    -Cleanup
        From the normal admin account, not perftest: turns auto-logon off,
        removes the task, the perftest account and its profile. Results
        stay in C:\ProgramData\RefurbPerf\results.

  Cycles alternate between two kinds, half each:
    busy     Word, Excel, Edge launched one after the other as soon as the
             session opens, while Windows is still loading (the start of a
             class).
    settled  wait until the disk has been >= 90% idle on average over 5
             minutes (that wait is itself recorded: settle_s), then Word,
             Excel, Edge cold (first launch since boot), then each again
             warm (second launch, served from memory).
  A launch is timed from Start-Process until the app has a window with a
  title. That is close to, not exactly, "ready to type": calibrate against
  a stopwatch on a couple of runs. Each cycle waits for the disk to settle
  before restarting, so Windows has time to log its boot event.

  Pause Windows Update (Settings > Windows Update > Pause for 1 week) after
  the install is fully updated, so an update doesn't land mid-test.

  KEEP THIS FILE ASCII-ONLY: Windows PowerShell 5.1 reads BOM-less files
  as ANSI, so accented characters would be mangled.
#>

param(
    [switch]$Setup,
    [switch]$Cycle,
    [switch]$Monitor,
    [switch]$Report,
    [switch]$Cleanup,
    [string]$Label,
    [int]$Runs = 6,
    [int]$Minutes = 30,
    [string]$Tag = 'routine',
    [switch]$SkipWinsat
)

$ErrorActionPreference = 'Stop'
$TaskName = 'RefurbPerfTest'
$User     = 'perftest'
$Dir      = 'C:\ProgramData\RefurbPerf'
$ResDir   = Join-Path $Dir 'results'
$RawFile  = Join-Path $ResDir 'raw.csv'
$StateFile = Join-Path $ResDir 'state.txt'      # WARMUP | RUNNING | DONE
$CycleFile = Join-Path $ResDir 'cycle.txt'      # next cycle number
$LastBootFile = Join-Path $ResDir 'last-boot.txt'
$Winlogon = 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Winlogon'

# The apps a class uses, by the name Start-Process resolves (App Paths) and
# the process that ends up owning the window.
$Apps = @(
    @{ Name = 'word';  Exe = 'winword'; Proc = 'WINWORD' },
    @{ Name = 'excel'; Exe = 'excel';   Proc = 'EXCEL' },
    @{ Name = 'edge';  Exe = 'msedge';  Proc = 'msedge' }
)

function Fail([string]$m) { Write-Host "FAILED: $m" -ForegroundColor Red; exit 1 }

function Test-Elevated {
    $id = [Security.Principal.WindowsIdentity]::GetCurrent()
    return (New-Object Security.Principal.WindowsPrincipal $id).IsInRole(
        [Security.Principal.WindowsBuiltInRole]::Administrator)
}

function Read-One([string]$path) {
    if (Test-Path $path) { return ((Get-Content $path -TotalCount 1) -as [string]).Trim() }
    return ''
}

function Get-Setting([string]$name) { return Read-One (Join-Path $ResDir "$name.txt") }

# One row per measurement, long format, so files from several machines can
# simply be stacked on the laptop.
function Add-Row([string]$cycle, [string]$kind, [string]$metric, $value) {
    $row = [pscustomobject]@{
        label = (Get-Setting 'label'); cycle = $cycle; kind = $kind
        metric = $metric; value = [string]$value
    }
    $csv = $row | ConvertTo-Csv -NoTypeInformation
    if (-not (Test-Path $RawFile)) { Set-Content $RawFile $csv[0] -Encoding ASCII }
    Add-Content $RawFile $csv[1] -Encoding ASCII
}

function Format-Sec([double]$s) { return $s.ToString('0.0', [Globalization.CultureInfo]::InvariantCulture) }

# CIM performance classes have the same names on French and English Windows,
# unlike the counter paths typeperf and Get-Counter take.
function Get-DiskIdlePct {
    $d = Get-CimInstance Win32_PerfFormattedData_PerfDisk_PhysicalDisk -Filter "Name='_Total'"
    return [math]::Min(100, [double]$d.PercentIdleTime)
}

# Returns seconds waited, or -1 if the disk never settled within the cap,
# or $null if the counter can't be read (then a fixed 10 min wait is used).
function Wait-DiskSettled([int]$capMin = 45) {
    $window = New-Object System.Collections.Generic.Queue[double]
    $sw = [Diagnostics.Stopwatch]::StartNew()
    try { [void](Get-DiskIdlePct) } catch {
        Write-Host "disk counter unreadable ($($_.Exception.Message)); waiting a fixed 10 min"
        Start-Sleep -Seconds 600
        return $null
    }
    # The first formatted sample is not meaningful (no previous sample to
    # compute a rate from), hence the read above, discarded.
    while ($sw.Elapsed.TotalMinutes -lt $capMin) {
        Start-Sleep -Seconds 5
        $window.Enqueue((Get-DiskIdlePct))
        if ($window.Count -gt 60) { [void]$window.Dequeue() }     # 60 x 5 s = 5 min
        if ($window.Count -eq 60) {
            $avg = ($window | Measure-Object -Average).Average
            if ($avg -ge 90) { return [int]$sw.Elapsed.TotalSeconds }
        }
    }
    return -1
}

function Get-AppWindow([string]$proc) {
    return Get-Process -Name $proc -ErrorAction SilentlyContinue |
        Where-Object { $_.MainWindowHandle -ne 0 -and $_.MainWindowTitle }
}

function Close-App([string]$proc) {
    foreach ($p in @(Get-AppWindow $proc)) { [void]$p.CloseMainWindow() }
    $sw = [Diagnostics.Stopwatch]::StartNew()
    while ((Get-AppWindow $proc) -and $sw.Elapsed.TotalSeconds -lt 10) { Start-Sleep -Milliseconds 500 }
    Get-AppWindow $proc | Stop-Process -Force -ErrorAction SilentlyContinue
}

# Seconds from Start-Process to a titled window, or 'TIMEOUT'.
function Measure-Launch($app, [int]$timeoutSec = 180) {
    Close-App $app.Proc
    $sw = [Diagnostics.Stopwatch]::StartNew()
    Start-Process $app.Exe
    while ($sw.Elapsed.TotalSeconds -lt $timeoutSec) {
        if (Get-AppWindow $app.Proc) { $t = $sw.Elapsed.TotalSeconds; Close-App $app.Proc; return (Format-Sec $t) }
        Start-Sleep -Milliseconds 200
    }
    Close-App $app.Proc
    return 'TIMEOUT'
}

function Restart-Now([string]$why) {
    Write-Host "Restarting in 10 s ($why). Close this window to stop."
    & shutdown.exe /r /t 10 /c "perf-test: $why" | Out-Null
}

function Get-Median([double[]]$v) {
    $s = $v | Sort-Object
    $n = $s.Count
    if ($n -eq 0) { return $null }
    if ($n % 2) { return $s[($n - 1) / 2] }
    return ($s[$n / 2 - 1] + $s[$n / 2]) / 2
}

# ---------------------------------------------------------------- -Setup
if ($Setup) {
    if (-not (Test-Elevated)) { Fail 'not elevated - reopen PowerShell as Administrator' }
    if ($Label -notmatch '^[A-Za-z0-9_-]{1,20}$') { Fail '-Label must be 1-20 letters, digits, - or _ (e.g. H1)' }
    if ($Runs -lt 2) { Fail '-Runs must be at least 2 (one busy + one settled cycle)' }
    if (Get-ScheduledTask -TaskName $TaskName -ErrorAction SilentlyContinue) {
        Fail "task $TaskName already exists - run -Cleanup first"
    }

    # Script folder: only SYSTEM and Administrators may write, because the
    # task runs whatever is in it; Users may read and run it, because the task
    # runs as perftest with a non-elevated token, which doesn't count as
    # admin (without this read grant powershell can't open the script and the
    # task ends at once with 0xFFFD0000). Results folder: perftest may write too.
    New-Item -ItemType Directory -Path $Dir, $ResDir -Force | Out-Null
    & icacls.exe $Dir /inheritance:r /grant:r '*S-1-5-18:(OI)(CI)F' '*S-1-5-32-544:(OI)(CI)F' '*S-1-5-32-545:(OI)(CI)RX' /T /Q | Out-Null
    if ($LASTEXITCODE -ne 0) { Fail "icacls failed on $Dir" }
    Copy-Item $PSCommandPath (Join-Path $Dir 'perf-test.ps1') -Force

    # Random password: auto-logon needs one stored, and it only has to work
    # on this throwaway install.
    $chars = [char[]]'abcdefghijkmnpqrstuvwxyzABCDEFGHJKLMNPQRSTUVWXYZ23456789'
    $plain = -join (1..20 | ForEach-Object { $chars | Get-Random })
    $secure = ConvertTo-SecureString $plain -AsPlainText -Force
    if (Get-LocalUser -Name $User -ErrorAction SilentlyContinue) {
        Set-LocalUser -Name $User -Password $secure
    } else {
        New-LocalUser -Name $User -Password $secure -PasswordNeverExpires -AccountNeverExpires `
            -Description 'perf-test.ps1 throwaway account' | Out-Null
    }
    # By SID: the group is "Administrateurs" on French Windows.
    if (-not (Get-LocalGroupMember -SID 'S-1-5-32-544' | Where-Object { $_.Name -like "*\$User" })) {
        Add-LocalGroupMember -SID 'S-1-5-32-544' -Member $User
    }
    & icacls.exe $ResDir /grant "${env:COMPUTERNAME}\${User}:(OI)(CI)M" /T /Q | Out-Null
    if ($LASTEXITCODE -ne 0) { Fail "icacls failed on $ResDir" }

    Set-ItemProperty $Winlogon AutoAdminLogon '1'
    Set-ItemProperty $Winlogon DefaultUserName $User
    Set-ItemProperty $Winlogon DefaultDomainName $env:COMPUTERNAME
    Set-ItemProperty $Winlogon DefaultPassword $plain
    # A count left by an unattended install (the test VM had 9996) makes
    # Windows stop auto-logon when it reaches 0, possibly mid-test.
    Remove-ItemProperty $Winlogon AutoLogonCount -ErrorAction SilentlyContinue

    $action = New-ScheduledTaskAction -Execute 'powershell.exe' -Argument (
        "-NoProfile -ExecutionPolicy Bypass -File `"$Dir\perf-test.ps1`" -Cycle")
    $trigger = New-ScheduledTaskTrigger -AtLogOn -User "$env:COMPUTERNAME\$User"
    $principal = New-ScheduledTaskPrincipal -UserId "$env:COMPUTERNAME\$User" -LogonType Interactive -RunLevel Limited
    $settings = New-ScheduledTaskSettingsSet -ExecutionTimeLimit (New-TimeSpan -Hours 12) `
        -MultipleInstances IgnoreNew -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries
    Register-ScheduledTask -TaskName $TaskName -Action $action -Trigger $trigger `
        -Principal $principal -Settings $settings | Out-Null

    Set-Content (Join-Path $ResDir 'label.txt') $Label -Encoding ASCII
    Set-Content (Join-Path $ResDir 'runs.txt') $Runs -Encoding ASCII
    Set-Content (Join-Path $ResDir 'setup-time.txt') (Get-Date -Format o) -Encoding ASCII
    Set-Content $StateFile 'WARMUP' -Encoding ASCII
    Set-Content $CycleFile '1' -Encoding ASCII
    # Leftovers from an earlier label on this machine would mix into -Report.
    Remove-Item $RawFile, $LastBootFile -ErrorAction SilentlyContinue
    Get-ChildItem $ResDir -Filter 'monitor-*.csv' | Remove-Item

    $t = Get-ScheduledTask -TaskName $TaskName
    Write-Host ''
    Write-Host "Label       : $Label, $Runs cycles"
    Write-Host "Task        : $($t.TaskName) [$($t.State)], runs as $($t.Principal.UserId) $($t.Principal.RunLevel)"
    Write-Host "Auto-logon  : $((Get-ItemProperty $Winlogon).DefaultUserName)"
    Write-Host ''
    Write-Host 'Pause Windows Update for a week if not done, then restart. perftest signs in'
    Write-Host 'by itself and asks for the warm-up.'
    exit 0
}

# ---------------------------------------------------------------- -Cycle
if ($Cycle) {
  $taskStart = Get-Date      # first thing: logon_task_s is boot -> here
  # Runs in a window nobody launched by hand: on an error, keep it open
  # long enough to read instead of letting it vanish.
  try {
    $boot = (Get-CimInstance Win32_OperatingSystem).LastBootUpTime
    $state = Read-One $StateFile
    $runsTotal = [int](Get-Setting 'runs')

    # Keep the machine awake while this runs (no persistent power change).
    try {
        Add-Type -Namespace Refurb -Name Power -MemberDefinition @'
[System.Runtime.InteropServices.DllImport("kernel32.dll")]
public static extern uint SetThreadExecutionState(uint esFlags);
'@
        [void][Refurb.Power]::SetThreadExecutionState([uint32]'0x80000001')
    } catch { }

    if ($state -eq 'DONE') {
        Write-Host 'All cycles done. Open PowerShell as Administrator and run:'
        Write-Host "  powershell -ExecutionPolicy Bypass -File $Dir\perf-test.ps1 -Report"
        Read-Host 'Press Enter to close'
        exit 0
    }

    if ($state -eq 'WARMUP') {
        Write-Host 'WARM-UP (not measured)'
        Write-Host 'Open Word, Excel and Edge once each, click through every first-run'
        Write-Host 'screen (privacy, sign-in prompts: skip or close), then close them.'
        Write-Host 'Then click THIS window''s title bar (not inside it: that starts text'
        Write-Host 'selection and the window ignores Enter until another key is pressed).'
        Read-Host 'Press Enter here when done; the machine restarts and measuring starts'
        Set-Content $StateFile 'RUNNING' -Encoding ASCII
        Restart-Now 'warm-up done'
        exit 0
    }

    # A sign-out and back in is not a new boot: don't measure it twice.
    $bootKey = $boot.ToString('o')
    if ((Read-One $LastBootFile) -eq $bootKey) {
        Write-Host 'This boot was already measured. Restart to run the next cycle.'
        exit 0
    }
    Set-Content $LastBootFile $bootKey -Encoding ASCII

    $n = [int](Read-One $CycleFile)
    $kind = if ($n % 2) { 'busy' } else { 'settled' }
    Write-Host "Cycle $n of $runsTotal ($kind). Don't use the machine until it restarts."

    Add-Row $n $kind 'boot_time' $bootKey
    Add-Row $n $kind 'logon_task_s' (Format-Sec ($taskStart - $boot).TotalSeconds)

    if ($kind -eq 'busy') {
        foreach ($a in $Apps) {
            $r = Measure-Launch $a
            Write-Host "  $($a.Name) (busy): $r"
            Add-Row $n $kind "$($a.Name)_busy_s" $r
            Start-Sleep -Seconds 3
        }
        Write-Host 'Waiting for the disk to settle before restarting...'
        [void](Wait-DiskSettled)
    } else {
        Write-Host 'Waiting for the disk to settle...'
        $settle = Wait-DiskSettled
        Add-Row $n $kind 'settle_s' $(if ($null -eq $settle) { 'UNREADABLE' } elseif ($settle -lt 0) { 'TIMEOUT' } else { $settle })
        foreach ($phase in 'cold', 'warm') {
            foreach ($a in $Apps) {
                $r = Measure-Launch $a
                Write-Host "  $($a.Name) ($phase): $r"
                Add-Row $n $kind "$($a.Name)_${phase}_s" $r
                Start-Sleep -Seconds 5
            }
        }
    }

    if ($n -ge $runsTotal) {
        Set-Content $StateFile 'DONE' -Encoding ASCII
        Write-Host ''
        Write-Host 'All cycles done. Open PowerShell as Administrator and run:'
        Write-Host "  powershell -ExecutionPolicy Bypass -File $Dir\perf-test.ps1 -Report"
        Read-Host 'Press Enter to close'
        exit 0
    }
    Set-Content $CycleFile ($n + 1) -Encoding ASCII
    Restart-Now "cycle $n done"
    exit 0
  } catch {
    Write-Host "FAILED: $($_.Exception.Message)" -ForegroundColor Red
    Write-Host "Cycle not counted; restarting runs it again. Stop: -Cleanup from the admin account."
    Read-Host 'Press Enter to close'
    exit 1
  }
}

# --------------------------------------------------------------- -Monitor
if ($Monitor) {
    if ($Tag -notmatch '^[A-Za-z0-9_-]{1,20}$') { Fail '-Tag must be 1-20 letters, digits, - or _' }
    New-Item -ItemType Directory -Path $ResDir -Force | Out-Null
    $out = Join-Path $ResDir "monitor-$Tag.csv"
    Set-Content $out 'time,disk_idle_pct,disk_queue,disk_reads_s,avail_mb,committed_mb,pages_input_s' -Encoding ASCII
    Write-Host "Logging every 5 s for $Minutes min to $out (Ctrl+C stops early; samples so far are kept)."
    [void](Get-DiskIdlePct)      # discard the first formatted sample
    $end = (Get-Date).AddMinutes($Minutes)
    while ((Get-Date) -lt $end) {
        Start-Sleep -Seconds 5
        $d = Get-CimInstance Win32_PerfFormattedData_PerfDisk_PhysicalDisk -Filter "Name='_Total'"
        $m = Get-CimInstance Win32_PerfFormattedData_PerfOS_Memory
        # All integers: -f formats with the current culture, and a French
        # decimal comma would split a column.
        Add-Content $out ('{0},{1},{2},{3},{4},{5},{6}' -f (Get-Date -Format 'HH:mm:ss'),
            [int][math]::Min(100, [double]$d.PercentIdleTime), [int]$d.CurrentDiskQueueLength,
            [int]$d.DiskReadsPersec, [int]$m.AvailableMBytes, [int]($m.CommittedBytes / 1MB),
            [int]$m.PagesInputPersec) -Encoding ASCII
    }
    Write-Host 'Done. -Report includes it.'
    exit 0
}

# ---------------------------------------------------------------- -Report
if ($Report) {
    if (-not (Test-Elevated)) { Fail 'not elevated - reopen PowerShell as Administrator (event log and winsat need it)' }
    if (-not (Test-Path $RawFile)) { Fail "no measurements in $RawFile" }
    $label = Get-Setting 'label'
    $raw = @(Import-Csv $RawFile)
    $rows = New-Object System.Collections.Generic.List[object]
    foreach ($r in $raw) { $rows.Add($r) }
    function Add-Out([string]$cycle, [string]$kind, [string]$metric, $value) {
        $rows.Add([pscustomobject]@{ label = $label; cycle = $cycle; kind = $kind; metric = $metric; value = [string]$value })
    }

    # Windows' own boot timing, matched to each cycle's boot: the first
    # event 100 logged within 30 min after it.
    $since = [datetime]::Parse((Get-Setting 'setup-time'))
    $events = @(Get-WinEvent -FilterHashtable @{
        LogName = 'Microsoft-Windows-Diagnostics-Performance/Operational'; Id = 100; StartTime = $since
    } -ErrorAction SilentlyContinue | Sort-Object TimeCreated)
    if ($events.Count -eq 0) { Write-Host 'WARNING no boot events (event 100) since setup - boot timings left out' -ForegroundColor Yellow }
    foreach ($b in ($raw | Where-Object { $_.metric -eq 'boot_time' })) {
        $bt = [datetime]::Parse($b.value)
        $ev = $events | Where-Object { $_.TimeCreated -gt $bt -and $_.TimeCreated -lt $bt.AddMinutes(30) } | Select-Object -First 1
        if (-not $ev) { continue }
        $data = @{}
        foreach ($x in ([xml]$ev.ToXml()).Event.EventData.Data) { $data[$x.Name] = $x.'#text' }
        foreach ($f in 'BootTime', 'MainPathBootTime', 'BootPostBootTime') {
            if ($data[$f]) { Add-Out $b.cycle $b.kind "event100_${f}_ms" $data[$f] }
        }
    }

    # winsat's XML, not its console text: the text is translated (French on
    # these machines), the XML's kind="..." labels and numbers are not.
    # winsat needs a desktop (it creates a Direct3D device even for the disk
    # test): from an SSH session it fails with exit 24 and writes nothing.
    if (-not $SkipWinsat) {
        Write-Host 'Running winsat disk (under a minute on an SSD, longer on a hard disk)...'
        $wx = Join-Path $ResDir 'winsat.xml'
        Remove-Item $wx -ErrorAction SilentlyContinue
        & winsat.exe disk -drive c -xml $wx 2>&1 | Out-Null
        $wsExit = $LASTEXITCODE
        if ($wsExit -ne 0 -or -not (Test-Path $wx)) {
            Write-Host "WARNING winsat failed (exit $wsExit): run -Report from a PowerShell window at the machine's own screen, not over SSH" -ForegroundColor Yellow
        } else {
            $dm = ([xml](Get-Content $wx)).WinSAT.Metrics.DiskMetrics
            foreach ($p in @(@('Random Read', 'winsat_random_read_mbs'), @('Sequential Read', 'winsat_seq_read_mbs'))) {
                $n = @($dm.AvgThroughput | Where-Object { $_.kind -eq $p[0] })
                if ($n.Count) { Add-Out 'disk' '' $p[1] $n[0].'#text' }
                else { Write-Host "WARNING winsat: no '$($p[0])' in $wx" -ForegroundColor Yellow }
            }
            $lat = @($dm.MeanLatency | Where-Object { $_.Kind -eq 'Read With Random Background Writes' })
            if ($lat.Count) { Add-Out 'disk' '' 'winsat_read_latency_us' $lat[0].'#text' }
        }
    }

    foreach ($f in @(Get-ChildItem $ResDir -Filter 'monitor-*.csv')) {
        $s = @(Import-Csv $f.FullName)
        if ($s.Count -eq 0) { continue }
        $tag = $f.BaseName -replace '^monitor-', ''
        $idle = [double[]]($s | ForEach-Object { [double]$_.disk_idle_pct })
        $busyPct = 100 * @($idle | Where-Object { $_ -lt 10 }).Count / $idle.Count
        Add-Out "mon-$tag" '' 'samples' $s.Count
        Add-Out "mon-$tag" '' 'disk_idle_pct_median' (Format-Sec (Get-Median $idle))
        Add-Out "mon-$tag" '' 'disk_saturated_pct_of_time' (Format-Sec $busyPct)
        Add-Out "mon-$tag" '' 'avail_mb_min' (($s | ForEach-Object { [double]$_.avail_mb } | Measure-Object -Minimum).Minimum)
        Add-Out "mon-$tag" '' 'committed_mb_max' (($s | ForEach-Object { [double]$_.committed_mb } | Measure-Object -Maximum).Maximum)
        Add-Out "mon-$tag" '' 'pages_input_s_max' (($s | ForEach-Object { [double]$_.pages_input_s } | Measure-Object -Maximum).Maximum)
        Add-Out "mon-$tag" '' 'pages_input_s_median' (Format-Sec (Get-Median ([double[]]($s | ForEach-Object { [double]$_.pages_input_s }))))
    }

    # What was tested, without anything that identifies the unit (no serial,
    # no hostname).
    $cs = Get-CimInstance Win32_ComputerSystem
    $cv = Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion'
    Add-Out 'info' '' 'model' $cs.Model
    Add-Out 'info' '' 'ram_gb' ([math]::Round($cs.TotalPhysicalMemory / 1GB, 1))
    Add-Out 'info' '' 'cpu' ((Get-CimInstance Win32_Processor | Select-Object -First 1).Name.Trim())
    foreach ($pd in @(Get-PhysicalDisk)) { Add-Out 'info' '' 'disk' "$($pd.FriendlyName) / $($pd.MediaType) / $($pd.BusType)" }
    Add-Out 'info' '' 'windows' "$($cv.DisplayVersion) build $($cv.CurrentBuild).$($cv.UBR)"

    $out = Join-Path $ResDir "report-$label.csv"
    $lines = @($rows | ConvertTo-Csv -NoTypeInformation)
    Set-Content $out $lines -Encoding ASCII

    Write-Host ''
    Write-Host "Summary for $label (median, min-max, n):"
    $numeric = $rows | Where-Object { $_.metric -ne 'boot_time' -and $_.cycle -notmatch '^(info|disk|mon-)' }
    foreach ($g in ($numeric | Group-Object metric | Sort-Object Name)) {
        $v = [double[]]@($g.Group | Where-Object { $_.value -match '^[\d.]+$' } | ForEach-Object { [double]$_.value })
        $bad = $g.Count - $v.Count
        $txt = if ($v.Count) { '{0}  ({1}-{2}, n={3})' -f (Get-Median $v), ($v | Measure-Object -Minimum).Minimum, ($v | Measure-Object -Maximum).Maximum, $v.Count } else { '-' }
        if ($bad) { $txt += "  + $bad TIMEOUT/UNREADABLE" }
        Write-Host ('  {0,-34} {1}' -f $g.Name, $txt)
    }
    foreach ($r in ($rows | Where-Object { $_.cycle -match '^(info|disk|mon-)' })) {
        Write-Host ('  {0,-12} {1,-28} {2}' -f $r.cycle, $r.metric, $r.value)
    }

    # Hash of the lines joined with LF, no trailing newline: survives a copy
    # through a web page that changes line endings.
    $bytes = [Text.Encoding]::ASCII.GetBytes(($lines -join "`n"))
    $hash = -join ([Security.Cryptography.SHA256]::Create().ComputeHash($bytes) | ForEach-Object { $_.ToString('x2') })
    Write-Host ''
    Write-Host "----- $out -----"
    $lines | ForEach-Object { Write-Host $_ }
    Write-Host '-----'
    Write-Host "SHA-256 (LF line endings): $hash"
    exit 0
}

# --------------------------------------------------------------- -Cleanup
if ($Cleanup) {
    if (-not (Test-Elevated)) { Fail 'not elevated - reopen PowerShell as Administrator' }
    if ([Environment]::UserName -eq $User) { Fail "signed in as $User - sign in with the normal admin account and run -Cleanup from there" }
    if ((Get-ItemProperty $Winlogon -ErrorAction SilentlyContinue).DefaultUserName -eq $User) {
        Set-ItemProperty $Winlogon AutoAdminLogon '0'
        Remove-ItemProperty $Winlogon DefaultPassword -ErrorAction SilentlyContinue
        Remove-ItemProperty $Winlogon DefaultUserName -ErrorAction SilentlyContinue
        Write-Host 'auto-logon off'
    }
    if (Get-ScheduledTask -TaskName $TaskName -ErrorAction SilentlyContinue) {
        Unregister-ScheduledTask -TaskName $TaskName -Confirm:$false
        Write-Host "task $TaskName removed"
    }
    $acct = Get-LocalUser -Name $User -ErrorAction SilentlyContinue
    if ($acct) {
        Get-CimInstance Win32_UserProfile | Where-Object { $_.SID -eq $acct.SID.Value } | Remove-CimInstance
        Remove-LocalUser -Name $User
        Write-Host "account $User and its profile removed"
    }
    Write-Host "Results kept in $ResDir"
    exit 0
}

Write-Host 'Give one of -Setup, -Monitor, -Report, -Cleanup (see the header of this file).'
exit 1
