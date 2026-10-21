<#
  install-office.ps1 - install Microsoft 365 Apps (Word, Excel, PowerPoint)
  with the Office Deployment Tool, using office-configuration.xml.

  Run in an elevated Windows PowerShell, after fetching this script and
  office-configuration.xml individually via Invoke-WebRequest and checking
  both SHA-256 values (see CLAUDE.md, "Delivery to target machines"):

    powershell -NoProfile -ExecutionPolicy Bypass -File .\install-office.ps1

  The ODT's setup.exe is downloaded from Microsoft at run time and can't be
  pinned to a checksum (Microsoft republishes it with each ODT release), so
  it is checked by its Authenticode signature instead: it must be valid and
  issued to Microsoft Corporation, or nothing runs. Office itself then
  downloads from Microsoft's Office CDN (officecdn.microsoft.com), about
  2-3 GB per machine. Both pass through on the Le Relais network
  (2026-10-20: a Lenovo, and the HP 036 in 11 min).

  No licence is needed to install. Word and Excel open unlicensed and ask
  for a sign-in; the licence decides activation, not installation (see the
  header of office-configuration.xml).

  Switches:
    -SetupUrl URL      where to get setup.exe (default: Office CDN)
    -SetupPath PATH    use a setup.exe you already have (still signature-checked)
    -Attempts N        tries of setup.exe before giving up (default 3)
    -RetryDelaySec N   wait between tries (default 60)

  Log: C:\ProgramData\Refurb\office-install.log

  KEEP THIS FILE ASCII-ONLY: Windows PowerShell 5.1 reads BOM-less files
  as ANSI, so accented characters would be mangled.
#>

param(
    [string]$SetupUrl = 'https://officecdn.microsoft.com/pr/wsus/setup.exe',
    [string]$SetupPath,
    [int]$Attempts = 3,
    [int]$RetryDelaySec = 60
)

$ErrorActionPreference = 'Stop'
$Dir     = 'C:\ProgramData\Refurb'
$Work    = Join-Path $Dir 'office'
$LogFile = Join-Path $Dir 'office-install.log'
$Config  = Join-Path $PSScriptRoot 'office-configuration.xml'
$C2R     = 'HKLM:\SOFTWARE\Microsoft\Office\ClickToRun\Configuration'

function Write-Log([string]$msg) {
    $line = "$(Get-Date -Format o)  $msg"
    Write-Host $line
    Add-Content -Path $LogFile -Value $line -Encoding UTF8
}
function Fail([string]$m) { Write-Log "FAILED: $m"; exit 1 }

# 1. Elevated?
$id = [Security.Principal.WindowsIdentity]::GetCurrent()
if (-not (New-Object Security.Principal.WindowsPrincipal $id).IsInRole(
        [Security.Principal.WindowsBuiltInRole]::Administrator)) {
    Write-Host 'FAILED: not elevated - reopen PowerShell as Administrator' -ForegroundColor Red
    exit 1
}
New-Item -ItemType Directory -Path $Work -Force | Out-Null

# 2. Configuration next to this script, and well-formed.
if (-not (Test-Path $Config)) { Fail "missing office-configuration.xml next to this script ($PSScriptRoot)" }
try { [void][xml](Get-Content $Config -Raw) } catch { Fail "office-configuration.xml is not valid XML: $($_.Exception.Message)" }
Copy-Item $Config (Join-Path $Work 'configuration.xml') -Force

# 3. setup.exe: download unless given, then check who signed it.
$setup = Join-Path $Work 'setup.exe'
if ($SetupPath) {
    Copy-Item $SetupPath $setup -Force
    Write-Log "using setup.exe from $SetupPath"
} else {
    Write-Log "downloading setup.exe from $SetupUrl"
    try { Invoke-WebRequest -Uri $SetupUrl -OutFile $setup -UseBasicParsing }
    catch { Fail "download failed: $($_.Exception.Message)" }
}
$sig = Get-AuthenticodeSignature $setup
$subject = if ($sig.SignerCertificate) { $sig.SignerCertificate.Subject } else { '(none)' }
if ($sig.Status -ne 'Valid' -or $subject -notmatch 'O=Microsoft Corporation') {
    Fail "setup.exe signature not trusted: status=$($sig.Status) signer=$subject"
}
$ver = (Get-Item $setup).VersionInfo.FileVersion
Write-Log "setup.exe $ver, signature Valid, signer: $subject"

# 4. Install. Display Level=None in the configuration: no window; this waits.
# setup.exe gives up on a single failed web request (seen on the test VM:
# exit 2250 after a 60 s timeout, 0x80072ee2, reaching
# mrodevicemgr.officeapps.live.com; the retry minutes later went through).
# Re-running /configure is safe: it carries on from whatever is in place.
# -NoNewWindow: setup.exe is a console program, so without it Windows opens
# an empty console titled with its path for the whole install.
$exit = $null
for ($attempt = 1; $attempt -le $Attempts; $attempt++) {
    Write-Log "install START, attempt $attempt of $Attempts (downloads Office from the Office CDN, can take 10-30 min)"
    $p = Start-Process -FilePath $setup -ArgumentList '/configure', "`"$Work\configuration.xml`"" `
            -WorkingDirectory $Work -NoNewWindow -Wait -PassThru
    $exit = $p.ExitCode
    Write-Log "install END, attempt $attempt, setup.exe exit code $exit"
    if ($exit -eq 0) { break }
    if ($attempt -lt $Attempts) {
        Write-Log "retrying in $RetryDelaySec s"
        Start-Sleep -Seconds $RetryDelaySec
    }
}
if ($exit -ne 0) {
    Fail "setup.exe exit code $exit after $Attempts attempt(s) - see the newest <MACHINE>-<date>.log in $env:TEMP"
}

# 5. Read back what Click-to-Run actually installed, rather than trusting the config.
if (-not (Test-Path $C2R)) { Fail "exit code 0 but no Click-to-Run configuration in the registry ($C2R)" }
$c = Get-ItemProperty $C2R
Write-Log "installed: $($c.ProductReleaseIds) $($c.VersionToReport) $($c.Platform), channel $($c.UpdateChannel)"
Write-Log "SharedComputerLicensing=$($c.SharedComputerLicensing)"
$root = Join-Path $env:ProgramFiles 'Microsoft Office\root\Office16'
foreach ($exe in 'WINWORD.EXE', 'EXCEL.EXE', 'POWERPNT.EXE') {
    if (-not (Test-Path (Join-Path $root $exe))) { Fail "$exe not found in $root" }
}
Write-Log 'DONE - Word, Excel and PowerPoint present'
exit 0
