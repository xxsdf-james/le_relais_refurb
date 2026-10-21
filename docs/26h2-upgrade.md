# 25H2 → 26H2 upgrade (tested, set aside) — DRAFT, 2026-10-19

**Status:** not used in this batch. Decision (James, with Le Relais IT, 2026-10-19): every
machine stays on 25H2, which has had a year of fixes. This procedure is kept for the
upgrade that becomes necessary before 25H2 Home/Pro stops getting security updates on
**12 October 2027** (third-party sites citing Microsoft's servicing table; Microsoft's own
lifecycle page not opened).

**Tested:** on 038 (M900z, 25H2), 2026-10-19, by James. The download and every command
below worked. Not recorded: how long it took, the resulting build number, and the
activation/watermark checks one by one. 038 was then reinstalled with 25H2.

## Why it works

KB5121794 is an "enablement package": 26H2's features already ship, switched off, inside
the monthly 25H2 cumulative updates, and the package switches them on. One restart; apps
and files stay ([Microsoft KB5121794](https://support.microsoft.com/help/5121794)).
Windows Update doesn't offer it to unsupported machines, so it's installed by hand.

## Where the file comes from

Not on the Microsoft Update Catalog (searched 2026-10-19: no results; the KB page says it
is "only available through the other release channels"). The `.msu` is on Microsoft's own
download server, `catalog.sf.dl.delivery.mp.microsoft.com` (link found via
[Pureinfotech](https://pureinfotech.com/windows-11-26h2-enablement-package-download/)).
That host was reachable from 038 on the Le Relais network without interception
(2026-10-19).

Integrity: no SHA-256 published. The 40-hex string in the file name is the file's SHA-1
(Microsoft's naming convention for these files, not a documented guarantee), plus the
Authenticode signature. Once checked, keep the SHA-256 in the Obsidian note and check
later downloads against it.

## Procedure (administrator PowerShell on the target machine)

1. Check the version, then run Windows Update until nothing is left. Microsoft requires
   KB5124010 (2026-09-22) or a later cumulative update first.
   ```
   Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion' | Select DisplayVersion, CurrentBuild, UBR
   ```
   → `25H2`, `26200`.
2. Download:
   ```
   cd $env:USERPROFILE\Downloads
   $f = 'Windows11.0-KB5121794-x64_5e20a3cce48d6611b16bdec42b07167f5456586a.msu'
   Invoke-WebRequest -Uri "https://catalog.sf.dl.delivery.mp.microsoft.com/filestreamingservice/files/94520a88-858f-4832-a57d-7211f6d84a4e/public/$f" -OutFile $f
   ```
   A TLS/certificate error means the network is intercepting the host: don't bypass it;
   download on the laptop and carry the file on USB instead.
3. Verify:
   ```
   (Get-FileHash $f -Algorithm SHA1).Hash          # 5E20A3CCE48D6611B16BDEC42B07167F5456586A
   Get-AuthenticodeSignature $f | Format-List Status, SignerCertificate   # Valid, Microsoft
   (Get-FileHash $f -Algorithm SHA256).Hash        # record / compare with the Obsidian note
   ```
4. Install and restart:
   ```
   wusa.exe ".\$f"
   ```
   "Not applicable to your computer" most likely means the cumulative update from step 1
   is missing.
5. Check: the step 1 command shows `DisplayVersion` `26H2`; `winver` shows 26H2;
   `slmgr /xpr` still activated; no "requirements not met" watermark or notice; run
   Windows Update again.
6. Record it on the laptop:
   ```
   scripts/laptop/set-os-installed.sh "Windows 11 26H2" --force --labels <label>
   scripts/laptop/combine-summary.sh
   ```

## Before reusing this in 2027

- Re-check the KB page: the prerequisite update and the download link may have changed.
- Check whether 27H2 has replaced it, and whether 27H2 still comes as an enablement
  package or needs a full reinstall.
- `update-loop.ps1` won't pull it in on its own: it searches `BrowseOnly=0`, and Windows
  offers the enablement package as an optional ("Download & install") update (inferred
  from the KB page's wording, not tested).
