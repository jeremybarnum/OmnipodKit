# DASH Advertisement / Alert Signalling — Field Findings

Correction + data addendum to the RE "Omnipod DASH Advertisement (Beacon) Parsing" spec,
from live capture on a real DASH pod (`DD5D6B83…`, address `0x179F0CF1`).

## Test setup
- OmnipodKit driven in a **connect-on-demand / "normally disconnected"** mode: the pod is left
  disconnected and advertising; the phone scans continuously (`scanForPeripherals(withServices:
  nil, options:[allowDuplicates:true])`, foreground) and connects only to run a command.
- Every pod-adjacent advertisement is logged with all raw fields (`[ADV]` / `[BEACON]`).
- A **non-destructive alert** (expiration reminder, ~60 s out via `configureAlerts`) was triggered
  to move the pod into an alerting state, then acknowledged to clear it — no fault, pod reusable.

## Headline correction to the spec
For an **alert**, the pod does **NOT** switch to the non-connectable `CE1F923D-…` 128-bit beacon
described in the spec. It stays **`connectable = 1`** and keeps advertising its **normal 16-bit
service-UUID list**, encoding the alert state in two changing fields:

- the **2nd 16-bit service UUID**, and
- a **4-byte status word inside the manufacturer data**.

The `CE1F923D` beacon is therefore most likely a **fault-only** path (a terminal fault where the
pod goes non-connectable). That was **not** reproduced here (would require sacrificing the pod).

## The normal ↔ alert ↔ cleared diff (measured)

| state | 2nd service UUID | mfg status word |
|---|---|---|
| normal (idle) | `C001` | `00020000` |
| **alert active** (beeping) | `C005` | `000a0008` |
| acknowledged (cleared) | `C001` | `00020000` (reverts) |

Reversible and repeatable. The 2nd UUID and the mfg status word move together.

## Advertisement field layout (observed, DASH)

Service UUIDs (16-bit), example alerting frame:
```
[4024, C005, 000A, 179F, 0CF1, 0859, 1693, 0015, 5E7B]
  │     │     │     └──┬──┘  ...other constant fields...
  │     │     │        └ 179F,0CF1 = pod address 0x179F0CF1
  │     │     └ 000A = constant ("third service")
  │     └ 2nd UUID = STATUS/ALERT carrier: C001 (clear) ↔ C005 (alert)
  └ 4024 = DASH main/advertisement service (scan-filter target today)
```

Manufacturer data (company ID `0x0360`), normal vs alert:
```
normal: 6003 021595a189ee252a4c7886a37c2a 000a 00020000 f10c bc
alert:  6003 021595a189ee252a4c7886a37c2a 000a 000a0008 f10c bc
        └CID └── pod id / serial (const) ──┘ └cst └STATUS┘ └addr└?
```
- `STATUS` = 4-byte word between the constant `000a` and the address tail `f10c`.
- clear `0x00020000` (bit 17) → alert `0x000a0008` (adds bits 3 and 19 on top).
  Consistent with the spec's "alarmCode/alertCode as a bit-field."

## Open items (need more pods / a real fault; not tested here)
1. **Per-alert bit mapping** — only one alert type (expiration reminder) was fired. Which
   bit/UUID-value corresponds to which specific alert/alarm needs several alert types diffed.
2. **Fault / `CE1F923D` path** — untested; the spec's 128-bit non-connectable beacon is presumed
   the fault path. Needs a deliberately faulted (sacrificed) pod.
3. **Background-scan filter UUID** — the alert rides the `4024` advertisement, so today's
   `withServices:[4024]` filter would catch alert changes in the background. The `CE1F923D` fault
   beacon may need a different/additional filter — confirm when the fault path is captured.

## Practical takeaway for OmnipodKit
Connectionless **alert detection is achievable now**: in the scan callback, read the 2nd 16-bit
service UUID and/or the mfg `STATUS` word and raise an alert to the pump manager when it deviates
from the clear baseline (`C001` / `00020000`) — no connection required. Detail/acknowledge still
needs a (slow, ~11–14 s) on-demand connect, but detection itself is instant.

---

# Background wake & heartbeat: delayed connect + State Restoration

Correction to the RE conclusion "BLE gives you alarm-wake but no periodic wake." A **periodic
background wake IS achievable** — not via scanning (the pod's disconnected advert is stable, so iOS
coalesces it), but via the **connect** path.

## Mechanism
Issue `central.connect(peripheral, options: [CBConnectPeripheralOptionStartDelayKey: N])` while
disconnected. iOS holds the request pending for `N` seconds, then completes it (the pod advertises
~0.77 s, so it connects shortly after the delay). With State Preservation & Restoration (restore ID
`com.OmnipodKit`) the pending connect **survives app termination** and **relaunches** the app when
it completes. Loop: on each `didDisconnect`, immediately re-issue the delayed connect, so there is
always a pending connect that survives suspension — the loop self-sustains.

## Verified on real hardware (15 h continuous run, DD5D6B83, StartDelay=300 s)
- **iOS relaunches the terminated app in the background — proven.** Tagged each connect with
  `everFg` (true once the process has ever been foregrounded). Multiple **new PIDs ran with
  `everFg=false` for extended periods** — e.g. one process launched via `willRestoreState` and ran
  the loop **~1h42m / ~13 cycles without ever being foregrounded.** A brand-new process running
  that long unforegrounded can only be iOS launching it (not a manual open — which is what
  `willRestoreState` + a new PID alone would NOT prove).
- **Self-sustaining.** After moving the re-arm into `didDisconnect` (see below), the loop ran ~14 h
  with no stalls across suspend / jetsam / relaunch.
- **Timing is fuzzy, not a clock.** For StartDelay=300 s: floor ~300 s, typical ~350–550 s,
  frequently 600–800 s, occasional spikes to ~1100–1580 s (~26 min) under heavy iOS throttling.
  Good for a "phone-home every several minutes" heartbeat; not for anything time-critical.

## Gotchas learned
- **Re-arm in `didDisconnect`, not via `didDiscover`.** Re-arming through a later scan discovery
  stalled (observed ~1h43m dead zone) whenever iOS suspended the app between cycles — the re-arm
  never ran and no pending connect was left to wake on. Issuing the next delayed connect directly
  in `didDisconnect` leaves a pending connect that survives suspension.
- **`willRestoreState` fires on a manual open too** — it does not, by itself, prove an iOS
  relaunch. Use the `everFg`/foreground signal to distinguish.
- **Force-quit (swipe-away) disables BLE relaunch** by design — not a valid relaunch test.
- Stop the `allowDuplicates` scan before the connect (it starves connection completion); iOS
  reacquires the pod on its own.

## Intended use
Keep this **off by default.** Use the delayed-connect heartbeat only when the hosting app requests
periodic check-ins. Otherwise: stay **disconnected**, run an **alarm-filtered scan** (`[C005]`) for
instant fault wake, and **connect on demand** only to send commands / read status.
