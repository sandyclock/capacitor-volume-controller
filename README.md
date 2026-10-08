# Capacitor Volume Control Plugin

A Capacitor plugin for advanced volume control with native Android and iOS implementations. This plugin provides comprehensive volume management capabilities including volume level control, volume change monitoring, and platform-specific features.

**Published on npm** · [capacitor-volume-controller](https://www.npmjs.com/package/capacitor-volume-controller) · **Supports Capacitor 5, 6, 7, and 8**

> **This is a fork.** Upstream is [odion-cloud/capacitor-volume-control](https://github.com/odion-cloud/capacitor-volume-control);
> this package is published as `capacitor-volume-controller` and is rebased on upstream **2.0.3**.
> Divergences from upstream (and why) are documented in [FORK.md](FORK.md); the device
> verification procedure is in [VERIFY.md](VERIFY.md).


## Features

- 🔊 **Volume Level Control**: Get and set volume levels for different audio streams
- 👂 **Volume Change Monitoring**: Watch for volume changes in real-time
- 📱 **Platform-Specific Features**: 
  - Android: Suppress volume indicator, control different volume types
  - iOS: Disable system volume handler, voice call volume control
- 🎯 **Type Safety**: Full TypeScript support with comprehensive type definitions
- 🔧 **Easy Integration**: Simple API that works seamlessly with Capacitor apps

---

## ⚠️ Android: your launcher Activity must let the volume keys through

`setVolumeControlStream()` routes the volume keys to a chosen stream — but only if the keys
**reach the window in the first place**. Many kiosk / lockdown / MDM apps override
`onKeyDown` or `dispatchKeyEvent` on their launcher Activity and swallow every key. If yours
does, this plugin appears to do nothing, and the failure is silent.

There are **two independent requirements**, and you need both:

| # | Requirement | Owned by |
|---|---|---|
| 1 | The Activity must **not consume** `KEYCODE_VOLUME_UP` (24) / `KEYCODE_VOLUME_DOWN` (25) | **your app** |
| 2 | The keys must be routed to the stream you care about | this plugin's `setVolumeControlStream()` |

### Measured on a Samsung tablet (Android 16), volume keys injected via `adb shell input keyevent 24`

| Configuration | `STREAM_VOICE_CALL` | `STREAM_MUSIC` |
|---|---|---|
| Activity swallows keys (default for many kiosk apps) | 11 → 11 | 12 → 12 |
| Keys allowed through, **no** `setVolumeControlStream` | 11 → 11 | **12 → 14** |
| Keys allowed through **+** `setVolumeControlStream('voice_call')` | **11 → 15** | 14 → 14 |

Without requirement 1 nothing moves at all. With requirement 1 but not 2, the keys move the
**default** stream (usually `STREAM_MUSIC`) — which is the wrong one if your audio is playing
on the voice-call route (a WebRTC / voice-agent app in `MODE_IN_COMMUNICATION`).

### What to do in your Activity

A standard `MainActivity` (`BridgeActivity`) already does the right thing — it does not
override `onKeyDown`, so the keys fall through to `PhoneWindow` and this plugin works with no
app-side change.

If you use a **custom kiosk Activity**, return `false` ("not handled") for the two volume
keycodes so they fall through to `PhoneWindow.onKeyDown`, which is what actually applies the
stream selected by `setVolumeControlStream()`:

```java
@Override
public boolean onKeyDown(int keyCode, KeyEvent event) {
    if (keyCode == KeyEvent.KEYCODE_VOLUME_UP || keyCode == KeyEvent.KEYCODE_VOLUME_DOWN) {
        return false;   // let the system handle it -> honours setVolumeControlStream()
    }
    // ... your existing lockdown handling for other keys
    return true;
}
```

⚠️ **Returning `true` consumes the key.** Do not "handle" volume yourself and also call
`setVolumeControlStream()` — you will get either double-stepping or nothing.

Some kiosk plugins expose an allow-list instead (e.g. a `setAllowedKeys([24, 25])` call).
Either approach works; the requirement is only that the Activity stops consuming the keys.

### Then bind the stream

```ts
import { VolumeControl } from 'capacitor-volume-controller';

// at session start, once the Activity lets the keys through
await VolumeControl.setVolumeControlStream({ type: 'voice_call' });

// on teardown
await VolumeControl.clearVolumeControlStream();
```

The binding lives on the **Activity**, so it does not survive process death — re-bind from JS
at session start. On iOS both calls are resolving no-ops, so you can call them unconditionally
without platform branching.

## ⚠️ Migration Notice

**v2.0+ Breaking Change:**
- The callback parameter in `watchVolume(options, callback)` is no longer supported.
- Use the event listener pattern `addListener('volumeButtonPressed', callback)` instead.
- The callback receives `{ direction: 'up' | 'down' }`.

---

## Installation

```bash
npm install capacitor-volume-controller
npx cap sync
```

### ✅ No MainActivity Integration Required!

This plugin uses `@capacitor-community/volume-buttons` for hardware button detection, which means **no MainActivity code changes needed**. Just install and use!

## Setup

1. Install dependencies:
```bash
npm install
```

2. Add the plugin:
```bash
npm install capacitor-volume-controller
```

3. Sync with native platforms:
```bash
npx cap sync
```

## Usage Examples

### Basic Volume Control

```typescript
import { VolumeControl, VolumeType } from 'capacitor-volume-controller';

// Get current volume
const volume = await VolumeControl.getVolumeLevel();
console.log('Current volume:', volume.value);

// Set volume to 50%
await VolumeControl.setVolumeLevel({ value: 0.5 });
```

### Volume Watching

```typescript
// First, add the event listener
await VolumeControl.addListener('volumeButtonPressed', (event) => {
  console.log('Volume button pressed:', event.direction); // 'up' or 'down'
});

// Then start watching
await VolumeControl.watchVolume({
  disableSystemVolumeHandler: true, // iOS only
  suppressVolumeIndicator: true,    // Android only
});

// Stop watching when done
await VolumeControl.clearWatch();
```

### Advanced Usage

```typescript
import { VolumeControl, VolumeType } from 'capacitor-volume-controller';

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
      // Add listener first
      await VolumeControl.addListener('volumeButtonPressed', this.handleVolumeChange.bind(this));
      
      // Then start watching
      await VolumeControl.watchVolume({
        disableSystemVolumeHandler: true,
        suppressVolumeIndicator: true
      });
      
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

  private handleVolumeChange(event: { direction: 'up' | 'down' }) {
    console.log(`Volume ${event.direction}`);
    // Custom volume handling logic
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
// Add listener
await VolumeControl.addListener('volumeButtonPressed', (event) => {
  console.log('Volume button pressed:', event.direction);
});

// Suppress volume indicator on Android
await VolumeControl.watchVolume({
  suppressVolumeIndicator: true
});

// Control different volume types
await VolumeControl.setVolumeLevel({
  value: 0.7,
  type: VolumeType.NOTIFICATION
});
```

### iOS Specific

```typescript
// Add listener
await VolumeControl.addListener('volumeButtonPressed', (event) => {
  console.log('Volume button pressed:', event.direction);
});

// Disable system volume handler on iOS
await VolumeControl.watchVolume({
  disableSystemVolumeHandler: true
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
  await VolumeControl.watchVolume({});
  await VolumeControl.watchVolume({}); // This will fail
} catch (error) {
  if (error.message.includes('already been watched')) {
    console.error('Volume watching is already active');
  }
}
```

## React Hook Example

```typescript
import { useEffect, useState } from 'react';
import { VolumeControl } from 'capacitor-volume-controller';

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
      // Add listener first
      await VolumeControl.addListener('volumeButtonPressed', (event) => {
        console.log('Volume button pressed:', event.direction);
        // You may want to update UI or state here
      });
      
      // Then start watching
      await VolumeControl.watchVolume({
        disableSystemVolumeHandler: true,
        suppressVolumeIndicator: true
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

## Vue Composition API Example

```typescript
import { ref, onMounted, onUnmounted } from 'vue';
import { VolumeControl } from 'capacitor-volume-controller';

export function useVolumeControl() {
  const volume = ref(0.5);
  const isWatching = ref(false);

  onMounted(async () => {
    // Get initial volume
    try {
      const result = await VolumeControl.getVolumeLevel();
      volume.value = result.value;
    } catch (error) {
      console.error('Failed to get initial volume:', error);
    }
  });

  onUnmounted(async () => {
    await stopWatching();
  });

  const startWatching = async () => {
    if (isWatching.value) return;

    try {
      // Add listener first
      await VolumeControl.addListener('volumeButtonPressed', (event) => {
        console.log('Volume button pressed:', event.direction);
      });
      
      // Then start watching
      await VolumeControl.watchVolume({
        disableSystemVolumeHandler: true,
        suppressVolumeIndicator: true
      });
      
      isWatching.value = true;
    } catch (error) {
      console.error('Failed to start watching:', error);
    }
  };

  const stopWatching = async () => {
    try {
      await VolumeControl.clearWatch();
      isWatching.value = false;
    } catch (error) {
      console.error('Failed to stop watching:', error);
    }
  };

  const setVolumeLevel = async (value: number) => {
    try {
      await VolumeControl.setVolumeLevel({ value });
      volume.value = value;
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

## Angular Service Example

```typescript
import { Injectable } from '@angular/core';
import { BehaviorSubject } from 'rxjs';
import { VolumeControl } from 'capacitor-volume-controller';

@Injectable({
  providedIn: 'root'
})
export class VolumeService {
  private volumeSubject = new BehaviorSubject<number>(0.5);
  private isWatchingSubject = new BehaviorSubject<boolean>(false);

  public volume$ = this.volumeSubject.asObservable();
  public isWatching$ = this.isWatchingSubject.asObservable();

  constructor() {
    this.initializeVolume();
  }

  private async initializeVolume() {
    try {
      const result = await VolumeControl.getVolumeLevel();
      this.volumeSubject.next(result.value);
    } catch (error) {
      console.error('Failed to get initial volume:', error);
    }
  }

  async startWatching(): Promise<void> {
    if (this.isWatchingSubject.value) return;

    try {
      // Add listener first
      await VolumeControl.addListener('volumeButtonPressed', (event) => {
        console.log('Volume button pressed:', event.direction);
        // You may want to update with actual logic
      });
      
      // Then start watching
      await VolumeControl.watchVolume({
        disableSystemVolumeHandler: true,
        suppressVolumeIndicator: true
      });
      
      this.isWatchingSubject.next(true);
    } catch (error) {
      console.error('Failed to start watching:', error);
      throw error;
    }
  }

  async stopWatching(): Promise<void> {
    try {
      await VolumeControl.clearWatch();
      this.isWatchingSubject.next(false);
    } catch (error) {
      console.error('Failed to stop watching:', error);
      throw error;
    }
  }

  async setVolumeLevel(value: number): Promise<void> {
    try {
      await VolumeControl.setVolumeLevel({ value });
      this.volumeSubject.next(value);
    } catch (error) {
      console.error('Failed to set volume:', error);
      throw error;
    }
  }
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

## Platform Support

### 📦 Capacitor & npm

- **Capacitor**: Compatible with Capacitor **5**, **6**, **7**, and **8**.
- **npm**: Package is published to [npm](https://www.npmjs.com/package/capacitor-volume-controller); releases are pushed to GitHub and then published to npm.

### 📱 Supported Devices

| Platform | Support Level | Minimum Version | Features |
|----------|---------------|-----------------|----------|
| **Android** | ✅ Full Support | Android 6.0+ (API 23+) | All volume types, hardware buttons, real-time monitoring |
| **iOS** | ✅ Full Support | iOS 13.0+ | Volume control, hardware buttons, audio session management |
| **Web** | ⚠️ Development Only | All modern browsers | Mock implementation for testing |

### 🏆 Android Version Compatibility

| Android Version | API Level | Support Level | Features |
|-----------------|-----------|---------------|----------|
| Android 14+ | API 34+ | ✅ Full | All features, visual media permissions |
| Android 13 | API 33 | ✅ Full | Granular media permissions |
| Android 10-12 | API 29-32 | ✅ Full | Scoped storage, external volumes |
| Android 6-9 | API 23-28 | ✅ Full | Runtime permissions, SD card access |
| Android 5 | API 21-22 | ⚠️ Basic | Limited external storage access |

### 🎯 Volume Types Support

| Volume Type | Android | iOS | Description |
|-------------|---------|-----|-------------|
| `VolumeType.MUSIC` | ✅ | ✅ | Music, videos, games, and other media |
| `VolumeType.SYSTEM` | ✅ | ❌ | System sounds and notifications |
| `VolumeType.RING` | ✅ | ❌ | Phone ringtone volume |
| `VolumeType.NOTIFICATION` | ✅ | ❌ | Notification sounds |
| `VolumeType.ALARM` | ✅ | ❌ | Alarm clock volume |
| `VolumeType.VOICE_CALL` | ✅ | ✅ | Voice call volume |
| `VolumeType.DTMF` | ✅ | ❌ | DTMF tones |

## API Reference

### Methods

#### `getVolumeLevel(options?)`
Get the current volume level for a specific audio stream.

```typescript
getVolumeLevel({
  type?: VolumeType;        // Volume type to get (default: 'music')
}): Promise<VolumeResult>

// Returns: { value: number } (0.0 to 1.0)
```

#### `setVolumeLevel(options)`
Set the volume level for a specific audio stream.

```typescript
setVolumeLevel({
  value: number;            // Volume level (0.0 to 1.0)
  type?: VolumeType;        // Volume type to set (default: 'music')
}): Promise<VolumeResult>

// Returns: { value: number } (the new volume level)
```

#### `watchVolume(options)`
Start watching for volume button presses.

```typescript
watchVolume({
  disableSystemVolumeHandler?: boolean;  // iOS: disable system UI
  suppressVolumeIndicator?: boolean;     // Android: hide volume UI
}): Promise<void>
```

#### `addListener(eventName, callback)`
Listen for volume button press events.

```typescript
addListener(
  'volumeButtonPressed',
  callback: (event: { direction: 'up' | 'down' }) => void
): Promise<PluginListenerHandle>

// Event data: { direction: 'up' | 'down' }
```

#### `clearWatch()`
Stop watching for volume changes.

```typescript
clearWatch(): Promise<void>
```

#### `isWatching()`
Check if volume watching is currently active.

```typescript
isWatching(): Promise<{ value: boolean }>
```

### Configuration Options

| Option | Platform | Description |
|--------|----------|-------------|
| `suppressVolumeIndicator` | Android | Hide system volume UI when changing volume |
| `disableSystemVolumeHandler` | iOS | Disable system volume UI and intercept hardware buttons |
| `type` | Both | Specify volume type (MUSIC, SYSTEM, RING, etc.) |
| `value` | Both | Volume level between 0.0 and 1.0 |

### Error Handling

Common errors and their solutions:

| Error Message | Cause | Solution |
|---------------|-------|----------|
| `Volume value must be between 0.0 and 1.0` | Invalid volume level | Ensure volume is between 0.0 and 1.0 |
| `Volume buttons has already been watched` | Multiple watch calls | Call `clearWatch()` before starting new watch |
| `Volume slider not available` | iOS setup issue | Check audio session configuration |
| `Failed to get volume level` | Permission or system error | Verify permissions and device compatibility |
| `Volume observer registration failed` | Android system issue | Restart app or check system permissions |
| `Audio session setup failed` | iOS audio session issue | Check audio session category and options |

### Best Practices

1. **Always clean up listeners**: Remove event listeners when components unmount with `removeAllListeners()`
2. **Add listener before watching**: Call `addListener()` before `watchVolume()` to ensure events are captured
3. **Handle errors gracefully**: Wrap volume operations in try-catch blocks
4. **Check watch status**: Use `isWatching()` to avoid duplicate watch calls
5. **Test on real devices**: Volume watching requires physical hardware

## Support This Project

Help me improve this plugin and build better tools for the community!

### 🤝 GitHub Sponsors
Support through GitHub's official sponsorship program:
- **[GitHub Sponsors](https://github.com/sponsors/odion-cloud)** - Most transparent and developer-friendly way to support

### ₿ Cryptocurrency Support
Support via crypto donations across multiple networks:

| Network | Address |
|---------|---------|
| **Bitcoin (BTC)** | `bc1q2k0ftm2fgst22kzj683e8gpau3spfa23ttkg26` |
| **USDT (Ethereum)** | `0xd6f4d8733c8C23e7bEC8Aeba37F4b3D2e93172d1` |
| **USDT (BNB Chain)** | `0xd6f4d8733c8C23e7bEC8Aeba37F4b3D2e93172d1` |
| **USDT (TRON/TRC20)** | `TXVy781mQ2tCuQ1BrattXWueUHp1wB5fwt` |
| **USDT (Solana)** | `GZ8jmSUUzc4dQF7Cthj2atomvpBZWqccR81N9DL4o1Be` |
| **USDT (TON)** | `UQAthXSNIlauj3SrzpDAU4VYxgEVV3niOSmeTPCtMBKGfEAE` |

### 💻 Why Support?
Your contributions help me:
- Upgrade to better development hardware
- Improve workspace and productivity
- Dedicate more time to open source projects
- Add new features faster
- Provide better documentation and examples

### 🤝 Other Ways to Help

- **⭐ Star the Project** - Give us a star on [GitHub](https://github.com/odion-cloud/capacitor-volume-control) to show your support!
- **🐛 Report Issues** - Help improve the plugin by reporting bugs and suggesting features
- **📖 Improve Docs** - Contribute to documentation, examples, and tutorials
- **💬 Spread the Word** - Share the plugin with other developers who might find it useful

## Contributing

We welcome contributions! Please see our [Contributing Guide](https://github.com/odion-cloud/capacitor-volume-control/blob/main/CONTRIBUTING.md) for details.

## License

This project is licensed under the MIT License - see the [LICENSE](https://github.com/odion-cloud/capacitor-volume-control/blob/main/LICENSE) file for details.

## Troubleshooting

### Android: Kotlin Version Incompatibility

If you encounter the error:
```
Module was compiled with an incompatible version of Kotlin. The binary version of its metadata is 1.9.0, expected version is 1.7.1
```

**Solution**: Update your project's Kotlin version in `android/build.gradle`:

```groovy
buildscript {
    ext.kotlin_version = '1.9.10'  // Update from older version
    dependencies {
        classpath "org.jetbrains.kotlin:kotlin-gradle-plugin:$kotlin_version"
    }
}
```

This plugin requires Kotlin 1.9.0+ and Android Gradle Plugin 7.4.2+.

### iOS: Pod Name Mismatch

If you're using the scoped npm package name and encounter pod installation issues:

**Symptom**: Pod name in Podfile (`OdionCloudCapacitorVolumeControl`) doesn't match the podspec file name (`CapacitorVolumeControl`)

**Solution**: Reference the package with an alias in `package.json`:

```json
{
  "dependencies": {
    "capacitor-volume-control": "npm:capacitor-volume-controller@^1.0.13"
  }
}
```

Then run:
```bash
npm install
npx cap sync ios
```

### Other Common Issues

**Volume watching not working on emulators/simulators**
- Volume watching requires physical hardware buttons
- Test on real devices for volume button detection

**Permission denied errors**
- Ensure you've added the required permissions to your AndroidManifest.xml or Info.plist
- Request permissions at runtime before calling volume control methods

**Build errors after updating**
- Clean your build folders:
  ```bash
  cd android && ./gradlew clean
  # or
  cd ios && rm -rf Pods && pod install
  ```
- Invalidate caches in Android Studio: File → Invalidate Caches → Restart

## Changelog

See [CHANGELOG.md](https://github.com/odion-cloud/capacitor-volume-control/blob/main/CHANGELOG.md) for a list of changes and version history.