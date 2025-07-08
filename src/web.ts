import { WebPlugin } from '@capacitor/core';

import type { 
  VolumeControlPlugin, 
  VolumeOptions, 
  SetVolumeOptions, 
  VolumeResult, 
  WatchVolumeOptions, 
  VolumeChangeCallback, 
  WatchStatusResult 
} from './definitions';

export class VolumeControlWeb extends WebPlugin implements VolumeControlPlugin {
  private watchCallback?: VolumeChangeCallback;
  private isWatchingVolume = false;

  async getVolumeLevel(options?: VolumeOptions): Promise<VolumeResult> {
    console.log('getVolumeLevel called with options:', options);
    
    // Web implementation - limited to what's available in browsers
    // Most browsers don't expose system volume, so we return a mock value
    return { value: 0.5 };
  }

  async setVolumeLevel(options: SetVolumeOptions): Promise<VolumeResult> {
    console.log('setVolumeLevel called with options:', options);
    
    // Validate input
    if (options.value < 0 || options.value > 1) {
      throw new Error('Volume value must be between 0.0 and 1.0');
    }
    
    // Web implementation - browsers don't allow setting system volume
    // This would typically show a warning or throw an error
    console.warn('Setting system volume is not supported in web browsers');
    
    return { value: options.value };
  }

  async watchVolume(options: WatchVolumeOptions, callback: VolumeChangeCallback): Promise<void> {
    console.log('watchVolume called with options:', options);
    
    if (this.isWatchingVolume) {
      throw new Error('Volume watching is already active');
    }
    
    this.watchCallback = callback;
    this.isWatchingVolume = true;
    
    // Web implementation - limited volume change detection
    // We can't reliably detect hardware volume button presses in browsers
    console.warn('Volume watching has limited functionality in web browsers');
  }

  async clearWatch(): Promise<void> {
    console.log('clearWatch called');
    
    this.watchCallback = undefined;
    this.isWatchingVolume = false;
  }

  async isWatching(): Promise<WatchStatusResult> {
    return { value: this.isWatchingVolume };
  }
}