# Capacitor Volume Control Plugin

A Capacitor plugin for advanced volume control with native Android and iOS implementations. This plugin provides comprehensive volume management capabilities including volume level control, volume change monitoring, and platform-specific features.

## Features

- 🔊 **Volume Level Control**: Get and set volume levels for different audio streams
- 👂 **Volume Change Monitoring**: Watch for volume changes in real-time
- 📱 **Platform-Specific Features**: 
  - Android: Suppress volume indicator, control different volume types
  - iOS: Disable system volume handler, voice call volume control
- 🎯 **Type Safety**: Full TypeScript support with comprehensive type definitions
- 🔧 **Easy Integration**: Simple API that works seamlessly with Capacitor apps

## Installation

```bash
npm install @odion-cloud/capacitor-volume-control
npx cap sync
```

## Setup

1. Install dependencies:
```bash
npm install
```

2. Add the plugin:
```bash
npm install @odion-cloud/capacitor-volume-control
```

3. Sync with native platforms:
```bash
npx cap sync
```

## Usage Examples

### Basic Volume Control

```typescript
import { VolumeControl, VolumeType } from '@odion-cloud/capacitor-volume-control';

// Get current volume
const volume = await VolumeControl.getVolumeLevel();
console.log('Current volume:', volume.value);

// Set volume to 50%
await VolumeControl.setVolumeLevel({ value: 0.5 });
```

### Volume Watching

```typescript
// Start watching volume changes
await VolumeControl.watchVolume({
  disableSystemVolumeHandler: true, // iOS only
  suppressVolumeIndicator: true,    // Android only
}, (event) => {
  console.log('Volume changed:', event.direction, event.level);
});

// Stop watching
await VolumeControl.clearWatch();
```

### Advanced Usage

```typescript
import { VolumeControl, VolumeType } from '@odion-cloud/capacitor-volume-control';

class VolumeService {
  private isWatching = false;

  async initializeVolume() {
    try {
      // Get current music volume
      const musicVolume = await VolumeControl.getVolumeLevel({
        type: VolumeType.MUSIC
      });
      
      console.log('Music volume:', musicVolume.value);
      
      // Set system volume
      await VolumeControl.setVolumeLevel({
        value: 0.8,
        type: VolumeType.SYSTEM
      });
      
    } catch (error) {
      console.error('Volume initialization error:', error);
    }
  }

  async startWatching() {
    if (this.isWatching) return;

    try {
      await VolumeControl.watchVolume({
        disableSystemVolumeHandler: true,
        suppressVolumeIndicator: true
      }, this.handleVolumeChange.bind(this));
      
      this.isWatching = true;
      console.log('Started volume watching');
      
    } catch (error) {
      console.error('Volume watching error:', error);
    }
  }

  async stopWatching() {
    try {
      await VolumeControl.clearWatch();
      this.isWatching = false;
      console.log('Stopped volume watching');
      
    } catch (error) {
      console.error('Stop watching error:', error);
    }
  }

  private handleVolumeChange(event: { direction: 'up' | 'down', level: number }) {
    console.log(`Volume ${event.direction}: ${event.level}`);
    
    // Custom volume handling logic
    if (event.level > 0.9) {
      console.warn('Volume is very high!');
    }
  }

  async getWatchStatus() {
    const status = await VolumeControl.isWatching();
    return status.value;
  }
}

// Usage
const volumeService = new VolumeService();

// Initialize
await volumeService.initializeVolume();

// Start watching
await volumeService.startWatching();

// Check status
const isWatching = await volumeService.getWatchStatus();
console.log('Is watching:', isWatching);

// Stop watching
await volumeService.stopWatching();
```

## Platform-Specific Examples

### Android Specific

```typescript
// Suppress volume indicator on Android
await VolumeControl.watchVolume({
  suppressVolumeIndicator: true
}, (event) => {
  console.log('Volume changed silently:', event);
});

// Control different volume types
await VolumeControl.setVolumeLevel({
  value: 0.7,
  type: VolumeType.NOTIFICATION
});
```

### iOS Specific

```typescript
// Disable system volume handler on iOS
await VolumeControl.watchVolume({
  disableSystemVolumeHandler: true
}, (event) => {
  console.log('Volume changed without system UI:', event);
});

// Control voice call volume
await VolumeControl.setVolumeLevel({
  value: 0.9,
  type: VolumeType.VOICE_CALL
});
```

## Error Handling

```typescript
try {
  await VolumeControl.setVolumeLevel({ value: 1.5 });
} catch (error) {
  if (error.message.includes('between 0.0 and 1.0')) {
    console.error('Invalid volume value');
  } else {
    console.error('Unexpected error:', error);
  }
}

try {
  await VolumeControl.watchVolume({}, callback);
  await VolumeControl.watchVolume({}, callback); // This will fail
} catch (error) {
  if (error.message.includes('already active')) {
    console.error('Volume watching is already active');
  }
}
```

## React Hook Example

```typescript
import { useEffect, useState } from 'react';
import { VolumeControl } from '@odion-cloud/capacitor-volume-control';

export function useVolumeControl() {
  const [volume, setVolume] = useState(0.5);
  const [isWatching, setIsWatching] = useState(false);

  useEffect(() => {
    // Get initial volume
    VolumeControl.getVolumeLevel().then(result => {
      setVolume(result.value);
    });

    // Cleanup on unmount
    return () => {
      VolumeControl.clearWatch();
    };
  }, []);

  const startWatching = async () => {
    if (isWatching) return;

    try {
      await VolumeControl.watchVolume({
        disableSystemVolumeHandler: true,
        suppressVolumeIndicator: true
      }, (event) => {
        setVolume(event.level);
      });
      
      setIsWatching(true);
    } catch (error) {
      console.error('Failed to start watching:', error);
    }
  };

  const stopWatching = async () => {
    try {
      await VolumeControl.clearWatch();
      setIsWatching(false);
    } catch (error) {
      console.error('Failed to stop watching:', error);
    }
  };

  const setVolumeLevel = async (value: number) => {
    try {
      await VolumeControl.setVolumeLevel({ value });
      setVolume(value);
    } catch (error) {
      console.error('Failed to set volume:', error);
    }
  };

  return {
    volume,
    isWatching,
    startWatching,
    stopWatching,
    setVolumeLevel
  };
}
```

## Testing

Run the example:

```bash
npm start
```

Build for production:

```bash
npm run build
```

Test on device:

```bash
npx cap run android
npx cap run ios
```