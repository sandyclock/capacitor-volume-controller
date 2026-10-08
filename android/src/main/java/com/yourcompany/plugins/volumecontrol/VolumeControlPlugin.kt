package com.yourcompany.plugins.volumecontrol

import android.content.Context
import android.media.AudioManager
import android.media.audiofx.AcousticEchoCanceler
import android.os.Build
import android.view.KeyEvent
import android.view.View
import com.getcapacitor.JSObject
import com.getcapacitor.Plugin
import com.getcapacitor.PluginCall
import com.getcapacitor.PluginMethod
import com.getcapacitor.annotation.CapacitorPlugin
import kotlin.math.round

/**
 * capacitor-volume-controller -- FORK of odion-cloud/capacitor-volume-control.
 *
 * The JS contract matches upstream 2.0.x (event-based `watchVolume` + `addListener`).
 * The Android implementation deliberately does NOT match upstream. See FORK.md.
 *
 * Two divergences, both intentional:
 *
 *  1. Upstream 2.0.x replaced the WebView key listener with a `ContentObserver` on
 *     `Settings.System`. An observer can NOTICE a volume change; it cannot INTERCEPT a
 *     keypress, and upstream's is hardcoded to STREAM_MUSIC, so it never sees changes on
 *     any other stream. We keep the key listener.
 *
 *  2. We add `setVolumeControlStream` / `clearVolumeControlStream`, which is the
 *     platform-sanctioned way to point the hardware volume keys at the stream your audio
 *     actually plays on. Upstream has no equivalent.
 */
@CapacitorPlugin(name = "VolumeControl")
class VolumeControlPlugin : Plugin() {

    private lateinit var audioManager: AudioManager
    private var isStarted = false
    private var suppressVolumeIndicator = false

    /**
     * When true the key listener consumes volume keys and adjusts the bound stream itself.
     *
     * ⚠️ OEM FALLBACK ONLY -- off by default, and it should stay off. Consuming volume keys
     * takes them away from TalkBack and from the system HUD, and if the adjustment below
     * ever fails the buttons become dead rather than merely misrouted. The supported path is
     * `setVolumeControlStream()`, which lets the SYSTEM handle the keys. Turn this on only
     * for a device proven to ignore `setVolumeControlStream`.
     */
    private var handleKeysDirectly = false

    /** The stream the direct-handling fallback adjusts. Follows `setVolumeControlStream`. */
    private var boundStreamType: Int = AudioManager.STREAM_MUSIC

    override fun load() {
        audioManager = context.getSystemService(Context.AUDIO_SERVICE) as AudioManager
    }

    private fun roundToTwoDecimals(value: Float): Float {
        return (round(value * 100f) / 100f).coerceIn(0f, 1f)
    }

    /**
     * Ported from upstream 2.0.3 -- the one piece of their rewrite worth having.
     *
     * Our own `VolumeType` TS enum has always declared these eight values; before this the
     * Kotlin ignored the option entirely and hardcoded STREAM_MUSIC, so the enum was
     * decorative. `null` / unknown falls back to MUSIC so existing callers are unaffected.
     */
    private fun streamTypeFromString(type: String?): Int {
        return when (type?.lowercase()) {
            "voice_call" -> AudioManager.STREAM_VOICE_CALL
            "system" -> AudioManager.STREAM_SYSTEM
            "ring" -> AudioManager.STREAM_RING
            "alarm" -> AudioManager.STREAM_ALARM
            "notification" -> AudioManager.STREAM_NOTIFICATION
            "dtmf" -> AudioManager.STREAM_DTMF
            "music" -> AudioManager.STREAM_MUSIC
            "default", null -> AudioManager.STREAM_MUSIC
            else -> AudioManager.STREAM_MUSIC
        }
    }

    private fun getCurrentVolume(streamType: Int): Float {
        val currentVolume = audioManager.getStreamVolume(streamType)
        val maxVolume = audioManager.getStreamMaxVolume(streamType)
        if (maxVolume <= 0) return 0f
        return roundToTwoDecimals(currentVolume.toFloat() / maxVolume.toFloat())
    }

    @PluginMethod
    fun getVolumeLevel(call: PluginCall) {
        try {
            val streamType = streamTypeFromString(call.getString("type"))
            val ret = JSObject()
            ret.put("value", getCurrentVolume(streamType))
            call.resolve(ret)
        } catch (e: Exception) {
            call.reject("Failed to get volume level", e)
        }
    }

    @PluginMethod
    fun setVolumeLevel(call: PluginCall) {
        try {
            val value = call.getFloat("value") ?: run {
                call.reject("Missing required parameter: value")
                return
            }
            if (value < 0f || value > 1f) {
                call.reject("Volume value must be between 0 and 1")
                return
            }

            val type = call.getString("type")
            val streamType = streamTypeFromString(type)
            val maxVolume = audioManager.getStreamMaxVolume(streamType)
            // `getCurrentVolume` already guards this; the setter did not. A stream can report
            // max 0 on fixed-volume devices (`AudioManager.isVolumeFixed()`, e.g. some
            // TV/dock/automotive outputs), where setStreamVolume is refused. Reject clearly
            // instead of computing an index of 0 and letting the platform throw.
            if (maxVolume <= 0) {
                call.reject("Stream $streamType reports no adjustable volume range on this device")
                return
            }
            // 🔴 FORK FIX 2026-08-26 -- this line used to read:
            //     (roundToTwoDecimals(value) * maxVolume).toInt()
            // which quantised the input to 2 decimals and THEN truncated, losing a whole step.
            // Worked example on STREAM_VOICE_CALL (max 15): asking for index 8 sends
            // 8/15 = 0.5333; roundToTwoDecimals -> 0.53; 0.53 * 15 = 7.95; .toInt() -> 7.
            // The caller asked for 8 and the device landed on 7.
            //
            // It also broke ROUND-TRIPPING, which matters because the design reads the current
            // level and later writes it back (D-11 / first-run adoption): getCurrentVolume
            // reports 2dp, so read(8) -> 0.53 -> write -> 7. Every read/write cycle drifted down.
            //
            // Round to the NEAREST index off the raw value, and clamp to the stream's range.
            // roundToTwoDecimals stays on the READ path, where reporting a 2dp fraction is fine.
            val targetVolumeLevel = round(value * maxVolume).toInt().coerceIn(0, maxVolume)

            // flags 0 -- do not show the system volume UI for a programmatic set.
            audioManager.setStreamVolume(streamType, targetVolumeLevel, 0)

            // Report what the device ACTUALLY landed on, not what was asked for. Streams have
            // coarse integer steps (STREAM_VOICE_CALL is often 5-7 against 15 for MUSIC), so
            // the granted value can differ noticeably from the requested one.
            val actualVolume = getCurrentVolume(streamType)
            val ret = JSObject()
            ret.put("value", actualVolume)
            call.resolve(ret)

            emitVolumeChanged(actualVolume, null, type)
        } catch (e: Exception) {
            call.reject("Failed to set volume level", e)
        }
    }

    /**
     * 🔑 FORK ADDITION. Bind the Activity's hardware volume keys to a stream.
     *
     * An Activity routes the volume keys to STREAM_MUSIC by default, so an app playing on
     * another stream sees the buttons move a stream nothing is playing on.
     */
    @PluginMethod
    fun setVolumeControlStream(call: PluginCall) {
        try {
            // `activity` is non-null once the plugin is attached to a BridgeActivity, but a
            // call arriving before attach would NPE inside runOnUiThread. Reject instead.
            val act = activity ?: run {
                call.reject("No activity attached; cannot bind the volume control stream")
                return
            }
            val type = call.getString("type")
            val streamType = streamTypeFromString(type)
            boundStreamType = streamType
            act.runOnUiThread { act.volumeControlStream = streamType }
            call.resolve()
        } catch (e: Exception) {
            call.reject("Failed to set volume control stream", e)
        }
    }

    /**
     * 🔑 FORK ADDITION. Restore the platform default binding.
     *
     * Call this when the session that requested a binding ends -- otherwise the device's
     * volume keys stay pointed at that stream for the rest of the Activity's life, which on a
     * personal phone means the user's media keys silently keep controlling the call stream.
     */
    @PluginMethod
    fun clearVolumeControlStream(call: PluginCall) {
        try {
            val act = activity ?: run {
                call.reject("No activity attached; cannot clear the volume control stream")
                return
            }
            boundStreamType = AudioManager.STREAM_MUSIC
            act.runOnUiThread {
                act.volumeControlStream = AudioManager.USE_DEFAULT_STREAM_TYPE
            }
            call.resolve()
        } catch (e: Exception) {
            call.reject("Failed to clear volume control stream", e)
        }
    }

    private fun audioModeName(mode: Int): String {
        return when (mode) {
            AudioManager.MODE_NORMAL -> "normal"
            AudioManager.MODE_RINGTONE -> "ringtone"
            AudioManager.MODE_IN_CALL -> "in_call"
            AudioManager.MODE_IN_COMMUNICATION -> "in_communication"
            else -> if (Build.VERSION.SDK_INT >= 30 && mode == AudioManager.MODE_CALL_SCREENING) "call_screening" else "other"
        }
    }

    /**
     * 🔑 FORK ADDITION. Read-only facts an app needs to choose its audio path and the
     * stream to control. Nothing is changed.
     *
     * - `echoCancellerAvailable`: `AcousticEchoCanceler.isAvailable()` -- whether the platform
     *   offers an echo-canceller effect. Some devices cancel echo inside the audio driver and
     *   report `false` here; treat it as a hint, not proof.
     * - `buildType`: `Build.TYPE` (`user`, `userdebug`, `eng`).
     * - `audioMode`: the CURRENT `AudioManager` mode. A WebView that opens the microphone
     *   with echo cancellation may switch to `in_communication`, and its playback then
     *   runs on `STREAM_VOICE_CALL` instead of `STREAM_MUSIC`. Read it while the
     *   microphone is open if you need to know which stream your audio plays on.
     * - `musicMaxSteps` / `voiceCallMaxSteps`: `getStreamMaxVolume` for the two streams.
     */
    @PluginMethod
    fun getAudioEnvironment(call: PluginCall) {
        try {
            val ret = JSObject()
            ret.put("platform", "android")
            ret.put("echoCancellerAvailable", AcousticEchoCanceler.isAvailable())
            ret.put("buildType", Build.TYPE)
            ret.put("manufacturer", Build.MANUFACTURER)
            ret.put("model", Build.MODEL)
            ret.put("audioMode", audioModeName(audioManager.mode))
            ret.put("musicMaxSteps", audioManager.getStreamMaxVolume(AudioManager.STREAM_MUSIC))
            ret.put("voiceCallMaxSteps", audioManager.getStreamMaxVolume(AudioManager.STREAM_VOICE_CALL))
            call.resolve(ret)
        } catch (e: Exception) {
            call.reject("Failed to read the audio environment", e)
        }
    }

    @PluginMethod
    fun isWatching(call: PluginCall) {
        val ret = JSObject()
        ret.put("value", isStarted)
        call.resolve(ret)
    }

    /**
     * Upstream 2.0.x contract: resolves immediately; presses arrive via `addListener`.
     *
     * The previous signature kept the PluginCall alive and resolved it repeatedly -- a
     * Capacitor anti-pattern that leaks a saved call for the lifetime of the watch.
     *
     * ⚠️ The listener does NOT consume the key by default (`return false`), so the system
     * still applies its own volume handling against whatever stream the Activity is bound to.
     * That is the point: pair this with `setVolumeControlStream()` and the system does the
     * work, draws the correct HUD, and accessibility keeps working. We only observe.
     */
    @PluginMethod
    fun watchVolume(call: PluginCall) {
        if (isStarted) {
            call.reject("Volume buttons has already been watched")
            return
        }

        suppressVolumeIndicator = call.getBoolean("suppressVolumeIndicator") ?: false
        handleKeysDirectly = call.getBoolean("handleKeysDirectly") ?: false

        bridge.webView.setOnKeyListener(
            object : View.OnKeyListener {
                override fun onKey(v: View?, keyCode: Int, event: KeyEvent?): Boolean {
                    if (keyCode != KeyEvent.KEYCODE_VOLUME_UP &&
                        keyCode != KeyEvent.KEYCODE_VOLUME_DOWN
                    ) {
                        return false
                    }

                    val isUp = keyCode == KeyEvent.KEYCODE_VOLUME_UP
                    val direction = if (isUp) "up" else "down"

                    if (event?.action == KeyEvent.ACTION_UP) {
                        if (handleKeysDirectly) {
                            // OEM fallback: adjust the bound stream ourselves.
                            val flag =
                                if (suppressVolumeIndicator) 0 else AudioManager.FLAG_SHOW_UI
                            audioManager.adjustStreamVolume(
                                boundStreamType,
                                if (isUp) AudioManager.ADJUST_RAISE else AudioManager.ADJUST_LOWER,
                                flag
                            )
                        }
                        emitVolumeChanged(getCurrentVolume(boundStreamType), direction, null)
                    }

                    // 🔴 Consume ONLY when we took responsibility for the adjustment.
                    //
                    // This previously read `handleKeysDirectly || suppressVolumeIndicator`,
                    // which contradicted the sentence above it: with suppressVolumeIndicator
                    // alone the key was CONSUMED while the adjust block -- gated on
                    // handleKeysDirectly -- never ran. Neither the system nor the plugin
                    // changed the volume, so the buttons went DEAD rather than merely
                    // misrouted: precisely the failure this comment claimed to prevent.
                    // (Inherited from 1.0.13, carried through the rewrite unexamined.)
                    //
                    // To hide the HUD *and* keep the buttons working, pass BOTH flags:
                    // handleKeysDirectly adjusts, suppressVolumeIndicator drops FLAG_SHOW_UI.
                    return handleKeysDirectly
                }
            }
        )

        isStarted = true
        call.resolve()
    }

    @PluginMethod
    fun clearWatch(call: PluginCall) {
        if (!isStarted) {
            call.reject("Volume buttons has not been watched")
            return
        }
        bridge.webView.setOnKeyListener(null)
        isStarted = false
        handleKeysDirectly = false
        suppressVolumeIndicator = false
        call.resolve()
    }

    private fun emitVolumeChanged(value: Float, direction: String?, type: String?) {
        val changed = JSObject()
        changed.put("value", value)
        if (direction != null) changed.put("direction", direction)
        if (type != null) changed.put("type", type)
        notifyListeners("volumeLevelChanged", changed)

        if (direction != null) {
            val pressed = JSObject()
            pressed.put("direction", direction)
            pressed.put("value", value)
            notifyListeners("volumeButtonPressed", pressed)
        }
    }
}
