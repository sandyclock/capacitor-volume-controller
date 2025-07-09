import { registerPlugin } from '@capacitor/core';

import type { VolumeControlPlugin } from './definitions';

const VolumeControl = registerPlugin<VolumeControlPlugin>('VolumeControl', {
  web: () => import('./web').then(m => new m.VolumeControlWeb()),
});

// Add event listener support for volume changes
VolumeControl.addListener('volumeChanged', (event) => {
  // This will be handled by the watchVolume callback
  console.log('Volume changed:', event);
});

export * from './definitions';
export { VolumeControl };