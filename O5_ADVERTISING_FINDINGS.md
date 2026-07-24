# O5 (Omnipod 5) Advertisement / Fault Signalling — Field Findings

Companion to `DASH_BEACON_FINDINGS.md`, for the **O5** pod. From live capture on a real O5 pod
(peripheral `636C6109…`, controllerId `0x002A1C6C`), including a **deliberately induced occlusion
fault** (cannula clamped + repeated large boluses; pod sacrificed).

## Advertisement structure (healthy)

O5 advertises a **single 128-bit service UUID** plus 7 bytes of manufacturer data:

```
svcUUIDs = [ CE1F923D-C539-48EA-7300-0A<controllerId:8hex><status:1byte> ]
mfg      = 60 03 00 <counter> <flags> <faultCode> <alertSet>
```

- **Service UUID** = `o5ServiceAdvertisementUUID(controllerId)` — a fixed prefix + the 32-bit
  `controllerId` (a.k.a. pdmId, = `myId`) + a **1-byte status suffix**.
  - Healthy value observed for 5 days straight: `…0A002A1C6C`**`00`** (suffix `00`).
  - Pre-pairing placeholder: `…0AFFFFFFFE00`.
- **Manufacturer data** (`60 03 00 …`):
  - byte3 `<counter>` — a ~2-minute "time since last connect" counter; increments ~every 2 min,
    **resets to 00 on each connect**. Not a fault signal.
  - byte4 `<flags>` — `0x10` healthy.
  - byte5 `<faultCode>` — `0x00` healthy.
  - byte6 `<alertSet>` — alert bitmask (`0x00` = none), same slot scheme as DASH.

## The occlusion fault (measured)

At the fault, **both** the UUID suffix and the manufacturer data changed, and the change **persisted**:

```
HEALTHY   svcUUIDs=[CE1F923D-…-0A002A1C6C00]  mfg=60 03 00 <cnt> 10 00 00
FAULTED   svcUUIDs=[CE1F923D-…-0A002A1C6C02]  mfg=60 03 00 <cnt> 18 14 00
                                       ↑↑                       ↑↑ ↑↑
```

- **Service UUID suffix `00` → `02`.**
- **mfg byte4 `10` → `18`** (a "faulted" flag), **byte5 `00` → `14`** (`0x14` = occlusion — the same
  fault-code value DASH uses).
- The counter (byte3) kept incrementing/resetting normally.

**Timing evidence (this is the important part — it's a real state change, not a blip):**
- `…6C02` was **never advertised once in the 5 days before the fault**.
- Healthy `…6C00` **stopped** at the fault; **zero** `…6C00` frames appeared afterward.
- `…6C02` **persisted ~10 minutes** across 6 distinct frames (until the pod was deactivated), with
  `faultCode 0x14` stable in every one.

## RE engineer static analysis (TWISDK) — refines the model

- The UUID suffix is a **4-state space: `00, 01, 02, 03`**. TWISDK has literal templates
  `CE1F923D-C539-48EA-7300-0A%@00` through `…%@03`, and a real scan request lists all four.
- The parsed field is named generically **`destinationStatus`**, with **separate** `alarmCode` /
  `alertCode` fields. The connected-status fault taxonomy (occlusion subtypes, etc.) lives in the
  PodSDK status/alarm models, **not** in the advert.
- Conclusion: `02` is a **coarse advertised "pod attention/status" bucket, NOT occlusion-specific**.
  There is no static evidence for a suffix → fault-type mapping. Our `00 = normal, 02 = faulted`
  observation is consistent with this, but the **exact fault type must be resolved from the
  connected status**, not the UUID byte.

## Implications for connectionless (deep-idle) O5 fault detection

Feasible, analogous to the DASH C00A scan: filter the idle scan on the **non-normal suffix(es)**
(`CE1F923D-…-0A<controllerId>02`, built from our known controllerId) so a fault is a genuinely NEW
discovery that wakes a suspended app. The advert change is only a **"go look" wake trigger**; the
actual fault/alert is always read from the connected pod status.

### Open questions (before finalizing the filter)
1. **What are suffixes `01` and `03`?** Unknown (only `00` and `02` observed). Likely other
   attention/alert states.
2. **Is any non-`00` suffix *persistent*?** ← the one that matters. Per the DASH lesson, a
   perpetually-advertised state (like DASH `C005` alert-configured) in the filter makes iOS
   *coalesce* the fault re-discovery → slow wakes. Our pod stayed at `00` for 5 days even with
   reminders configured (encouraging — suggests O5 holds `00` until an actual event), but this is
   **not yet confirmed**. Capturing an O5 **alert** (fire an expiration-reminder / low-reservoir
   alert on a normal pod) would show which suffix it uses and whether it sticks.

## Safety (does the scan risk another user's pod?)

- **Filter is not pod-unique.** The O5 `controllerId` is drawn from `O5CertificateStore`
  (`O5RegistrationData.allValues.randomElement()`); **compiled certs are shared across an app
  build**, so controllerIds can collide across users (the source explicitly notes the value "can't
  be … semi-unique across for all users"). So a nearby stranger's faulted pod *can* match our
  filter and wake us.
- **But it cannot false-alarm or cross-command.** A wake triggers a connect to **our own** pod (by
  its unique `bleIdentifier`) + a status read; the alarm is issued only if **our** pod is faulted.
  Commands are encrypted/signed with our pod's session keys (LTK), which a foreign pod lacks.
- **Mitigation for the residual spurious-wake cost:** gate the fault handler on
  `autoConnectIDs.contains(peripheral.identifier)` (own-pod BLE identity) so foreign adverts are
  dropped without a connect. (The current DASH path doesn't do this and should get the same guard.)

## Status
The O5 connectionless fault scan is **not yet implemented** — this is the research backing it. O5
currently relies on the StartDelay heartbeat + connect-on-demand to catch a fault on the next status
read (same as DASH before its C00A scan).
