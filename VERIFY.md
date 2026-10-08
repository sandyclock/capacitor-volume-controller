# VERIFY.md — how to verify this plugin on a real device

**Run this on BOTH iOS and Android after any native change — including on a platform your
app does not use.** This package is published; someone else will call it.

## Why a device test is not optional here

The JS contract is upstream's; the native implementations are ours (see `FORK.md`). That is
exactly the shape of project where a defect is invisible to CI: TypeScript compiles, the web
mock passes, and one platform quietly does something else.

That already happened. Adopting upstream's 2.0.x event contract migrated Android and web but
missed iOS, which kept the 1.0.13 keep-alive `watchVolume` — it never resolved the initial
call and never emitted an event. `await watchVolume({})` would hang forever on iOS while
every compile-time check stayed green. **No unit test could have caught it.** The harness
below exists so the next one fails loudly.

## 🔴 Before you start

**Do not run this while a live microphone session is open on iOS.** `watchVolume()` reaches
`setupSession()`, which touches the shared `AVAudioSession` category. Through 1.0.13 that
category was `.playback`, which makes WebKit refuse `getUserMedia` and kills the mic
mid-session. This fork uses `.ambient` and never activates the session, but the harness still
refuses to start unless you pass `noCaptureSessionActive: true`.

The harness restores what it changes: it puts the volume back and calls
`clearVolumeControlStream()` at the end.

---

## Route 1 — from a debug screen (preferred)

```ts
import { VolumeControl, verifyVolumeControl, formatVerifyReport } from 'capacitor-volume-controller';
import { Capacitor } from '@capacitor/core';

const report = await verifyVolumeControl(VolumeControl, {
  noCaptureSessionActive: true,          // required acknowledgement — see above
  platform: Capacitor.getPlatform(),
  buttonPressTimeoutMs: 8000,            // 0 to skip the interactive check
  onProgress: c => console.log(`[verify] ${c.status} ${c.id}`),
});
console.log(formatVerifyReport(report));
```

With `buttonPressTimeoutMs > 0` you must **physically press a volume button** during the
window. Set it to `0` for an unattended run; that check then reports `skip`, not `pass`.

## Route 2 — from an attached inspector, no app change

Capacitor exposes plugins at `window.Capacitor.Plugins`, so the critical subset can be run
without rebuilding anything.

- **iOS:** Safari → Develop → *device* → the app's WebView
- **Android:** Chrome → `chrome://inspect` → inspect the WebView

```js
(async () => {
  const P = Capacitor.Plugins.VolumeControl;
  const t = (p, ms, what) => Promise.race([
    p, new Promise((_, r) => setTimeout(() => r(new Error(`${what} never settled in ${ms}ms`)), ms)),
  ]);
  const out = [];
  const check = async (name, fn) => {
    try { out.push(`PASS ${name}: ${await fn()}`); }
    catch (e) { out.push(`FAIL ${name}: ${e.message}`); }
  };

  await check('get',            async () => JSON.stringify(await t(P.getVolumeLevel(), 3000, 'get')));
  await check('get voice_call', async () => JSON.stringify(await t(P.getVolumeLevel({ type: 'voice_call' }), 3000, 'get')));
  await check('bind stream',    async () => { await t(P.setVolumeControlStream({ type: 'voice_call' }), 3000, 'bind'); return 'ok'; });
  // 🔴 the regression guard — this is what hung on the un-migrated iOS build
  await check('watch resolves', async () => { await t(P.watchVolume({}), 3000, 'watchVolume'); return 'ok'; });
  await check('isWatching',     async () => JSON.stringify(await t(P.isWatching(), 3000, 'isWatching')));
  await check('clearWatch',     async () => { await t(P.clearWatch(), 3000, 'clearWatch'); return 'ok'; });
  await check('clear stream',   async () => { await t(P.clearVolumeControlStream(), 3000, 'clear'); return 'ok'; });

  console.log(out.join('\n'));
})();
```

---

## What each check proves

| id | Proves |
|---|---|
| `get.default` / `get.voiceCall` | reads work and return a ratio in `[0,1]` |
| `get.streamsDiffer` | **Android:** `type` reaches the native layer. Through 1.0.13 the Kotlin ignored it and always read `STREAM_MUSIC`. Equal values are legitimate — re-run with the two streams at *different* device volumes to be conclusive |
| `set.roundTrip` | **Android:** the value the plugin *reported* matches a read-back. **iOS:** report-only — see "platform differences" below. Streams are coarse (`STREAM_VOICE_CALL` is often 5–7 steps against 15 for `MUSIC`), so granted ≠ requested is expected and not a failure |
| `set.rejectsOutOfRange` | input validation still exists |
| `stream.bind` | `setVolumeControlStream` resolves. **Android:** confirm the effect separately with `adb shell dumpsys audio` and by pressing a hardware button |
| `watch.resolves` | 🔴 **the regression guard.** Fails on any half-migrated watch contract |
| `watch.isWatching` / `watch.rejectsDouble` | watch state is tracked and re-entry is refused |
| `event.buttonPressed` | **interactive.** A real press emits `volumeButtonPressed` with a direction |
| `event.levelChanged` | moving the volume emits `volumeLevelChanged`. The check **changes the value** and restores it — re-setting the *current* value cannot work on iOS |
| `event.platformNote` | informational: a programmatic set emits different events per platform |
| `watch.clear` | `clearWatch` resolves *and* actually stops. On 1.0.13 the stop was nested inside `if let id = savedCallID`, so a nil id meant it never stopped and never resolved |
| `stream.clear` | the Activity's volume-key routing is restored |

## 🔴 Platform differences the harness accounts for

These are real contract differences, not bugs. The harness was originally written to
Android's semantics and **would have failed against a correct iOS plugin** — caught in
review. A harness that cries wolf is worse than none: the first false red teaches everyone
to ignore it.

| | Android | iOS |
|---|---|---|
| `setVolumeLevel` write | `setStreamVolume`, **synchronous** | hands the write to `DispatchQueue.main.async` on an `MPVolumeView` slider |
| value it resolves with | the **granted** value (read back from the stream) | the **requested** value — before the write has landed |
| event on a programmatic set | `volumeLevelChanged` only | emitted from `outputVolume` **KVO**, so **nothing fires if the value does not change** — and the shared KVO handler also emits `volumeButtonPressed`, with a direction, though no button was pressed |
| `type` / stream selection | eight streams, honoured | ignored — iOS has one global `outputVolume` |

Consequences when reading a report:

- **`set.roundTrip` asserts a read-back only on Android.** On iOS it reports the observed
  drift for a human to judge. An iOS "value did NOT move" line usually means a hardware step
  boundary, not a broken plugin.
- **`event.levelChanged` moves the volume for real**, then restores it, because re-setting
  the current value emits nothing on iOS.
- **Do not treat `volumeButtonPressed` as "a human pressed a button" on iOS.**

**The unambiguous cross-platform signal is the watch group** — `watch.resolves`,
`watch.isWatching`, `watch.rejectsDouble`, `watch.clear`. Those depend on no platform-specific
write semantics, and `watch.resolves` is the guard against another half-migrated contract.

## Android — confirming the parts JS cannot see

`stream.bind` only proves the call resolved. To prove the binding took effect:

```bash
adb shell dumpsys audio | grep -iE 'mode|stream|volume' | head -40
# then press a hardware volume button and confirm the HUD names the CALL stream, not media
```

⚠️ In an app whose custom kiosk Activity swallows keys this will still fail: if `onKeyDown`
returns `true` for every key and never calls `super.onKeyDown`, no key ever reaches default
handling. That is an app-side fix, not a plugin one.

⚠️ `AudioManager.isVolumeFixed()` devices refuse volume writes outright; `set.roundTrip` will
fail there and that is the device, not the plugin.

## Recording a result

Paste the report into the task register with the device and OS version. A run is only
meaningful against a stated device — `STREAM_VOICE_CALL` step counts and routing differ
across OEMs, and a phone is not a tablet.

## Known gap

There is no standalone Xcode project or `Package.swift` in this repo, so the Swift is only
compiled when a host app builds it. `npm run verify:ios` says so rather than pretending.
Until that is fixed, **the device harness is the only iOS verification there is.**
