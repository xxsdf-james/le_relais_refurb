# Methodology — Le Relais PC Refurbishment

*Living document. Not yet evergreen — reflects current understanding and will change as the process is refined.*

*Merged 2026-09-28 from the two methodology drafts exported from the claude.ai Project
(`methodology.md`, `refurb-diagnostics-methodology.md`). Section numbers 1–9 are unchanged
from the pre-merge `methodology.md` — `diagnostics.sh`, `erase-partition.sh`,
`known-issues.md`, `toolkit-reference.md`, and `open-questions.md` all reference several of
them by number, so this merge only ever appends new subsections, never renumbers an
existing one.*

## 1. Purpose and end goal

Fondation Le Relais retired 100+ machines during its migration to Windows 11 because these machines are no longer officially supported for it. They are functional hardware, not waste. The goal is to refurbish them — wipe, verify, install both Windows 11 and Linux Mint where the hardware allows (falling back to a single OS otherwise) — and pass them on to participants in Le Relais's various programs, at low or no cost.

Because the recipients are individuals, not the foundation itself, and because Windows 11 on unsupported hardware carries real security/update implications, the refurbishment record needs to answer three questions for each machine:
1. Is the hardware actually in working order?
2. Was the previous occupant's data verifiably destroyed?
3. Was the new OS (and required software) installed and verified correctly?

### 1.1 Why this shape (ITAD framing)

These three questions are standard **IT Asset Disposition (ITAD)** practice, scaled down to something a one-person operation can run with a USB stick instead of enterprise software (Blancco, Certus, and similar tools implement the same three-part shape — test → sanitize → test → record — for organizations that can afford dedicated ITAD software). The difference here is doing it manually and locally, not that the underlying reasoning is different.

### 1.2 Why before/after diagnostics matter

**Before:** a used/refurbished machine's condition becomes your responsibility from the moment you take possession. If a drive was already failing (high SMART reallocated-sector count, high percentage-used on an SSD) before you started, you need a record proving that — otherwise any failure after redeployment looks like something the refurbishment caused. This is the same reason car mechanics photograph a vehicle before a repair: an "as received" baseline protects both the technician and whoever receives the machine next. What this rationale calls for capturing (not all of which is necessarily implemented in the current scripts — see the per-machine record note in §3.1): NVMe/SMART data (drive wear, error counts, power-on hours — the single most predictive indicator of imminent drive failure), RAM module presence/speed, CPU/hardware identification, and UEFI boot entries/Secure Boot state.

**After:** confirms the sanitization actually worked at the hardware level, and establishes the redeployment baseline the next owner receives the machine in. **The diff between before and after is the actual deliverable, not either report alone** — it's what tells you whether the refurbishment process itself was clean (no new wear/errors introduced) versus whether the machine was already degrading before you touched it.

## 2. Legal basis for the sanitization requirement

Switzerland's revised Federal Act on Data Protection (FADP / nLPD), in force since September 1, 2023, applies to personal data of identifiable natural persons and requires controllers to implement **"adequate technical and organizational security measures"** to protect data throughout its lifecycle, including its destruction. The FADP does not itself prescribe a specific technical wipe standard — it's principle-based ("adequate measures"), not method-prescriptive.

This matters practically: these machines likely held personal data belonging to Le Relais staff or program participants. Because the FADP doesn't specify *how* to sanitize, but does require the result to be defensible as "adequate," the sanitization method used here is chosen to align with **NIST SP 800-88 Rev. 2**, the internationally recognized reference standard for media sanitization (see §4) — this is the standard most commonly pointed to internationally as evidence of "adequate" technical measures, even though Switzerland does not mandate it by name, and it's the same standard most SME data-protection policies point back to, directly or indirectly, well beyond US federal contexts.

**Note (2026-09-28):** this document originally cited **Rev. 1** (Dec 2014). Rev. 1 was withdrawn 2025-09-26 and superseded in its entirety by **Rev. 2** (Sept 2025) — confirmed directly against NIST's own withdrawal notice on the Rev. 1 PDF. This isn't just a version bump: Rev. 2 deliberately removed the per-command Clear/Purge mapping table Rev. 1 had (Rev. 2's own change log: "all sanitization technique and tool details have been replaced with recommendations to comply with IEEE 2883, NSA specifications, or an organizationally approved standard"). IEEE 2883 is a paid ANSI/IEEE standard, not freely accessible to this project. Where §4 below cites a specific command as "Purge-equivalent," that's now this project's own reasoned judgment measured against Rev. 2's principle-based definition, not a citation to a NIST-published command table — see §4.3 for the fullest example of this distinction.

NIST 800-88 defines three sanitization tiers, referenced throughout this document:
- **Clear** — basic overwrite. Recoverable via laboratory techniques. Not sufficient for a machine leaving custody, except as a documented, justified exception (§4.1).
- **Purge** — renders data infeasible to recover even with advanced laboratory techniques. This is the bar for redeployment/resale.
- **Destroy** — physical destruction. Only for drives being scrapped, not reused — out of scope for this project's redeployment goal.

**Practical implication:** the diagnostic report for each machine should record *which* sanitization method was used and confirm it completed successfully — this record is what would demonstrate "adequate measures were taken" if ever questioned, not the deletion itself in isolation. Where the method actually used deviates from the standard's preferred tier for that media type (see §4's Clear-tier exception), the deviation itself needs to be recorded and justified, not silently folded into the same reporting as a full Purge-tier result — an undocumented deviation is far harder to defend than a documented one if the method is ever questioned.

## 3. Machine identification and tracking

Each machine currently carries a number assigned by CIAD, the third-party hardware provider that previously handled Le Relais's asset tracking. That system is being phased out; a new internal system does not yet exist (see §9, open items).

For now, each report records exactly two identifiers:
- **Serial number** — the source of truth. Pulled directly from hardware (`dmidecode -t system`), not transcribed from a label.
- **CIAD number** — entered manually, to preserve traceability back to the prior tracking system for any machine where that history still matters.

No other ID field is added until Le Relais defines its new internal numbering system.

`summary.csv` (written by `diagnostics.sh` and `erase-partition.sh`) is the working record for this project — every diagnostic and erasure stage appends a row, keyed on these two identifiers plus the drive's own serial (see `toolkit-reference.md`). A separate, personally maintained `hardware-inventory.csv` is not part of this project's active toolkit; it's updated by hand outside this workflow and isn't something these scripts write to or assume the schema of.

### 3.1 Minimum per-machine record

Even without dedicated ITAD software, a usable per-machine record — the kind that could go to an accountant for depreciation tracking, or to a recipient as a condition disclosure — should have:

| Field | Source |
|---|---|
| Asset ID/label | Assigned at intake |
| Date processed | System clock at script run |
| Make/Model/Serial | `dmidecode -t system` |
| CPU | `lscpu` |
| RAM (size, speed, health) | `dmidecode -t memory` |
| Storage model + capacity | `nvme list` / `lsblk` |
| Storage health (before) | `smartctl` / `nvme smart-log`, pre-wipe |
| Sanitization method + tier + date | Command used (`--ses=1/2`, or the Clear-tier fallback — see §4.1), timestamp |
| Storage health (after) | Same commands, post-wipe |
| OS installed | Manual note (Windows/Mint + version) |
| Technician | Manual note |
| Disposition | Redeployed / resold / destroyed |

**Current gap, not yet resolved:** `summary.csv`'s schema (`machine_serial,ciad_number,ram_gb,storage_type,storage_capacity_gb,drive_serial,smart_status,erase_method,erase_result,os_installed,status,date`) covers the technical rows above but has no `technician` or `disposition` column — this table describes the target shape, not the current implementation. Worth a column addition or an explicit decision to keep those two out-of-band; not decided here (see §9).

## 4. Data sanitization, by drive type

The correct sanitization method depends on the physical storage technology, because the failure mode of "just overwrite it" differs between them:

- **NVMe SSD**: overwriting is *not* reliable sanitization, because wear-leveling means the controller may write new data to different physical cells than the ones holding the original data — remnants can persist and be recoverable via direct flash access (see §4.2 for the full mechanism). The correct method is the drive's own sanitize command:
  - `nvme format --ses=2` (cryptographic erase) where the drive supports encryption-at-rest — instant, and NIST 800-88 "Purge"-equivalent.
  - `nvme format --ses=1` (user-data erase) as fallback where crypto erase isn't supported.
- **SATA SSD (non-NVMe)**: same wear-leveling problem as NVMe (§4.2) — overwrite is Clear-tier at best here too. The drive's own `hdparm` secure-erase command family is used instead: `--security-erase-enhanced` where the drive reports support for it, falling back to plain `--security-erase` otherwise. Confirmed working end-to-end on real hardware 2026-09-28 (002). **Not classified as NIST-certified Purge** the way NVMe crypto erase above is — see §4.3 for why, and for the reasoning behind preferring Enhanced.
- **Rotating disk (HDD)**: cryptographic erase doesn't apply (no controller-level encryption to discard a key for). A full-disk overwrite is the correct method here — this is the one case where a ShredOS/`nwipe`-style pass is actually the right tool, not a legacy one.

The diagnostics script needs to detect which drive type is present per machine and select the corresponding method automatically — this branching logic is implemented in `erase-partition.sh` (drive-type detection was already in place; the NVMe method-selection logic below was added in v3).

**Verification, not just execution:** the closing diagnostic should confirm the wipe completed and, where possible, that the drive reports a clean/sanitized state (e.g., SMART data showing no leftover partition/filesystem signatures) — the report should reflect a *confirmed* result, not just "the command was run."

### 4.1 Accepted exception: Clear-tier fallback for NVMe drives with no Purge-tier path (decided 2026-09-22)

Some NVMe drives report Format NVM and crypto-erase support in `nvme id-ctrl` (`oacs`/`fna`) that their firmware does not actually implement — the controller rejects the command at the opcode level (`Invalid Command Opcode`) regardless of which `--ses` value is requested, and `sanicap=0` confirms the device-level Sanitize command (the only other Purge-tier path) is unavailable too. This was confirmed on a Samsung MZVLW256HEHP-000L7 (machine 001/CIAD7562) through a full diagnosis trail ruling out mount locks, SES-specific rejection, nvme-cli bugs, and TCG Opal/BitLocker-eDrive locking — see `known-issues.md` for the complete trail.

**Decision:** for a drive confirmed to fail this way, `erase-partition.sh` falls back automatically to a **Clear-tier** (NIST 800-88) zero-fill overwrite via `nwipe`, rather than pulling the machine from the participant-redeployment pool. This is a one-person operation processing ~100 machines; a per-machine manual unlock or routing step doesn't scale, and the affected drives are not known to be salvageable to Purge-tier by any means available in this workflow.

**This is a deliberate, documented deviation, not a silent substitution.** Every report and `summary.csv` row produced by this fallback records the method as `"nwipe overwrite (Clear-tier fallback — Format NVM confirmed unsupported despite oacs/fna claiming support; see known-issues.md)"` — a string kept distinct from both the normal Purge-tier NVMe methods and the plain HDD `nwipe` label, specifically so a later audit of the records can tell which machines received which tier without re-deriving it from raw logs.

**Residual-risk statement (for the record, per §2's requirement that a deviation be justified, not just logged):** a zero-fill overwrite writes through the drive's Flash Translation Layer, not directly to the physical NAND cells that held the original data — wear-leveling means the "zero" write lands on a different physical page, and the original page is marked stale but not erased until garbage collection later reclaims it. Additionally, 7–28% of a typical SSD's physical capacity is reserved as controller-managed over-provisioning space that is never addressable by any host-level command (overwrite, TRIM, or otherwise) — if wear-leveling ever relocated original data into that reserved pool over the drive's life, no overwrite pass can reach it. Recovery of this residual data is not possible through normal means; it requires chip-off forensics (physically desoldering the NAND and reading it with specialized equipment) — which is precisely why NIST 800-88 classifies overwrite as Clear-tier (recoverable via laboratory techniques) rather than Purge-tier (infeasible even with them) for flash media. See §4.2 below for the full mechanism and sourcing.

Given the realistic threat model for this batch (refurbished machines going to low-budget program participants, not a targeted forensic adversary), this residual risk is judged acceptable relative to the alternative of pulling functioning hardware from the redeployment pool — but the report for each affected machine should make clear which tier of sanitization it actually received, not just that "sanitization succeeded."

### 4.2 Why overwrite falls short on flash — the mechanism, in detail

This matters beyond the general "wear-leveling" statement above (§4, §4.1), because it's the basis for the Clear-tier fallback decision and it's worth understanding precisely what is and isn't reachable, rather than treating "wear-leveling" as a black box.

**NAND cannot be overwritten in place.** Flash memory can only be erased at the block level (hundreds of KB to a few MB per block) and written at the page level, and only into an already-erased page. When an overwrite command targets logical block address (LBA) X, the Flash Translation Layer (FTL) doesn't zero the physical cells currently holding LBA X's old data — it writes the new pattern to a *different*, pre-erased physical page and updates the logical-to-physical mapping table to point there instead. The old physical page is marked stale. It is not erased by this operation; the original data remains present as stored charge until garbage collection later reclaims that block.

**Three places old data can outlive a completed overwrite pass:**
1. **Stale pages awaiting garbage collection.** GC runs opportunistically, not synchronously with the write. A host-level read-back immediately after the overwrite (the verification method this workflow uses) reads through the *current* mapping and correctly returns zero — but never touches the retired physical page, which may not be reclaimed yet, especially if the machine is powered off shortly after (exactly this workflow's sequence: wipe, then partition, then move to OS install).
2. **Over-provisioned/spare area.** SSD controllers reserve **7–28% of physical capacity** beyond the advertised logical size for wear-leveling headroom, bad-block replacement, and GC working space ([Security and Forensics – Is Solid State Drive a Friend or a Foe?, MEMSYS 2025](https://www.usna.edu/Users/cs/srinivas/research_pubs/Memsys-2025.pdf)). No LBA maps to this space — it is architecturally unreachable by any host-level command, overwrite included. If wear-leveling ever relocated a page holding old data into this pool during the drive's operational life, no overwrite pass can reach it, ever.
3. **Retired bad blocks.** Blocks that failed during the drive's life are swapped out for spares from the same reserved pool; any data they held before failing is permanently outside the addressable LBA space.

**What recovering this actually requires:** chip-off forensics — physically desoldering the NAND packages and reading them raw with a flash programmer, then reconstructing the vendor-proprietary FTL mapping well enough to interpret the dump. This is a real, documented forensic technique, not a theoretical concern, but it requires specialized equipment and expertise well beyond what a casual finder of a discarded machine would have. This is the exact distinction NIST 800-88 draws between Clear (recoverable via laboratory techniques) and Purge (infeasible even with them) — an overwrite pass is a real, meaningful, standards-recognized Clear-tier result; it is a categorically different and weaker claim than Purge, and the two should never be described interchangeably in a report.

**Note on TRIM/Deallocate as an alternative:** the ATA TRIM / NVMe Dataset Management–Deallocate command is sometimes suggested as a lighter-weight alternative to a full overwrite. It's not used here, because it's advisory rather than a data-destruction command — it tells the controller a region no longer holds valid data and may be reclaimed whenever convenient, with no guaranteed timing and no deterministic read-after-write semantics (a read of a deallocated region can return zeros, stale data, or garbage, depending on the drive's optional DRAT/DZAT support). That non-determinism makes it fundamentally unverifiable in a way overwrite isn't: this workflow's `readback-sample` verification step depends on the write command having defined semantics, which TRIM does not provide.

### 4.3 SATA SSD secure erase — tier classification (documented judgment call, not NIST-certified)

`erase-partition.sh`'s SATA-SSD branch uses the ATA `SECURITY ERASE UNIT` command family via `hdparm`, preferring `--security-erase-enhanced` where the drive reports support for it (`hdparm -I`'s security section), falling back to plain `--security-erase` otherwise. Confirmed working end-to-end on real hardware for the first time 2026-09-28 (002/SATA SSD): sanitization exit=0, `readback-sample` verification passed, partition table zapped clean.

**Why this isn't cited as "NIST 800-88 Purge" the way §4's NVMe `--ses=2` crypto erase is:** see §2's note on Rev. 1's withdrawal. Rev. 2 removed the per-command Clear/Purge table Rev. 1 had and now defers technology-specific technique selection to IEEE 2883 (a paid standard, not accessible here). What Rev. 2 gives instead is principle-based: Purge is a technique that "makes recovery of target data infeasible using state-of-the-art laboratory techniques," achievable via "dedicated, standardized device sanitize commands that ... bypass the abstraction inherent in typical read and write commands" (Rev. 2 §3.1.2). ATA Secure Erase — enhanced or plain — fits that description structurally: it's a firmware-level command, not a host-issued overwrite through the normal read/write interface. But Rev. 2's Appendix B is explicit this can't be taken on faith: "no assumptions should be made as to the functionality of these commands ... It may be difficult or impossible for users to know for sure how the sanitization action is being implemented" — the exact failure mode already caught once in this project (§4.1: an NVMe drive whose `oacs`/`fna` claimed Format NVM + crypto-erase support its firmware then rejected at the opcode level).

**Decision (2026-09-28, documented exception, same treatment as §4.1's NVMe fallback — not silently assumed):** `--security-erase-enhanced` is preferred over plain `--security-erase` whenever the drive reports support for it, because it's a strict superset by ATA spec (Enhanced additionally covers reallocated/spare sectors that plain Secure Erase doesn't guarantee) at no observed cost — both variants completed in roughly the same ~30-second window on the confirmed drive, consistent with SSD firmware typically implementing both via the same internal mechanism (key discard / full block erase) rather than a literal sector-by-sector overwrite. This is the strongest claim available without a paid IEEE 2883 subscription or per-model vendor documentation. Report this as "ATA Secure Erase (Enhanced, where supported)," not as an unqualified "Purge-tier, NIST-certified" result, in any recipient-facing disclosure.

**Frozen-state fix, confirmed 2026-09-28 (002):** suspend the machine to RAM (S3) and resume, not the plain power-off/power-on cycle `erase-partition.sh` used to suggest. Most BIOSes issue `SECURITY FREEZE LOCK` on every POST; suspend/resume forces a SATA link reset (COMRESET) via the kernel without going through POST, so the freeze-lock command is never reissued. A normal power cycle goes through POST again and typically refreezes the drive — it isn't a reliable fix by itself.

## 5. Hardware suitability triage (dual-boot vs. fallback)

Not every machine will have the RAM/storage/firmware to comfortably run a Windows 11 + Mint dual-boot. Three possible outcomes per machine:
1. **Dual-boot**: Windows 11 + Linux Mint, both installed.
2. **Windows 11 only**.
3. **Mint only**.

The opening diagnostic needs to evaluate hardware condition and recommend one of these three outcomes before installation begins. **The specific thresholds (minimum RAM, storage size, UEFI requirement, etc.) that decide between these three outcomes are not yet defined — this is an explicit open item (§9), not a gap in this document.** Once defined, this section should be updated with the actual decision criteria.

## 6. Software manifest

- **Windows 11**: Firefox, Thunderbird, VLC, LibreOffice — installed fresh, since Windows doesn't ship any of them. Installation is followed by driver verification (confirm no unrecognized/missing devices in Device Manager, matching the machine's actual hardware) and a general installation verification pass.
- **Linux Mint**: believed to ship with Firefox, Thunderbird, VLC, and LibreOffice pre-installed — to be confirmed. If confirmed, Mint's software step is a version/update check rather than an installation step; if any are missing or outdated, install/update as needed.

## 7. Workflow (maps to the working outline)

```
Ubuntu Live
  → Opening diagnostics (hardware condition, drive type, dual-boot suitability)
  → Disk wipe (method selected per §4, based on detected drive type)
  → Partitioning (per outcome from §5)

Windows 11 install (Rufus USB)
  → Windows Update
  → Install Firefox, Thunderbird, VLC, LibreOffice
  → Driver verification
  → Installation verification (including confirming activation succeeded)

Linux Mint install (Rufus USB) — where applicable per §5
  → Updates
  → Verify Firefox/Thunderbird/VLC/LibreOffice presence and version (§6)

Ubuntu Live
  → Closing diagnostics: hardware still healthy, wipe verified (§4),
    both OS installs verified, bootloader verified (GRUB shows and
    boots both entries where dual-boot applies)
```

**Note (2026-09-28):** the original version of this diagram named the Toolbox USB as where opening/closing diagnostic results were saved. The Toolbox USB has been dropped (see CLAUDE.md, Out of scope) and where results go instead for the *routine*, all-~100-machines case is still an open item (§9) — `docs/ssh-access.md` is a confirmed-working answer for ad hoc/troubleshooting transfer, not yet a decided replacement for this diagram's result-recording step.

The before/after diagnostics being the same script, run at both ends, remains the reason this comparison is trustworthy — that principle still applies with the added drive-type and dual-boot-triage logic layered in.

### 7.1 Why boot media and results/evidence are kept separate

This maps to a basic **chain-of-custody principle**: the tool used to *perform* an action (the bootable OS) should be kept separate from the tool/mechanism used to *record evidence of* that action (currently: whatever the results-destination open item above resolves to). Mixing the two — as the first version of this workflow tried to do — creates exactly the kind of ambiguity (was the drive locked? was data overwritten by the boot process itself?) that a clean audit trail is supposed to prevent. This principle is independent of the specific mechanism (Toolbox USB, SSH, or otherwise) — whatever replaces the Toolbox USB for routine use should preserve this separation, not just replace it with a single mixed-purpose tool.

## 8. Recipient-facing information

No disclosure document is being authored as part of this methodology — that's explicitly out of scope here. What *is* in scope: making sure the information a disclosure would need is captured and readily available in each machine's report, specifically:
- Confirmation the machine is running Windows 11 without official manufacturer/Microsoft support for that hardware.
- Which OS(es) were installed.
- Date of refurbishment.

Whoever produces the actual recipient-facing disclosure later can pull directly from the report rather than re-deriving this information.

## 9. Open items / TODO

- **Dual-boot decision thresholds** (§5) — not yet defined.
- **New internal asset-labeling system** — Le Relais needs to define this now that CIAD's system is being phased out (§3).
- **Mint software manifest confirmation** — verify which of Firefox/Thunderbird/VLC/LibreOffice actually ship by default on the specific Mint edition chosen, and confirm which Mint edition/version is being standardized on.
- **SATA SSD fallback-if-genuinely-unsupported question** — §4.1's Clear-tier `nwipe` fallback covers NVMe drives only. Whether a SATA SSD reporting `hdparm` secure-erase as genuinely unsupported (not just frozen — §4.3 documents the confirmed frozen-state fix, suspend-to-RAM) should get the same automatic fallback, or needs its own separate confirmation pass first, is still not decided — `erase-partition.sh`'s SATA SSD branch has no fallback path for that case yet. (The tier-classification question for the *working* path is now addressed — §4.3.)
- **Windows activation tracking** — `summary.csv` has no column for `windows_activation_verified`; `diagnostics.sh`'s "after" reminder currently just tells the technician to note it separately (no longer pointing at `hardware-inventory.csv`, per the decision below). Not yet decided whether this needs its own `summary.csv` column or stays out-of-band.
- **`technician`/`disposition` columns** (§3.1) — the minimum per-machine record calls for both; `summary.csv`'s current schema has neither. Not yet decided whether to add columns or keep these out-of-band.
- **§7's workflow diagram still needs updating** once the routine (not just ad hoc) diagnostic-results destination is decided — see CLAUDE.md Open items and `docs/ssh-access.md`.

**Resolved (2026-09-22):** `hardware-inventory.csv` is no longer part of this project's active toolkit — `summary.csv` (written by `diagnostics.sh`/`erase-partition.sh`) is the working record for the refurbishment workflow going forward. A separately maintained `hardware-inventory.csv` is updated by hand, outside this workflow, and these scripts don't write to it or assume its schema. This resolves the earlier open item about adding a `sanitization_tier` column to that file — moot, since the Clear-tier fallback (§4.1) is already recorded distinctly in `summary.csv`'s `erase_method` field.
