# Official quota, local daily tokens

The sync worker calls the installed Codex executable over app-server stdio.
It reuses Codex-managed authentication. There is no companion login screen,
credential file parsing, token export, model turn, or reset-credit consumption.
Only initialize, initialized, and account/rateLimits/read are sent.

Quota is queried at most once per 60 seconds, with an eight-second deadline and
one-MiB response budget. Each subprocess is reaped after the request. The GUI
thread is not blocked. Supported executable locations include the ChatGPT bundled
Codex CLI, Codex.app, Homebrew, and absolute PATH entries.

The codex bucket is selected explicitly when a multi-bucket response is present.
The 300-minute and 10080-minute windows supply used percentages and reset times.
Unknown, invalid, wrong-window, or expired values are not converted to zero.
The last successful official response can survive a temporary query failure for
up to 15 minutes (and never beyond each window's reset). After that, existing
log-quota fallback rules apply. A missing official window remains unknown rather
than giving old log data a new timestamp. Existing Cube protocol age semantics
are preserved; no firmware update is required for this change.

Today's token total remains the incremental local-session total. Official daily
buckets can lag behind the current day, so yesterday's value is never copied into
today, nor is a missing official daily bucket treated as zero. This is a local
activity total, not a promise of identical account-wide billing statistics.

Official protocol: https://learn.chatgpt.com/docs/app-server

Validation: the actual Swift reader compiled independently and passed an
assertion harness covering mapping, local-token preservation, age, expiry, and
unknown values. A live read using the existing login succeeded. Full SwiftPM GUI
tests/package signing still require the macOS build environment; the standalone
harness is not a replacement for the XCTest suite in CI. Actions are not started
automatically by this change.
