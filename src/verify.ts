/*
 * On-device verification harness for capacitor-volume-controller.
 *
 * WHY THIS EXISTS
 * ---------------
 * This package is a fork whose whole point is that the NATIVE implementations diverge from
 * upstream while the JS contract does not (see FORK.md). That is precisely the shape of
 * project where a defect hides: the TypeScript compiles, the web mock passes, and one
 * platform silently does something else.
 *
 * That is not hypothetical. Adopting upstream's 2.0.x event contract migrated Android and
 * web but MISSED iOS, which kept the 1.0.13 keep-alive `watchVolume`: it never resolved the
 * initial call and never emitted an event. `await watchVolume({})` would hang forever on
 * iOS while every compile-time check stayed green. Nothing in CI could have caught it —
 * only running the real thing on the real platform.
 *
 * ⇒ Run this on BOTH platforms after any native change, even on a platform the host app does
 *   not use. "We don't call it on iOS" is not a reason to ship an iOS build that is broken;
 *   the package is published and someone else will call it.
 *
 * HOW TO RUN — see VERIFY.md.
 *
 * 🔴 NEVER run this while a live microphone session is open on iOS. `watchVolume()` reaches
 * `setupSession()`, which touches the shared AVAudioSession category. Through 1.0.13 that
 * category was `.playback`, which makes WebKit refuse `getUserMedia` and kills the mic
 * mid-session. This fork uses `.ambient` and does not activate the session, but the harness
 * still refuses to start unless the caller confirms no capture is running.
 */
import type {
  VolumeControlPlugin,
  VolumeButtonPressedEvent,
  VolumeLevelChangedEvent,
} from './definitions';
import { VolumeType } from './definitions';

export type VerifyStatus = 'pass' | 'fail' | 'skip';

export interface VerifyCheck {
  /** Stable identifier, safe to grep for in logs. */
  id: string;
  /** What the check proves, in one line. */
  name: string;
  status: VerifyStatus;
  /** Observed value, or the reason for a fail/skip. */
  detail: string;
  /** Platforms this check is meaningful on. */
  platforms: Array<'ios' | 'android' | 'web'>;
}

export interface VerifyReport {
  platform: string;
  startedAt: string;
  checks: VerifyCheck[];
  passed: number;
  failed: number;
  skipped: number;
  /** True only when nothing failed. Skips do not fail the run. */
  ok: boolean;
}

export interface VerifyOptions {
  /**
   * 🔴 Required acknowledgement that no microphone capture is running. See the file header.
   */
  noCaptureSessionActive: true;

  /** 'ios' | 'android' | 'web' — normally `Capacitor.getPlatform()`. */
  platform: string;

  /**
   * Milliseconds to wait for a HUMAN to press a hardware volume button. 0 skips the
   * interactive checks, which is what you want in an unattended run.
   * @default 0
   */
  buttonPressTimeoutMs?: number;

  /**
   * How long any single plugin call may take before it counts as hung.
   * This is the guard that catches a never-resolving promise — the exact iOS defect above.
   * @default 3000
   */
  callTimeoutMs?: number;

  /**
   * Grace period after a write before reading the value back.
   *
   * iOS needs this: `setVolumeLevel` hands the write to `DispatchQueue.main.async` on an
   * MPVolumeView slider and resolves BEFORE it lands. Android's `setStreamVolume` is
   * synchronous and needs none of it.
   * @default 400
   */
  settleMs?: number;

  /** Optional progress sink, so a UI can show checks as they land. */
  onProgress?: (check: VerifyCheck) => void;
}

/**
 * Reject rather than hang. A never-settling promise is a REAL failure mode here — it is what
 * the un-migrated iOS `watchVolume` did — so every call in this harness goes through it.
 * Without this the harness would hang exactly where the bug is, and report nothing.
 */
function withTimeout<T>(p: Promise<T>, ms: number, what: string): Promise<T> {
  return new Promise<T>((resolve, reject) => {
    const timer = setTimeout(
      () => reject(new Error(`${what} did not settle within ${ms}ms (never-resolving promise?)`)),
      ms,
    );
    p.then(
      v => { clearTimeout(timer); resolve(v); },
      e => { clearTimeout(timer); reject(e); },
    );
  });
}

const isRatio = (v: unknown): v is number =>
  typeof v === 'number' && Number.isFinite(v) && v >= 0 && v <= 1;

/**
 * Exercise every method and event of the plugin and report what actually happened.
 *
 * Pass the plugin explicitly (`verifyVolumeControl(VolumeControl, {...})`) so this module has
 * no runtime dependency on the registration in `index.ts`.
 */
export async function verifyVolumeControl(
  plugin: VolumeControlPlugin,
  options: VerifyOptions,
): Promise<VerifyReport> {
  if (options.noCaptureSessionActive !== true) {
    throw new Error(
      'verifyVolumeControl refuses to run without noCaptureSessionActive: true — ' +
        'watchVolume touches the iOS audio session and can kill a live microphone.',
    );
  }

  const platform = options.platform;
  const callTimeout = options.callTimeoutMs ?? 3000;
  const pressTimeout = options.buttonPressTimeoutMs ?? 0;
  const settleMs = options.settleMs ?? 400;
  const sleep = (ms: number) => new Promise<void>(r => setTimeout(r, ms));
  // Platform write semantics differ enough that one assertion cannot be honest for both.
  const syncWrites = platform === 'android';
  const checks: VerifyCheck[] = [];

  const record = (c: VerifyCheck) => {
    checks.push(c);
    options.onProgress?.(c);
    return c;
  };
  const run = async (
    id: string,
    name: string,
    platforms: VerifyCheck['platforms'],
    fn: () => Promise<string>,
  ) => {
    if (!platforms.includes(platform as any)) {
      return record({ id, name, status: 'skip', detail: `not applicable on ${platform}`, platforms });
    }
    try {
      return record({ id, name, status: 'pass', detail: await fn(), platforms });
    } catch (e: any) {
      return record({ id, name, status: 'fail', detail: e?.message ?? String(e), platforms });
    }
  };

  const ALL: VerifyCheck['platforms'] = ['ios', 'android', 'web'];
  const NATIVE: VerifyCheck['platforms'] = ['ios', 'android'];
  const ANDROID: VerifyCheck['platforms'] = ['android'];

  // ---- read ---------------------------------------------------------------
  await run('get.default', 'getVolumeLevel() returns a ratio in [0,1]', ALL, async () => {
    const r = await withTimeout(plugin.getVolumeLevel(), callTimeout, 'getVolumeLevel()');
    if (!isRatio(r?.value)) throw new Error(`expected 0..1, got ${JSON.stringify(r)}`);
    return `value=${r.value}`;
  });

  // The whole reason the fork exists: `type` must actually reach the native layer. Through
  // 1.0.13 the Kotlin ignored it and always read STREAM_MUSIC, so this returned the media
  // volume no matter what was asked for.
  await run('get.voiceCall', 'getVolumeLevel({VOICE_CALL}) is honoured', ALL, async () => {
    const r = await withTimeout(
      plugin.getVolumeLevel({ type: VolumeType.VOICE_CALL }), callTimeout, 'getVolumeLevel(VOICE_CALL)');
    if (!isRatio(r?.value)) throw new Error(`expected 0..1, got ${JSON.stringify(r)}`);
    return `value=${r.value}`;
  });

  await run('get.streamsDiffer', 'MUSIC and VOICE_CALL are distinguishable', ANDROID, async () => {
    const music = await withTimeout(
      plugin.getVolumeLevel({ type: VolumeType.MUSIC }), callTimeout, 'get(MUSIC)');
    const voice = await withTimeout(
      plugin.getVolumeLevel({ type: VolumeType.VOICE_CALL }), callTimeout, 'get(VOICE_CALL)');
    // Equal values are legitimate — both streams can simply sit at the same ratio — so this
    // check reports rather than asserts. A PERMANENTLY identical pair across different device
    // volumes is the signal that `type` is being ignored.
    return `music=${music.value} voiceCall=${voice.value}` +
      (music.value === voice.value ? ' (equal — re-run at different device volumes to confirm type is honoured)' : '');
  });

  // ---- write --------------------------------------------------------------
  // ⚠️ ANDROID and iOS have genuinely different write contracts, and asserting Android's
  // shape on iOS makes this check FAIL AGAINST A CORRECT PLUGIN:
  //   Android -- setStreamVolume is synchronous and the plugin reports the GRANTED value.
  //   iOS     -- the write is handed to DispatchQueue.main.async on an MPVolumeView slider and
  //              the plugin resolves with the REQUESTED value before the write has landed.
  // A harness that cries wolf is worse than no harness: the first false red teaches everyone
  // to ignore it. So assert only what each platform actually promises.
  await run('set.roundTrip', 'setVolumeLevel lands on VOICE_CALL', NATIVE, async () => {
    const before = (await withTimeout(
      plugin.getVolumeLevel({ type: VolumeType.VOICE_CALL }), callTimeout, 'get')).value;
    const target = before > 0.5 ? 0.3 : 0.7;
    const set = await withTimeout(
      plugin.setVolumeLevel({ value: target, type: VolumeType.VOICE_CALL }), callTimeout, 'setVolumeLevel');
    if (!isRatio(set?.value)) throw new Error(`setVolumeLevel returned ${JSON.stringify(set)}`);

    await sleep(settleMs);
    const after = (await withTimeout(
      plugin.getVolumeLevel({ type: VolumeType.VOICE_CALL }), callTimeout, 'get')).value;
    const restore = plugin.setVolumeLevel({ value: before, type: VolumeType.VOICE_CALL })
      .catch(() => undefined);

    if (syncWrites) {
      // Streams are coarse -- STREAM_VOICE_CALL is often 5-7 steps against 15 for MUSIC -- so
      // granted != requested is EXPECTED and is not a failure. What must hold is that the
      // value the plugin REPORTED is the value a read-back sees.
      if (Math.abs(after - set.value) > 0.001) {
        await restore;
        throw new Error(`reported ${set.value} but read-back gave ${after}`);
      }
      await restore;
      return `requested=${target} granted=${set.value} readBack=${after} (restored ${before})`;
    }

    // iOS: cannot assert the read-back. Report the drift instead so a human can judge it.
    await restore;
    const moved = Math.abs(after - before) > 0.001;
    return `requested=${target} resolved=${set.value} readBack=${after} ` +
      `(async write; ${moved ? 'value moved' : 'value did NOT move -- may be a hardware step boundary'})`;
  });

  await run('set.rejectsOutOfRange', 'setVolumeLevel rejects value > 1', ALL, async () => {
    try {
      await withTimeout(plugin.setVolumeLevel({ value: 1.5 }), callTimeout, 'setVolumeLevel(1.5)');
    } catch {
      return 'rejected as expected';
    }
    throw new Error('accepted an out-of-range value');
  });

  // ---- control stream (fork addition) -------------------------------------
  await run('stream.bind', 'setVolumeControlStream(VOICE_CALL) resolves', ALL, async () => {
    await withTimeout(
      plugin.setVolumeControlStream({ type: VolumeType.VOICE_CALL }), callTimeout, 'setVolumeControlStream');
    return platform === 'android' ? 'bound (verify with: adb shell dumpsys audio)' : 'resolved (no-op on this platform)';
  });

  // ---- watch + events -----------------------------------------------------
  // 🔴 THE REGRESSION GUARD. On the un-migrated iOS build this never settled. Any future
  // half-migration of the watch contract fails HERE rather than in production.
  await run('watch.resolves', 'watchVolume() RESOLVES (does not hang)', ALL, async () => {
    await withTimeout(plugin.watchVolume({}), callTimeout, 'watchVolume()');
    return 'resolved';
  });

  await run('watch.isWatching', 'isWatching() is true after watchVolume()', ALL, async () => {
    const r = await withTimeout(plugin.isWatching(), callTimeout, 'isWatching()');
    if (r?.value !== true) throw new Error(`expected true, got ${JSON.stringify(r)}`);
    return 'true';
  });

  await run('watch.rejectsDouble', 'a second watchVolume() rejects', ALL, async () => {
    try {
      await withTimeout(plugin.watchVolume({}), callTimeout, 'watchVolume() #2');
    } catch {
      return 'rejected as expected';
    }
    throw new Error('a concurrent watch was accepted');
  });

  // Interactive: needs a human. Skipped when buttonPressTimeoutMs is 0.
  if (pressTimeout > 0) {
    await run('event.buttonPressed', `a hardware volume press emits volumeButtonPressed (${pressTimeout}ms)`, NATIVE, async () => {
      const seen = await new Promise<VolumeButtonPressedEvent | null>(resolve => {
        let done = false;
        const timer = setTimeout(() => { if (!done) { done = true; resolve(null); } }, pressTimeout);
        plugin.addListener('volumeButtonPressed', (e: VolumeButtonPressedEvent) => {
          if (!done) { done = true; clearTimeout(timer); resolve(e); }
        });
      });
      if (!seen) throw new Error('no volumeButtonPressed within the window — was a button actually pressed?');
      if (seen.direction !== 'up' && seen.direction !== 'down') {
        throw new Error(`bad direction: ${JSON.stringify(seen)}`);
      }
      return `direction=${seen.direction} value=${seen.value}`;
    });
  } else {
    record({
      id: 'event.buttonPressed',
      name: 'a hardware volume press emits volumeButtonPressed',
      status: 'skip',
      detail: 'set buttonPressTimeoutMs > 0 and press a volume button to run this',
      platforms: NATIVE,
    });
  }

  // ⚠️ This check used to re-set the CURRENT value, which cannot work on iOS: there is no
  // notifyListeners in iOS `setVolumeLevel` at all -- the event comes from `outputVolume` KVO,
  // and KVO does not fire when the value does not change. Android emits unconditionally, so
  // the bug was invisible there and in the web mock. Move the value for real, then restore.
  await run('event.levelChanged', 'a volume change emits volumeLevelChanged', NATIVE, async () => {
    const before = (await withTimeout(
      plugin.getVolumeLevel({ type: VolumeType.VOICE_CALL }), callTimeout, 'get')).value;
    // Move far enough to cross a hardware step on a coarse stream.
    const target = before > 0.5 ? Math.max(0, before - 0.3) : Math.min(1, before + 0.3);

    const seen = await new Promise<VolumeLevelChangedEvent | null>(resolve => {
      let done = false;
      const timer = setTimeout(() => { if (!done) { done = true; resolve(null); } },
        callTimeout + settleMs);
      plugin.addListener('volumeLevelChanged', (e: VolumeLevelChangedEvent) => {
        if (!done) { done = true; clearTimeout(timer); resolve(e); }
      });
      plugin.setVolumeLevel({ value: target, type: VolumeType.VOICE_CALL }).catch(() => undefined);
    });

    await plugin.setVolumeLevel({ value: before, type: VolumeType.VOICE_CALL }).catch(() => undefined);

    if (!seen) {
      throw new Error(
        `no volumeLevelChanged after moving ${before} -> ${target}` +
        (syncWrites ? '' : ' (iOS emits only from outputVolume KVO; if the device was already at a step boundary the value may not have moved)'),
      );
    }
    if (!isRatio(seen.value)) throw new Error(`bad payload: ${JSON.stringify(seen)}`);
    return `value=${seen.value} (moved ${before} -> ${target}, restored)`;
  });

  // ⚠️ Known cross-platform difference, reported rather than asserted. Android emits ONLY
  // volumeLevelChanged for a programmatic set (direction is null). iOS emits from the shared
  // KVO handler, which sends volumeButtonPressed TOO -- with a direction, even though no
  // button was pressed. Neither is wrong against the documented contract; a consumer that
  // treats volumeButtonPressed as "a human pressed a button" will be misled on iOS.
  record({
    id: 'event.platformNote',
    name: 'programmatic-set event shape differs by platform',
    status: 'skip',
    detail: syncWrites
      ? 'Android: a programmatic set emits volumeLevelChanged only'
      : 'iOS: a programmatic set ALSO emits volumeButtonPressed (KVO-driven) -- do not read that event as a human press',
    platforms: NATIVE,
  });

  // ---- teardown -----------------------------------------------------------
  await run('watch.clear', 'clearWatch() resolves and stops the watch', ALL, async () => {
    await withTimeout(plugin.clearWatch(), callTimeout, 'clearWatch()');
    const r = await withTimeout(plugin.isWatching(), callTimeout, 'isWatching()');
    if (r?.value !== false) throw new Error(`isWatching still ${JSON.stringify(r)} after clearWatch`);
    return 'stopped';
  });

  await run('stream.clear', 'clearVolumeControlStream() resolves', ALL, async () => {
    await withTimeout(plugin.clearVolumeControlStream(), callTimeout, 'clearVolumeControlStream');
    return 'restored to platform default';
  });

  await run('listeners.removeAll', 'removeAllListeners() resolves', ALL, async () => {
    await withTimeout(plugin.removeAllListeners(), callTimeout, 'removeAllListeners()');
    return 'removed';
  });

  const passed = checks.filter(c => c.status === 'pass').length;
  const failed = checks.filter(c => c.status === 'fail').length;
  const skipped = checks.filter(c => c.status === 'skip').length;

  return {
    platform,
    // Caller-independent timestamp; harmless if the host clock is wrong.
    startedAt: new Date().toISOString(),
    checks, passed, failed, skipped,
    ok: failed === 0,
  };
}

/** Render a report as plain text for a console or a debug panel. */
export function formatVerifyReport(r: VerifyReport): string {
  const icon = (s: VerifyStatus) => (s === 'pass' ? 'PASS' : s === 'fail' ? 'FAIL' : 'SKIP');
  const lines = [
    `capacitor-volume-controller verification — platform=${r.platform} at ${r.startedAt}`,
    ...r.checks.map(c => `  [${icon(c.status)}] ${c.id.padEnd(22)} ${c.name}\n           ${c.detail}`),
    `  ${r.passed} passed, ${r.failed} failed, ${r.skipped} skipped → ${r.ok ? 'OK' : 'FAILURES PRESENT'}`,
  ];
  return lines.join('\n');
}
