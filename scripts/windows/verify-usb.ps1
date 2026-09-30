<#
  verify-usb.ps1 - check a Rufus-written Windows 11 USB stick against its ISO.

  Runs on the Windows machine that writes the sticks with Rufus, NOT on a target
  machine. Only reads the stick. Mounts the ISO, and unmounts it afterwards if it
  wasn't already mounted. Run elevated (Mount-DiskImage needs it):

    powershell -ExecutionPolicy Bypass -File .\verify-usb.ps1 -IsoPath "C:\...\Win11_French_x64.iso" -UsbDrive E

  Compares the SHA-256 of sources\install.wim on the ISO and on the stick. That file
  is the multi-GB Windows image Setup unpacks during "Installing Windows". A damaged
  copy made Setup fail at ~78% with no detail on 003 (known-issues.md, "Windows
  install"). Only install.wim is compared, on purpose: Rufus edits or adds some
  small files for its Windows 11 bypass options, so comparing every file would
  report mismatches that aren't damage.

  Also prints the ISO file's own SHA-256 (skip with -SkipIsoHash). Compare it with
  a second download of the same ISO (toolkit-reference.md, "ISO sources").

  Exit codes: 0 MATCH, 1 MISMATCH, 2 usage/environment error,
              3 install.wim missing on one side (e.g. split into install.swm).
#>
param(
    [Parameter(Mandatory)] [string] $IsoPath,
    [Parameter(Mandatory)] [string] $UsbDrive,
    [switch] $SkipIsoHash
)
$ErrorActionPreference = 'Stop'
# Any unexpected error exits 2, so it can't be mistaken for exit 1 (MISMATCH),
# which is what PowerShell would otherwise return for an unhandled error.
trap { Write-Host "ERROR: $_"; exit 2 }

$principal = [Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()
if (-not $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    Write-Host 'ERROR: run from an elevated PowerShell (Mount-DiskImage needs it).'
    exit 2
}
if (-not (Test-Path -LiteralPath $IsoPath -PathType Leaf)) {
    Write-Host "ERROR: ISO not found: $IsoPath"
    exit 2
}
$IsoPath   = (Resolve-Path -LiteralPath $IsoPath).Path
$usbLetter = $UsbDrive.TrimEnd(':', '\')    # accept E, E: or E:\
if ($usbLetter -notmatch '^[A-Za-z]$' -or -not (Test-Path "${usbLetter}:\")) {
    Write-Host "ERROR: drive '$UsbDrive' not found. Give the stick's drive letter, e.g. -UsbDrive E"
    exit 2
}

# No 'exit' inside try: errors are recorded in $err/$code so the finally block
# always gets to unmount the ISO.
$err = $null; $code = 0
$isoHash = $null; $usbHash = $null
$weMounted = $false
try {
    if (-not (Get-DiskImage -ImagePath $IsoPath).Attached) {
        Mount-DiskImage -ImagePath $IsoPath | Out-Null
        $weMounted = $true
    }
    # The drive letter can take a moment to appear after mounting.
    $isoLetter = $null
    for ($i = 0; $i -lt 10 -and -not $isoLetter; $i++) {
        $isoLetter = (Get-DiskImage -ImagePath $IsoPath | Get-Volume).DriveLetter
        if (-not $isoLetter) { Start-Sleep -Seconds 1 }
    }
    $isoWim = "${isoLetter}:\sources\install.wim"
    $usbWim = "${usbLetter}:\sources\install.wim"

    if (-not $isoLetter) {
        $err = 'ISO mounted but got no drive letter.'; $code = 2
    } elseif ("$isoLetter" -eq $usbLetter) {
        $err = "-UsbDrive $usbLetter is the mounted ISO itself, not the stick."; $code = 2
    } elseif (-not (Test-Path -LiteralPath $isoWim)) {
        $err = "$isoWim not found - is this a Windows install ISO?"; $code = 3
    } elseif (-not (Test-Path -LiteralPath $usbWim)) {
        $err = "$usbWim not found. If the stick has sources\install.swm or install.esd instead, Rufus split or converted it and this check can't compare it."; $code = 3
    } else {
        Write-Host "ISO       : $IsoPath (mounted as ${isoLetter}:)"
        Write-Host "USB stick : ${usbLetter}:"
        Write-Host 'Hashing install.wim on the ISO...'
        $isoHash = (Get-FileHash -LiteralPath $isoWim -Algorithm SHA256).Hash
        Write-Host 'Hashing install.wim on the stick (a few minutes)...'
        $usbHash = (Get-FileHash -LiteralPath $usbWim -Algorithm SHA256).Hash
    }
} catch {
    $err = "$_"; $code = 2
} finally {
    if ($weMounted) { Dismount-DiskImage -ImagePath $IsoPath | Out-Null }
}
if ($err) {
    Write-Host "ERROR: $err"
    exit $code
}

Write-Host ''
Write-Host "install.wim on ISO   : $isoHash"
Write-Host "install.wim on stick : $usbHash"
if (-not $SkipIsoHash) {
    Write-Host 'Hashing the ISO file itself...'
    Write-Host ("ISO file SHA-256     : {0}" -f (Get-FileHash -LiteralPath $IsoPath -Algorithm SHA256).Hash)
}
Write-Host ''
if ($isoHash -eq $usbHash) {
    Write-Host 'RESULT: MATCH - the stick''s install.wim is identical to the ISO''s.'
    Write-Host '        Record the install.wim hash in the Obsidian note as this stick''s known-good value.'
    exit 0
} else {
    Write-Host 'RESULT: MISMATCH - the stick''s install.wim is damaged. Re-create the stick'
    Write-Host '        (preferably on a different stick) and run this again. Don''t install from it.'
    exit 1
}
