import { registerPlugin } from '@capacitor/core';

import type { VolumeControlPlugin } from './definitions';

const VolumeControl = registerPlugin<VolumeControlPlugin>('VolumeControl', {
  web: () => import('./web').then(m => new m.VolumeControlWeb()),
});

export * from './definitions';
export { VolumeControl };

// 🔑 FORK ADDITION -- on-device verification harness (see verify.ts / VERIFY.md).
// This is the one line by which index.ts is no longer byte-identical to upstream.
export { verifyVolumeControl, formatVerifyReport } from './verify';
export type { VerifyReport, VerifyCheck, VerifyOptions, VerifyStatus } from './verify';