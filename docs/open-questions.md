# Open Questions — Le Relais PC Refurbishment

*Unresolved items only. Once something here is decided, move the decision into the relevant document (methodology.md, toolkit-reference.md, etc.) and delete it from this file — don't let resolved items linger here.*

## Hardware triage thresholds
- Exact RAM/storage/UEFI thresholds that decide dual-boot vs. Windows-only vs. Mint-only are not yet defined (methodology.md §5).
- Criteria for falling back from Mint Cinnamon to Mint Xfce are not yet defined — likely related to the same thresholds above, but not confirmed.

## Asset labeling
- Le Relais's asset numbers were previously managed by CIAD (third-party hardware provider); that system is being phased out. A new internal labeling system doesn't exist yet — undefined who owns this decision or on what timeline.

## Recipient disclosure
- No disclosure document is being authored as part of this project, but the mechanism by which the "unsupported Windows 11 hardware" caveat actually reaches recipients (a printed slip, a verbal notice, something else) hasn't been decided by whoever does own that step.

## Failed/rejected machines
- Confirmed: a failed machine still gets a row in `summary.csv` (erase_exit_status/verify_result reflecting the failure) rather than being omitted — `erase-partition.sh` writes the row unconditionally, not just on success. Not yet decided: what happens to a rejected machine physically afterward (recycling process, e-waste handling) — likely outside this project's scope, but worth confirming it's someone else's defined responsibility rather than silently unowned.

## SATA SSD sanitization fallback
- `methodology.md` §4.1's Clear-tier fallback (for NVMe drives confirmed to have no Purge-tier path) currently covers NVMe only. Whether a SATA SSD reporting `hdparm` secure-erase as unsupported, or FROZEN with no resolution, should get the same automatic fallback — or needs its own separate confirmation pass first — is undecided.

## Printers and monitors
- Explicitly deferred — no procedure exists yet, and none of the current documents address them. Revisit once the PC batch is underway.
