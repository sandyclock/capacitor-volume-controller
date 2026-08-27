/*
 * capacitor-volume-controller -- FORK of odion-cloud/capacitor-volume-control.
 *
 * The JS CONTRACT below matches upstream 2.0.x deliberately, so this package stays a
 * drop-in shape for anyone reading upstream's docs. The NATIVE implementation diverges --
 * see FORK.md. Two additions are ours and have no upstream counterpart:
 * `setVolumeControlStream()` / `clearVolumeControlStream()`.
 */
import type { PluginListenerHandle } from '@capacitor/core';

export enum VolumeType {
  VOICE_CALL = 'voice_call',
  SYSTEM = 'system',
  RING = 'ring',
  DEFAULT = 'default',
  MUSIC = 'music',
  ALARM = 'alarm',
  NOTIFICATION = 'notification',
  DTMF = 'dtmf'
}

export interface VolumeOptions {
  /**
   * The type of volume to control
   * @default VolumeType.MUSIC
   */
  type?: VolumeType;
}

export interface SetVolumeOptions extends VolumeOptions {
  /**
   * Volume level as a float between 0.0 and 1.0
   * @example 0.5
   */
  value: number;
}

export interface VolumeResult {
  /**
   * Current volume level as a float between 0.0 and 1.0
   */
  value: number;
}

export interface WatchVolumeOptions {
  /**
   * Disable system volume handler (iOS only)
   * When true, prevents system volume UI from appearing
   * @default false
   */
  disableSystemVolumeHandler?: boolean;
  
  /**
   * Suppress volume indicator (Android only)
   * When true, prevents volume UI from appearing
   * @default false
   *
   * ⚠️ Only has an effect together with `handleKeysDirectly`. On its own it does NOT
   * suppress the system HUD, because the plugin no longer consumes the key event -- the
   * system performs the adjustment and draws its own indicator. See `handleKeysDirectly`.
   */
  suppressVolumeIndicator?: boolean;

  /**
   * 🔑 FORK ADDITION (no upstream counterpart). ANDROID ONLY. **OEM fallback -- leave off.**
   *
   * When true the plugin CONSUMES the hardware volume keys and calls `adjustStreamVolume`
   * itself against the stream bound by `setVolumeControlStream()`.
   *
   * The supported path is `setVolumeControlStream()`, which lets the SYSTEM handle the keys:
   * it draws the correct HUD and leaves the keys available to accessibility services such as
   * TalkBack. Consuming them takes both away, and if the adjustment fails the buttons go dead
   * rather than merely controlling the wrong stream.
   *
   * Turn this on only for a device proven to ignore `setVolumeControlStream`.
   *
   * @default false
   * @since 2.1.0
   */
  handleKeysDirectly?: boolean;
}

export interface VolumeButtonPressedEvent {
  /**
   * Direction of volume button press
   */
  direction: 'up' | 'down';

  /**
   * Current volume level as a float between 0.0 and 1.0 (best-effort).
   */
  value?: number;
}

export interface VolumeLevelChangedEvent extends VolumeResult {
  /**
   * Direction inferred from the change (best-effort).
   */
  direction?: 'up' | 'down';

  /**
   * The volume stream/type (Android only; iOS is global output volume).
   */
  type?: VolumeType;
}

export interface WatchStatusResult {
  /**
   * Whether volume watching is currently active
   */
  value: boolean;
}

export interface VolumeControlPlugin {
  /**
   * Get current volume level
   * @param options Volume options
   * @returns Promise resolving to current volume level
   * @since 1.0.0
   */
  getVolumeLevel(options?: VolumeOptions): Promise<VolumeResult>;

  /**
   * Set volume level
   * @param options Volume options with value
   * @returns Promise resolving to new volume level
   * @since 1.0.0
   */
  setVolumeLevel(options: SetVolumeOptions): Promise<VolumeResult>;

  /**
   * Start watching volume button presses
   * @param options Watch options
   * @returns Promise resolving when watching starts
   * @since 1.0.0
   */
  watchVolume(options: WatchVolumeOptions): Promise<void>;

  /**
   * Clear volume watch
   * @returns Promise resolving when watch is cleared
   * @since 1.0.0
   */
  clearWatch(): Promise<void>;

  /**
   * Check if volume watching is active
   * @returns Promise resolving to watch status
   * @since 1.0.0
   */
  isWatching(): Promise<WatchStatusResult>;

  /**
   * Listen to volume button press events
   * @param eventName - Name of the event to listen for
   * @param listenerFunc - Callback function that receives the event data
   * @returns Promise resolving to a listener handle
   * @since 1.0.0
   * 
   * @example
   * ```typescript
   * const listener = await VolumeControl.addListener('volumeButtonPressed', (event) => {
   *   console.log('Volume button pressed:', event.direction);
   * });
   * ```
   */
  addListener(
    eventName: 'volumeButtonPressed',
    listenerFunc: (event: VolumeButtonPressedEvent) => void,
  ): Promise<PluginListenerHandle>;

  /**
   * Listen to volume level changes (hardware buttons + system UI + setVolumeLevel()).
   * @since 2.0.2
   */
  addListener(
    eventName: 'volumeLevelChanged',
    listenerFunc: (event: VolumeLevelChangedEvent) => void,
  ): Promise<PluginListenerHandle>;

  /**
   * Remove all listeners for this plugin
   * @returns Promise resolving when all listeners are removed
   * @since 1.0.0
   */
  removeAllListeners(): Promise<void>;

  /**
   * 🔑 FORK ADDITION (no upstream counterpart). ANDROID ONLY -- a no-op on iOS and web.
   *
   * Bind the Activity's hardware volume keys to a specific stream, so the volume buttons
   * adjust that stream and the system draws the matching HUD.
   *
   * An Android Activity routes the volume keys to `STREAM_MUSIC` by default. An app whose
   * audio plays on another stream -- e.g. a WebRTC / voice-assistant session, which runs in
   * `MODE_IN_COMMUNICATION` on `STREAM_VOICE_CALL` -- will therefore see the buttons move a
   * stream nothing is playing on, which users report as "the volume buttons do nothing".
   *
   * Call this when your session STARTS and `clearVolumeControlStream()` when it ENDS.
   * Leaving the binding in place would keep the device's volume keys pointed at the wrong
   * stream for the rest of the Activity's life.
   *
   * ⚠️ This binds the keys; it does not guarantee the keys REACH default handling. A kiosk
   * Activity that overrides `onKeyDown` and swallows keys without calling `super` will still
   * eat them. That is an app-side concern, not something this plugin can fix.
   *
   * @param options stream to bind; omit `type` for MUSIC
   * @since 2.1.0
   */
  setVolumeControlStream(options?: VolumeOptions): Promise<void>;

  /**
   * 🔑 FORK ADDITION (no upstream counterpart). ANDROID ONLY -- a no-op on iOS and web.
   *
   * Restore the Activity's volume keys to the platform default
   * (`AudioManager.USE_DEFAULT_STREAM_TYPE`). Call this when the session that requested
   * `setVolumeControlStream()` ends.
   *
   * @since 2.1.0
   */
  clearVolumeControlStream(): Promise<void>;
}