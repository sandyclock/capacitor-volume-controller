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

### 2a. `getAudioEnvironment()` (new, 2.2.0)

No upstream equivalent. Read-only facts an app needs to choose how to play voice audio and which
stream to control: echo canceller reported, build type, the current audio mode, and stream step
counts. Measured on five Android boards: a WebView that opens the microphone with echo cancellation
switches to `in_communication` on devices with a working canceller, and its playback then runs on
`STREAM_VOICE_CALL`; elsewhere it stays `normal` on `STREAM_MUSIC`. `echoCancellerAvailable` is a
hint, not proof — some devices cancel echo inside the audio driver and report `false`.

### 3. iOS — we track upstream's audio session handling (this section was WRONG)

🔴 **An earlier revision of this file claimed we diverged from upstream here. That claim was
based on two unmeasured assumptions, both of which were later falsified on real hardware
(an iPhone, iOS 26). The divergence has been REMOVED. Do not reintroduce it.**

**Falsified claim 1 — "`.playback` is output-only, so WebKit refuses `getUserMedia` and
`watchVolume()` kills the microphone."** Measured false. Built with
`sessionCategory = .playback`, `getUserMedia` **acquired** the mic and it stayed
`readyState=live muted=false` for the life of the test. We now use `.playback`, matching
upstream. If anyone changes this back to `.ambient`, justify it by **silent-switch
semantics** — `.ambient` obeys the mute switch, `.playback` plays through it, which is a
real product question for a kiosk — and **never** by the microphone.

**Falsified claim 2 — "KVO on `outputVolume` does not require an active session, so we can
skip `setActive(true)`."** Measured false, and it silently broke the feature. On an
**inactive** session the observer does not fire **at all** — not filtered, never fired. The
plugin only appeared to work after an accidental background→foreground cycle, which
activates the session via `applicationDidChangeActive`. `setActive(true)` has been restored
in `setupSession()` and is load-bearing. Removing it "to protect the mic" is backwards:
activation never threatened the mic.

We still do **not** copy upstream's `setActive(true)` inside `getVolumeLevel()`, on the
narrower ground that a plain read should not mutate global session state.

🔴 **Real, structural iOS limitation — this one IS measured.** While a capture route is live
(the agent listening), `outputVolume` KVO **stops firing entirely** and `getVolumeLevel()`
can return **stale** values. This is **not** a fork bug — upstream behaves identically. It
follows that on iOS **hardware volume buttons cannot be observed by this plugin during an
agent session**, and any design that assumes otherwise is invalid. An app that needs volume
control during a live session must do it in its own audio graph (e.g. a gain node); the hardware
buttons still change what the user *hears*, the plugin simply cannot observe or mirror them.

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
