# Scanner unknown metrics fix

Update the macOS app and the **ZMK Prospector scanner** firmware together.
This is not an ESP32 Cube firmware update.

Scanner handshake: `PING` → `PROSPECTOR-SCANNER/2`.
The app sends `CODEX2 <5-hour remaining> <today tokens> <7-day remaining>` followed by a newline.
Each field may independently be `-1` (unknown). The scanner acknowledges `OK`
and renders unavailable fields as `--` while updating all known fields.
Zero remains a real value; it is never used as a substitute for missing data.

This scanner command is deliberately separate from the Cube CODEX2 protocol
(which has a different field order and includes freshness/lease fields).

Legacy `CODEX <remaining> <tokens> [weekly remaining]` frames remain accepted.
The new app also recognizes v1 scanners and uses the legacy frame when its
required values are known. Unknown values require upgrading that scanner;
they must not be replaced with fabricated quota or token totals.

The 15-minute quota freshness rule is unchanged. This fix keeps synchronization
working with unavailable quota; it does not manufacture fresh account data.

Validation:

```sh
cd prospector-codex-macos
swift test
```

Firmware parser regression test (from workspace root):

```sh
cc -std=c11 -Wall -Wextra -Werror prospector-zmk-module/tests/scanner_host_protocol_test.c -o /tmp/scanner_host_protocol_test
/tmp/scanner_host_protocol_test
```
