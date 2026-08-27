/*
 * Web-implementation tests.
 *
 * ⚠️ Rewritten for the upstream 2.0.x event contract (FORK.md). The previous version was
 * written against our old 1.0.13 API and asserted things that no longer exist:
 *
 *   - `watchVolume(options, callback)` -- the keep-alive callback form. It is now
 *     `watchVolume(options)` and presses arrive via `addListener`.
 *   - an event named `volumeChanged` -- there is no such event. The names are
 *     `volumeButtonPressed` and `volumeLevelChanged`.
 *
 * These tests exercise the WEB implementation only, which is a mock: browsers expose no
 * system volume. They verify the CONTRACT (shapes, guards, watch state), not audio.
 */
import { VolumeControlWeb } from '../web';
import { VolumeType } from '../definitions';

describe('VolumeControlWeb', () => {
  let volumeControl: VolumeControlWeb;

  beforeEach(() => {
    volumeControl = new VolumeControlWeb();
  });

  afterEach(async () => {
    // clearWatch() REJECTS when nothing is being watched, and most tests here never start a
    // watch. The previous version called it unconditionally and un-awaited, which produced an
    // unhandled rejection on every such test. Guard on the actual state instead.
    if ((await volumeControl.isWatching()).value) {
      await volumeControl.clearWatch();
    }
  });

  describe('getVolumeLevel', () => {
    it('returns a level within [0, 1]', async () => {
      const result = await volumeControl.getVolumeLevel();
      expect(result.value).toBeGreaterThanOrEqual(0);
      expect(result.value).toBeLessThanOrEqual(1);
    });

    it('accepts a volume type', async () => {
      const result = await volumeControl.getVolumeLevel({ type: VolumeType.MUSIC });
      expect(result.value).toBeDefined();
    });

    it('accepts VOICE_CALL -- the type our Android implementation actually needs', async () => {
      const result = await volumeControl.getVolumeLevel({ type: VolumeType.VOICE_CALL });
      expect(result.value).toBeDefined();
    });
  });

  describe('setVolumeLevel', () => {
    it('accepts valid values', async () => {
      const result = await volumeControl.setVolumeLevel({ value: 0.5 });
      expect(result.value).toBe(0.5);
    });

    it('rejects values below 0', async () => {
      await expect(volumeControl.setVolumeLevel({ value: -0.1 })).rejects.toThrow();
    });

    it('rejects values above 1', async () => {
      await expect(volumeControl.setVolumeLevel({ value: 1.1 })).rejects.toThrow();
    });

    it('accepts a volume type', async () => {
      const result = await volumeControl.setVolumeLevel({
        value: 0.7,
        type: VolumeType.SYSTEM,
      });
      expect(result.value).toBe(0.7);
    });
  });

  describe('watchVolume', () => {
    it('takes options only -- no callback argument', async () => {
      await volumeControl.watchVolume({});
      expect((await volumeControl.isWatching()).value).toBe(true);
    });

    it('rejects a second concurrent watch', async () => {
      await volumeControl.watchVolume({});
      await expect(volumeControl.watchVolume({})).rejects.toThrow();
    });

    it('accepts watch options', async () => {
      await volumeControl.watchVolume({
        disableSystemVolumeHandler: true,
        suppressVolumeIndicator: true,
      });
      expect((await volumeControl.isWatching()).value).toBe(true);
    });
  });

  describe('clearWatch', () => {
    it('clears an active watch', async () => {
      await volumeControl.watchVolume({});
      await volumeControl.clearWatch();
      expect((await volumeControl.isWatching()).value).toBe(false);
    });

    it('rejects when nothing is being watched', async () => {
      await expect(volumeControl.clearWatch()).rejects.toThrow();
    });
  });

  describe('isWatching', () => {
    it('is false initially', async () => {
      expect((await volumeControl.isWatching()).value).toBe(false);
    });
  });

  describe('event listeners', () => {
    it('registers volumeButtonPressed', async () => {
      const listener = await volumeControl.addListener('volumeButtonPressed', jest.fn());
      expect(listener).toBeDefined();
      expect(typeof listener.remove).toBe('function');
    });

    it('registers volumeLevelChanged', async () => {
      const listener = await volumeControl.addListener('volumeLevelChanged', jest.fn());
      expect(listener).toBeDefined();
    });

    it('emits volumeLevelChanged when the level is set', async () => {
      const seen = jest.fn();
      await volumeControl.addListener('volumeLevelChanged', seen);
      await volumeControl.setVolumeLevel({ value: 0.42 });
      expect(seen).toHaveBeenCalledWith(expect.objectContaining({ value: 0.42 }));
    });

    it('removes all listeners', async () => {
      await volumeControl.addListener('volumeLevelChanged', jest.fn());
      await volumeControl.addListener('volumeButtonPressed', jest.fn());
      await expect(volumeControl.removeAllListeners()).resolves.not.toThrow();
    });
  });

  /*
   * 🔑 FORK ADDITIONS. Android-only in effect; the web implementation is a deliberate no-op
   * so callers can invoke them unconditionally without platform branching. These tests exist
   * to pin that no-op down -- if either ever starts throwing on web, every caller that does
   * not branch on platform breaks at once.
   */
  describe('volume control stream (fork addition)', () => {
    it('setVolumeControlStream resolves as a no-op on web', async () => {
      await expect(
        volumeControl.setVolumeControlStream({ type: VolumeType.VOICE_CALL }),
      ).resolves.toBeUndefined();
    });

    it('setVolumeControlStream resolves with no options', async () => {
      await expect(volumeControl.setVolumeControlStream()).resolves.toBeUndefined();
    });

    it('clearVolumeControlStream resolves as a no-op on web', async () => {
      await expect(volumeControl.clearVolumeControlStream()).resolves.toBeUndefined();
    });
  });
});
