# Live quota versus daily token accounting

## Previous bottleneck

The companion used one forward file cursor for both account quota and daily
token totals. Each sync cycle reads at most 8 MiB for up to 0.4 seconds. With
large session transcripts, a quota near EOF could wait behind hundreds of MiB
of historical content. Successful USB/HTTP delivery could therefore still carry
unknown quota fields. The firmware's independent 15-minute sample-age guard
also correctly rejects genuinely old quota samples.

## Updated reader

- Quotas have a separate backward scan, before forward token accounting. Across
  candidate files, timestamps still select the newest populated rate-limit data.
- Tail work is capped at 1 MiB and approximately 150ms per cycle, using backward
  128KiB windows with 4KiB overlap. The overlap supports ordinary metric records
  crossing a window boundary; incomplete edge lines are ignored. There is no
  unlimited whole-file load or repeated scan from the beginning.
- Per-file tail progress is cached independently; file growth requests a fresh
  tail scan. Unchanged fully indexed files require no new reads. Replacement,
  truncation (including truncation above the forward offset), deletion and
  same-size rewrites invalidate dependent state.
- Tail parsing never increments token totals. The original chronological forward
  accounting remains responsible for cumulative deltas, midnight baselines and
  complete daily sums. While this catch-up is incomplete, totals stay unknown
  rather than publishing a misleading partial sum.
- Forward line splitting now searches delimiters in chunks instead of iterating
  every byte in Swift. Pending lines remain capped at 1 MiB.
- Quotas still expire after 15 minutes and primary reset time. No fabricated
  100% remaining, no account credentials, network quota calls, or conversation
  contents are sent to either display. Session logs are not modified.

## Reference comparison

`S7venYoung/mac-thermalright-ai-monitor`, `AgentUsageCollector.swift`, also
separates account-global quota collection from token counting: it scans recent
file tails (up to 16MiB per file), chooses the latest timestamp, caches the result
and throttles scans to around 20 seconds. This change adopts the independent
quota path but not its reset-to-zero inference. Our existing 5h/7d protocol and
unknown-value semantics are retained. It also retains file-mtime candidate
selection, so an active session begun more than 14 days ago is not excluded.

## Verification and deployment

Ten regression cases cover immediate tail quota under a 64-byte token budget,
append/partial writes during backfill, expiry, truncation, no double-counting,
unchanged zero-byte reads, replacement/deletion, old-file exclusion and midnight.
The test methods ran through a Foundation assertion harness because this host's
Command Line Tools lack XCTest and the SwiftUI macro plugin. The reader module
itself compiled with Swift. Full `swift test` / GUI packaging still need a working
Xcode toolchain. A read-only diagnostic against the live 1GiB+ session collection
returned fresh primary/weekly percentages on its first updated-reader cycle,
even while total accounting remained in catch-up.

The installed app is not replaced or restarted by this source change. Deploy an
updated macOS companion to activate it. Cube firmware and pairing do not change.
