/*
 * Tests for the verification harness.
 *
 * The harness is the thing that catches native defects, so it needs its own guard: a harness
 * that silently passes is worse than none. The central test here is `catches a
 * never-resolving watchVolume` — a fake plugin reproducing EXACTLY the un-migrated iOS
 * behaviour (watchVolume never settles, no events). If that test ever goes green-by-passing,
 * the harness has stopped doing its job.
 */
import { verifyVolumeControl, formatVerifyReport } from '../verify';
import { VolumeControlWeb } from '../web';
import type { VolumeControlPlugin } from '../definitions';

const opts = (over: Partial<Parameters<typeof verifyVolumeControl>[1]> = {}) => ({
  noCaptureSessionActive: true as const,
  platform: 'web',
  callTimeoutMs: 200,
  buttonPressTimeoutMs: 0,
  ...over,
});

describe('verifyVolumeControl', () => {
  it('refuses to run without the capture acknowledgement', async () => {
    await expect(
      verifyVolumeControl(new VolumeControlWeb(), { noCaptureSessionActive: false as any, platform: 'web' }),
    ).rejects.toThrow(/noCaptureSessionActive/);
  });

  it('passes against the web mock', async () => {
    const r = await verifyVolumeControl(new VolumeControlWeb(), opts());
    expect(r.failed).toBe(0);
    expect(r.ok).toBe(true);
    expect(r.passed).toBeGreaterThan(0);
  });

  it('skips native-only checks on web instead of failing them', async () => {
    const r = await verifyVolumeControl(new VolumeControlWeb(), opts());
    const androidOnly = r.checks.find(c => c.id === 'get.streamsDiffer');
    expect(androidOnly?.status).toBe('skip');
  });

  // 🔴 THE POINT OF THE HARNESS.
  it('catches a never-resolving watchVolume — the exact un-migrated iOS defect', async () => {
    const hung: VolumeControlPlugin = Object.assign(new VolumeControlWeb(), {
      // keep-alive shape: the promise is never settled and no event is ever emitted
      watchVolume: () => new Promise<void>(() => undefined),
    }) as any;

    const r = await verifyVolumeControl(hung, opts({ platform: 'ios' }));
    const watch = r.checks.find(c => c.id === 'watch.resolves');
    expect(watch?.status).toBe('fail');
    expect(watch?.detail).toMatch(/did not settle/);
    expect(r.ok).toBe(false);
  });

  it('catches a plugin that ignores the volume type', async () => {
    const ignores: VolumeControlPlugin = Object.assign(new VolumeControlWeb(), {
      getVolumeLevel: async () => ({ value: 2 }), // out of range → contract violation
    }) as any;
    const r = await verifyVolumeControl(ignores, opts());
    expect(r.checks.find(c => c.id === 'get.default')?.status).toBe('fail');
    expect(r.ok).toBe(false);
  });

  it('catches a setVolumeLevel that accepts an out-of-range value', async () => {
    const sloppy: VolumeControlPlugin = Object.assign(new VolumeControlWeb(), {
      setVolumeLevel: async ({ value }: any) => ({ value }),
    }) as any;
    const r = await verifyVolumeControl(sloppy, opts());
    expect(r.checks.find(c => c.id === 'set.rejectsOutOfRange')?.status).toBe('fail');
  });

  /*
   * 🔴 Guards the r2 finding: two checks were written to ANDROID write semantics and would
   * have failed against a CORRECT iOS plugin —
   *   set.roundTrip     — iOS resolves with the REQUESTED value and writes async, so the
   *                       read-back assertion cannot hold
   *   event.levelChanged — iOS never emits from setVolumeLevel; the event comes from
   *                       outputVolume KVO, which does not fire when the value is unchanged,
   *                       and the check used to re-set the CURRENT value
   * A harness that cries wolf gets ignored, so these model the iOS contract explicitly.
   */
  describe('iOS write semantics must not produce false failures', () => {
    /** Resolves with the REQUESTED value; the write lands later; never emits on set. */
    const iosLike = (): VolumeControlPlugin => {
      let actual = 0.5;
      const web = new VolumeControlWeb();
      return Object.assign(web, {
        getVolumeLevel: async () => ({ value: actual }),
        setVolumeLevel: async ({ value }: any) => {
          if (value < 0 || value > 1) throw new Error('out of range');
          setTimeout(() => {
            // hardware granularity: iOS volume lands on 1/16 steps, so granted != requested
            const granted = Math.round(value * 16) / 16;
            const changed = granted !== actual;
            actual = granted;
            if (changed) (web as any).notifyListeners('volumeLevelChanged', { value: actual });
          }, 50);
          return { value }; // the REQUESTED value, not the granted one
        },
      }) as any;
    };

    it('set.roundTrip does not fail on an async, requested-value-resolving plugin', async () => {
      const r = await verifyVolumeControl(iosLike(), opts({ platform: 'ios', settleMs: 200 }));
      const c = r.checks.find(x => x.id === 'set.roundTrip');
      expect(c?.status).toBe('pass');
      expect(c?.detail).toMatch(/async write/);
    });

    it('event.levelChanged passes when the value actually moves', async () => {
      const r = await verifyVolumeControl(iosLike(), opts({ platform: 'ios', settleMs: 200, callTimeoutMs: 1000 }));
      expect(r.checks.find(x => x.id === 'event.levelChanged')?.status).toBe('pass');
    });

    it('the whole iOS run is green on a correct iOS-shaped plugin', async () => {
      const r = await verifyVolumeControl(iosLike(), opts({ platform: 'ios', settleMs: 200, callTimeoutMs: 1000 }));
      expect(r.failed).toBe(0);
    });

    it('but STILL catches a hung watchVolume on that same iOS shape', async () => {
      const hung = Object.assign(iosLike(), {
        watchVolume: () => new Promise<void>(() => undefined),
      }) as any;
      const r = await verifyVolumeControl(hung, opts({ platform: 'ios', settleMs: 200 }));
      expect(r.checks.find(x => x.id === 'watch.resolves')?.status).toBe('fail');
      expect(r.ok).toBe(false);
    });
  });

  it('reports progress as checks land', async () => {
    const seen: string[] = [];
    const r = await verifyVolumeControl(new VolumeControlWeb(), opts({ onProgress: c => seen.push(c.id) }));
    expect(seen.length).toBe(r.checks.length);
  });

  it('formats a readable report', async () => {
    const r = await verifyVolumeControl(new VolumeControlWeb(), opts());
    const text = formatVerifyReport(r);
    expect(text).toContain('capacitor-volume-controller verification');
    expect(text).toMatch(/\d+ passed, \d+ failed, \d+ skipped/);
  });
});
