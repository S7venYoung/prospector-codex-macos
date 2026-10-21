# Cube absolute reset clock time

Official quota snapshots now retain primaryResetAt from primary.resetsAt.
Today's local token total is unchanged. CODEX3 supplies the reset epoch and
Mac timezone offset at the reset instant, so Cube can show a drawn hourglass
and HH:MM, without a countdown, text prefix or dependency on its own clock sync.

The default CubeProtocol.frame remains CODEX2 for existing callers/devices.
USB first identifies CAPS/2, then probes CAPS3 once per opened port (one second
maximum for unsupported legacy firmware). Wi-Fi attempts CODEX3 then falls back
to CODEX2 only for HTTP 400. Auth/network failures are not masked. No credential
is sent in the new frame; existing pairing-token handling remains unchanged.

Only the Cube dongle firmware branch implements the new display. Old scanner
firmware and previously published packages remain compatible via fallback.
Both updated companion and updated dongle app are needed to see reset time.
Unknown/expired official reset remains unknown, never copied from yesterday
or inferred from quota percentage. Full GUI build/hardware testing is pending.
