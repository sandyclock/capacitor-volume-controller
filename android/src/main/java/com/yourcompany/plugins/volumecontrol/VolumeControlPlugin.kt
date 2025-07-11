package com.yourcompany.plugins.volumecontrol

import android.content.Context
import android.database.ContentObserver
import android.media.AudioManager
import android.net.Uri
import android.os.Handler
import android.os.Looper
import android.provider.Settings
import android.util.Log
import com.getcapacitor.JSObject
import com.getcapacitor.Plugin
import com.getcapacitor.PluginCall
import com.getcapacitor.PluginMethod
import com.getcapacitor.annotation.CapacitorPlugin

@CapacitorPlugin(name = "VolumeControl")
class VolumeControlPlugin : Plugin() {
    private var audioManager: AudioManager? = null
    private var streamType = AudioManager.STREAM_MUSIC
    private var isWatching = false
    private var suppressVolumeIndicator = false
    private var volumeObserver: VolumeObserver? = null
    private var previousVolume = 0.0f
    private var isSettingVolume = false
    
    companion object {
        private const val TAG = "VolumeControlPlugin"
    }

    override fun load() {
        audioManager = context.getSystemService(Context.AUDIO_SERVICE) as AudioManager
        // Initialize previous volume
        updatePreviousVolume()
    }

    private fun updatePreviousVolume() {
        audioManager?.let { am ->
            val maxVolume = am.getStreamMaxVolume(streamType)
            val currentVolume = am.getStreamVolume(streamType)
            previousVolume = if (maxVolume > 0) currentVolume.toFloat() / maxVolume.toFloat() else 0.0f
        }
    }

    private fun getVolumeTypeFromString(type: String?): Int {
        return when (type?.lowercase()) {
            "voice_call" -> AudioManager.STREAM_VOICE_CALL
            "system" -> AudioManager.STREAM_SYSTEM
            "ring" -> AudioManager.STREAM_RING
            "music", "default" -> AudioManager.STREAM_MUSIC
            "alarm" -> AudioManager.STREAM_ALARM
            "notification" -> AudioManager.STREAM_NOTIFICATION
            "dtmf" -> AudioManager.STREAM_DTMF
            else -> AudioManager.STREAM_MUSIC
        }
    }

    @PluginMethod
    fun isWatching(call: PluginCall) {
        val ret = JSObject()
        ret.put("value", isWatching)
        call.resolve(ret)
    }

    @PluginMethod
    fun getVolumeLevel(call: PluginCall) {
        try {
            val type = call.getString("type", "music")
            val targetStreamType = getVolumeTypeFromString(type)
            
            val maxVolume = audioManager?.getStreamMaxVolume(targetStreamType) ?: 15
            val currentVolume = audioManager?.getStreamVolume(targetStreamType) ?: 0
            val normalizedVolume = if (maxVolume > 0) currentVolume.toFloat() / maxVolume.toFloat() else 0.0f
            
            Log.d(TAG, "getVolumeLevel - Type: $type, Current: $currentVolume, Max: $maxVolume, Normalized: $normalizedVolume")
            
            val ret = JSObject()
            ret.put("value", normalizedVolume)
            call.resolve(ret)
        } catch (e: Exception) {
            Log.e(TAG, "Failed to get volume level", e)
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
                call.reject("Volume value must be between 0.0 and 1.0")
                return
            }

            val type = call.getString("type", "music")
            val targetStreamType = getVolumeTypeFromString(type)

            val maxVolume = audioManager?.getStreamMaxVolume(targetStreamType) ?: 15
            val targetVolume = (value * maxVolume).toInt()
            
            Log.d(TAG, "setVolumeLevel - Type: $type, Value: $value, Target: $targetVolume, Max: $maxVolume")
            
            isSettingVolume = true
            val flags = if (suppressVolumeIndicator && isWatching) 0 else AudioManager.FLAG_SHOW_UI
            audioManager?.setStreamVolume(targetStreamType, targetVolume, flags)
            
            // Update previous volume if this is for the watched stream
            if (targetStreamType == streamType) {
                previousVolume = value
            }
            
            // Reset flag after a short delay
            Handler(Looper.getMainLooper()).postDelayed({
                isSettingVolume = false
            }, 100)
            
            val ret = JSObject()
            ret.put("value", value)
            call.resolve(ret)
        } catch (e: Exception) {
            Log.e(TAG, "Failed to set volume level", e)
            call.reject("Failed to set volume level", e)
        }
    }

    @PluginMethod
    fun watchVolume(call: PluginCall) {
        if (isWatching) {
            call.reject("Volume buttons has already been watched")
            return
        }

        try {
            val type = call.getString("type", "music")
            streamType = getVolumeTypeFromString(type)
            suppressVolumeIndicator = call.getBoolean("suppressVolumeIndicator", false) ?: false
            
            Log.d(TAG, "watchVolume - Type: $type, StreamType: $streamType, Suppress: $suppressVolumeIndicator")
            
            // Update initial volume
            updatePreviousVolume()
            
            // Create and register volume observer
            volumeObserver = VolumeObserver(Handler(Looper.getMainLooper()))
            
            // Register observer for the specific volume type
            val volumeUri = when (streamType) {
                AudioManager.STREAM_MUSIC -> Settings.System.getUriFor("volume_music")
                AudioManager.STREAM_RING -> Settings.System.getUriFor("volume_ring")
                AudioManager.STREAM_NOTIFICATION -> Settings.System.getUriFor("volume_notification")
                AudioManager.STREAM_ALARM -> Settings.System.getUriFor("volume_alarm")
                AudioManager.STREAM_SYSTEM -> Settings.System.getUriFor("volume_system")
                AudioManager.STREAM_VOICE_CALL -> Settings.System.getUriFor("volume_voice")
                else -> Settings.System.getUriFor("volume_music")
            }
            
            context.contentResolver.registerContentObserver(
                volumeUri,
                false,
                volumeObserver!!
            )
            
            isWatching = true
            
            val ret = JSObject()
            ret.put("callbackId", "volume-watch-${System.currentTimeMillis()}")
            call.resolve(ret)
            
        } catch (e: Exception) {
            Log.e(TAG, "Failed to start volume watching", e)
            call.reject("Failed to start volume watching", e)
        }
    }

    @PluginMethod
    fun clearWatch(call: PluginCall) {
        if (!isWatching) {
            call.reject("Volume buttons has not been watched")
            return
        }

        try {
            volumeObserver?.let { observer ->
                context.contentResolver.unregisterContentObserver(observer)
            }
            volumeObserver = null
            isWatching = false
            
            Log.d(TAG, "clearWatch - Volume watching stopped")
            call.resolve()
        } catch (e: Exception) {
            Log.e(TAG, "Failed to clear volume watch", e)
            call.reject("Failed to clear volume watch", e)
        }
    }

    private inner class VolumeObserver(handler: Handler) : ContentObserver(handler) {
        override fun onChange(selfChange: Boolean, uri: Uri?) {
            super.onChange(selfChange, uri)
            
            if (isSettingVolume) {
                Log.d(TAG, "VolumeObserver - Ignoring programmatic volume change")
                return
            }
            
            try {
                audioManager?.let { am ->
                    val maxVolume = am.getStreamMaxVolume(streamType)
                    val currentVolumeInt = am.getStreamVolume(streamType)
                    val currentVolume = if (maxVolume > 0) currentVolumeInt.toFloat() / maxVolume.toFloat() else 0.0f
                    
                    Log.d(TAG, "VolumeObserver - Previous: $previousVolume, Current: $currentVolume, Raw: $currentVolumeInt/$maxVolume")
                    
                    // Only process if volume actually changed
                    if (Math.abs(currentVolume - previousVolume) > 0.001f) {
                        val direction = if (currentVolume > previousVolume) "up" else "down"
                        
                        Log.d(TAG, "VolumeObserver - Volume changed $direction from $previousVolume to $currentVolume")
                        
                        // If suppressing volume indicator, reset to previous volume
                        val finalVolume = if (suppressVolumeIndicator) {
                            Log.d(TAG, "VolumeObserver - Suppressing volume change, resetting to $previousVolume")
                            isSettingVolume = true
                            val targetVolumeInt = (previousVolume * maxVolume).toInt()
                            am.setStreamVolume(streamType, targetVolumeInt, 0) // No UI flags
                            
                            // Reset flag after delay
                            Handler(Looper.getMainLooper()).postDelayed({
                                isSettingVolume = false
                            }, 100)
                            
                            previousVolume // Keep previous volume
                        } else {
                            // Update previous volume for next comparison
                            val newPrevious = currentVolume
                            previousVolume = newPrevious
                            currentVolume // Use current volume
                        }
                        
                        // Send event to JavaScript
                        val ret = JSObject().apply {
                            put("direction", direction)
                            put("level", finalVolume)
                        }
                        
                        Log.d(TAG, "VolumeObserver - Notifying listeners: direction=$direction, level=$finalVolume")
                        notifyListeners("volumeChanged", ret)
                    }
                }
            } catch (e: Exception) {
                Log.e(TAG, "VolumeObserver - Error processing volume change", e)
            }
        }
    }
}