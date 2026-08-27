# FORK.md — how this package differs from upstream

`capacitor-volume-controller` is a fork of
[`odion-cloud/capacitor-volume-control`](https://github.com/odion-cloud/capacitor-volume-control),
published under our own npm name and maintained independently.

**The JavaScript contract deliberately tracks upstream 2.0.x. The native implementation
deliberately does not.** This file exists so that divergence is stated rather than
discovered — a fork that stays silent about its own behaviour is a fork that lies.

## Why the fork exists

Our use case is a **voice agent**: a live microphone session with acoustic echo
cancellation. On Android that forces `MODE_IN_COMMUNICATION`, so playback runs on
`STREAM_VOICE_CALL`, not `STREAM_MUSIC`. On iOS it puts WebKit into a voice-processing
session, which is fragile with respect to anything that touches the audio session.

Upstream is built for media playback. Three of its choices are actively wrong for us.

## Divergences

### 1. Android — the key listener is kept

Upstream 2.0.x replaced the WebView `OnKeyListener` with a `ContentObserver` on
`Settings.System`. An observer can **notice** a volume change; it cannot **intercept** a
keypress. Upstream's is also hardcoded to `STREAM_MUSIC`, so it never sees changes on any
other stream.

We keep the key listener. By default it **observes without consuming** (`return false`), so
the system still performs the adjustment and draws its own HUD.

### 2. Android — `setVolumeControlStream` / `clearVolumeControlStream` (new)

No upstream equivalent. An Android `Activity` routes the hardware volume keys to
`STREAM_MUSIC` by default, so an app playing on another stream sees the buttons move a
stream nothing is playing on — reported by users as "the volume buttons do nothing."

These bind and restore that routing. Call `setVolumeControlStream({type: 'voice_call'})`
when a session starts and `clearVolumeControlStream()` when it ends. **Not restoring it
leaves the device's volume keys pointed at the wrong stream for the rest of the Activity's
life** — on a personal phone, that means the user's media keys silently keep controlling
the call stream.

`watchVolume` also accepts `handleKeysDirectly` (default `false`): an **OEM fallback** in
which the plugin consumes the keys and calls `adjustStreamVolume` itself. Leave it off
unless a device is proven to ignore `setVolumeControlStream`. Consuming volume keys takes
them from TalkBack, and if the adjustment fails the buttons become dead rather than merely
misrouted.

⚠️ `suppressVolumeIndicator` only has an effect **together with** `handleKeysDirectly`.
On its own it does not hide the HUD, because the plugin no longer consumes the key — the
system does the adjustment and draws its own indicator. (Through 1.0.13 it *did* consume on
its own, which killed the buttons outright: nothing adjusted the volume at all.)

⚠️ **Bind before you watch.** Events carry the volume of the stream bound by
`setVolumeControlStream()`; before the first bind that is `STREAM_MUSIC`. If you rely on the
`value` field, call `setVolumeControlStream()` first. Note also that the binding lives on the
Activity, so it does **not** survive process death — re-bind from JS at session start.

### 3. iOS — the audio session is not hijacked

Upstream, and `@capacitor-community/volume-buttons` which upstream copied, hardcode
`AVAudioSession.Category.playback` in `setupSession()` and call `setActive(true)`.

`.playback` is **output-only**, and WebKit refuses `getUserMedia` while the session sits in
it. Calling `watchVolume()` during a live microphone session therefore **kills the
microphone**. This plugin only needs to observe `outputVolume`; it has no business owning
the route.

We use `.ambient` and do not call `setActive(true)` — KVO on `outputVolume` does not
require an active session. Upstream 2.0.x went further and added `setActive(true)` to
`getVolumeLevel()`, so that every volume *read* activates the session. Deliberately not
adopted.

⚠️ **Known residual hazard, not yet addressed.** `setupSession()` still calls `setCategory`
at all, and the interruption handler and `applicationDidChangeActive` still call
`setActive(true)`. Both are inherited. Reviewers noted that the strictly safest form is to
call `setCategory` **not at all** and observe whatever session the host app has already
activated. That change is unmade because none of this iOS code is compiled or device-tested
here, and our own product never calls `watchVolume` on iOS. **If you do call it on iOS
during a live microphone session, treat that as untested territory.**

### 4. `@capacitor-community/volume-buttons` is not a dependency

Upstream declares it in `dependencies` (`^1.0.2`) and **never references it from any
Kotlin or Swift file**. It is the MediaSession implementation upstream's documentation
describes and upstream's code does not contain. We do not carry it.

### 5. Metadata

- `@capacitor/core` is a **peer** dependency (`>=5.0.0`), not a hard dependency. A plugin
  must never bundle its own copy of the bridge.
- `kotlin-stdlib` follows the consuming app's `kotlinVersion` when it declares one.
- `repository.url` points at this fork, not upstream.

## What is NOT divergent

`src/index.ts` differs from upstream by exactly one export block — the verification harness
(§6). `src/definitions.ts` and `src/web.ts` are upstream's, plus the additions in §2
(`setVolumeControlStream`, `clearVolumeControlStream`, and the `handleKeysDirectly` watch
option). Anyone writing against upstream's documented
JS API — `getVolumeLevel`, `setVolumeLevel`, `watchVolume`, `clearWatch`, `isWatching`,
`addListener('volumeButtonPressed' | 'volumeLevelChanged')`, `removeAllListeners` — will
find it behaves as documented **on all three platforms**.

> ⚠️ That last clause was untrue in the first cut of this fork and is worth recording,
> because it is exactly the failure this file exists to prevent. iOS was left on the 1.0.13
> keep-alive `watchVolume` — `call.keepAlive = true`, re-resolving the same `PluginCall` per
> press, never resolving the initial call and never calling `notifyListeners` — while the
> TypeScript already promised upstream's `Promise<void>` + events. On iOS
> `await watchVolume({})` would have hung forever and no listener would ever have fired.
> Android and web were migrated; iOS was missed, and this section claimed parity anyway.
> Caught in review before publish. iOS now resolves once and emits events like the others.

## Upstream documentation is unreliable

For anyone considering re-syncing: upstream's `PUBLISH_TO_NPM.md` claims a
"MediaSession + VolumeProvider" Android implementation and `MAINACTIVITY_INTEGRATION.md`
documents a `handleVolumeKeyEvent()` method. **Neither exists in upstream's shipped 2.0.3
source.** Read their code, not their docs.

## Versioning

We publish `2.1.0` against upstream's `2.0.3`: the minor bump signals "upstream's 2.0.x
contract plus our native additions" rather than claiming to mirror a specific upstream
release. Consumers on `^1.0.13` will not resolve `2.x` automatically and need an explicit
bump.

## 6. Verification harness — `verifyVolumeControl()`

`src/verify.ts` exports an on-device harness that exercises every method and event and
returns a structured pass/fail report. `VERIFY.md` has the runbook, including a
copy-pasteable console script that needs no app change.

**Run it on both platforms after any native change, including a platform your app does not
use.** The reason this exists is recorded in §3's warning box: iOS was left on the 1.0.13
keep-alive `watchVolume` while the TypeScript already promised upstream's `Promise<void>`
plus events. Everything compiled; the web mock passed; iOS would have hung forever. The
harness's `watch.resolves` check is the guard against a repeat, and `src/__tests__/verify.test.ts`
proves the harness actually detects that failure by running it against a deliberately hung
fake.

`npm run verify:ios` and `verify:android` **do not compile anything** — there is no
standalone Xcode project or `Package.swift` here, and the Android module builds against the
host app's `rootProject`. Both scripts now say so and exit non-zero rather than failing
obscurely. Compile by building a host app; verify behaviour with the harness.
