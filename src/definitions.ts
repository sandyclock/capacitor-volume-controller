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
   */
  suppressVolumeIndicator?: boolean;
}

export interface VolumeEvent {
  /**
   * Direction of volume change
   */
  direction: 'up' | 'down';
  
  /**
   * New volume level as a float between 0.0 and 1.0
   */
  level: number;
}

export interface WatchStatusResult {
  /**
   * Whether volume watching is currently active
   */
  value: boolean;
}

export type VolumeChangeCallback = (event: VolumeEvent) => void;

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
   * Start watching volume changes
   * @param options Watch options
   * @param callback Callback function for volume changes
   * @returns Promise resolving when watch is started
   * @since 1.0.0
   */
  watchVolume(options: WatchVolumeOptions, callback: VolumeChangeCallback): Promise<void>;

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
}