package com.yourcompany.plugins.volumecontrol

import android.content.Context
import android.database.ContentObserver
import android.media.AudioManager
import android.net.Uri
import android.os.Handler
import android.os.Looper
import android.provider.Settings
import com.getcapacitor.JSObject
import com.getcapacitor.Plugin
import com.getcapacitor.PluginCall
import com.getcapacitor.PluginMethod
import com.getcapacitor.annotation.CapacitorPlugin

@CapacitorPlugin(name = "VolumeControl")
class VolumeControlPlugin : Plugin() {
    
    private lateinit var audioManager: AudioManager
    private var volumeObserver: VolumeObserver? = null
    private var isWatching = false
    private var suppressVolumeIndicator = false
    private var previousVolume = -1
    private var targetVolume = -1
    private var isSettingVolume = false
    
    override fun load() {
        audioManager = context.getSystemService(Context.AUDIO_SERVICE) as AudioManager
        // Initialize previous volume
        previousVolume = audioManager.getStreamVolume(AudioManager.STREAM_MUSIC)
    }
    
    @PluginMethod
    fun getVolumeLevel(call: PluginCall) {
        try {
            val volumeType = call.getString("type") ?: "music"
            val streamType = mapVolumeTypeToStreamType(volumeType)
            
            val currentVolume = audioManager.getStreamVolume(streamType)
            val maxVolume = audioManager.getStreamMaxVolume(streamType)
            
            val normalizedVolume = if (maxVolume > 0) {
                currentVolume.toFloat() / maxVolume.toFloat()
            } else {
                0.0f
            }
            
            val ret = JSObject()
            ret.put("value", normalizedVolume)
            call.resolve(ret)
            
        } catch (e: Exception) {
            call.reject("Failed to get volume level: ${e.message}")
        }
    }
    
    @PluginMethod
    fun setVolumeLevel(call: PluginCall) {
        try {
            val value = call.getFloat("value") ?: run {
                call.reject("Missing required parameter: value")
                return
            }
            
            if (value < 0.0f || value > 1.0f) {
                call.reject("Volume value must be between 0.0 and 1.0")
                return
            }
            
            val volumeType = call.getString("type") ?: "music"
            val streamType = mapVolumeTypeToStreamType(volumeType)
            
            val maxVolume = audioManager.getStreamMaxVolume(streamType)
            val targetVolumeLevel = (value * maxVolume).toInt()
            
            // Set flag to prevent observer from triggering during programmatic changes
            isSettingVolume = true
            targetVolume = targetVolumeLevel
            
            // Set volume with or without showing system UI
            val flags = if (suppressVolumeIndicator) {
                0 // No flags means no system UI
            } else {
                AudioManager.FLAG_SHOW_UI
            }
            
            audioManager.setStreamVolume(streamType, targetVolumeLevel, flags)
            
            // Reset flag after a short delay
            Handler(Looper.getMainLooper()).postDelayed({
                isSettingVolume = false
                targetVolume = -1
            }, 100)
            
            val ret = JSObject()
            ret.put("value", value)
            call.resolve(ret)
            
        } catch (e: Exception) {
            isSettingVolume = false
            targetVolume = -1
            call.reject("Failed to set volume level: ${e.message}")
        }
    }
    
    @PluginMethod
    fun watchVolume(call: PluginCall) {
        try {
            if (isWatching) {
                call.reject("Volume watching is already active")
                return
            }
            
            suppressVolumeIndicator = call.getBoolean("suppressVolumeIndicator", false) ?: false
            
            android.util.Log.d("VolumeControl", "Starting volume watching with suppressVolumeIndicator: $suppressVolumeIndicator")
            
            // Start observing volume changes
            val handler = Handler(Looper.getMainLooper())
            volumeObserver = VolumeObserver(handler)
            
            // Register observer for different volume types
            val volumeUris = listOf(
                "volume_music",
                "volume_ring", 
                "volume_notification",
                "volume_alarm",
                "volume_system"
            )
            
            var registeredCount = 0
            volumeUris.forEach { volumeKey ->
                try {
                    val uri = Settings.System.getUriFor(volumeKey)
                    context.contentResolver.registerContentObserver(uri, true, volumeObserver!!)
                    registeredCount++
                    android.util.Log.d("VolumeControl", "Registered observer for $volumeKey")
                } catch (e: Exception) {
                    // Some volume types might not be available on all devices
                    android.util.Log.w("VolumeControl", "Could not register observer for $volumeKey: ${e.message}")
                }
            }
            
            if (registeredCount == 0) {
                call.reject("Failed to register any volume observers")
                return
            }
            
            // Initialize previous volume
            previousVolume = audioManager.getStreamVolume(AudioManager.STREAM_MUSIC)
            
            isWatching = true
            call.resolve()
            
        } catch (e: Exception) {
            call.reject("Failed to start volume watching: ${e.message}")
        }
    }
    
    @PluginMethod
    fun clearWatch(call: PluginCall) {
        try {
            if (volumeObserver != null) {
                context.contentResolver.unregisterContentObserver(volumeObserver!!)
                volumeObserver = null
                android.util.Log.d("VolumeControl", "Volume observer unregistered")
            }
            
            isWatching = false
            suppressVolumeIndicator = false
            previousVolume = -1
            targetVolume = -1
            isSettingVolume = false
            call.resolve()
            
        } catch (e: Exception) {
            call.reject("Failed to clear volume watch: ${e.message}")
        }
    }
    
    @PluginMethod
    fun isWatching(call: PluginCall) {
        val ret = JSObject()
        ret.put("value", isWatching)
        call.resolve(ret)
    }
    
    private fun mapVolumeTypeToStreamType(volumeType: String): Int {
        return when (volumeType) {
            "voice_call" -> AudioManager.STREAM_VOICE_CALL
            "system" -> AudioManager.STREAM_SYSTEM
            "ring" -> AudioManager.STREAM_RING
            "music" -> AudioManager.STREAM_MUSIC
            "alarm" -> AudioManager.STREAM_ALARM
            "notification" -> AudioManager.STREAM_NOTIFICATION
            "dtmf" -> AudioManager.STREAM_DTMF
            else -> AudioManager.STREAM_MUSIC // default
        }
    }
    
    private inner class VolumeObserver(handler: Handler) : ContentObserver(handler) {
        
        override fun onChange(selfChange: Boolean, uri: Uri?) {
            super.onChange(selfChange, uri)
            
            // Skip if we're currently setting volume programmatically
            if (isSettingVolume) {
                android.util.Log.d("VolumeControl", "Skipping volume change - programmatic change in progress")
                return
            }
            
            try {
                // Get current volume for music stream (most commonly used)
                val currentVolume = audioManager.getStreamVolume(AudioManager.STREAM_MUSIC)
                val maxVolume = audioManager.getStreamMaxVolume(AudioManager.STREAM_MUSIC)
                
                android.util.Log.d("VolumeControl", "Volume changed: $previousVolume -> $currentVolume (max: $maxVolume)")
                
                // Only notify if volume actually changed and we have a valid previous volume
                if (previousVolume != -1 && previousVolume != currentVolume) {
                    val direction = if (currentVolume > previousVolume) "up" else "down"
                    val normalizedLevel = if (maxVolume > 0) {
                        currentVolume.toFloat() / maxVolume.toFloat()
                    } else {
                        0.0f
                    }
                    
                    android.util.Log.d("VolumeControl", "Notifying volume change: $direction, level: $normalizedLevel")
                    
                    val ret = JSObject()
                    ret.put("direction", direction)
                    ret.put("level", normalizedLevel)
                    
                    // If suppressVolumeIndicator is enabled, we need to handle the volume change
                    if (suppressVolumeIndicator) {
                        // Reset volume to previous level to suppress the change
                        Handler(Looper.getMainLooper()).postDelayed({
                            try {
                                isSettingVolume = true
                                audioManager.setStreamVolume(AudioManager.STREAM_MUSIC, previousVolume, 0)
                                
                                // Reset flag after setting
                                Handler(Looper.getMainLooper()).postDelayed({
                                    isSettingVolume = false
                                }, 50)
                                
                                android.util.Log.d("VolumeControl", "Volume suppressed - reset to previous level: $previousVolume")
                            } catch (e: Exception) {
                                android.util.Log.e("VolumeControl", "Failed to suppress volume: ${e.message}")
                                isSettingVolume = false
                            }
                        }, 10)
                    } else {
                        // Update previous volume if not suppressing
                        previousVolume = currentVolume
                    }
                    
                    // Notify JavaScript layer
                    notifyListeners("volumeChanged", ret)
                } else if (previousVolume == -1) {
                    // Initialize previous volume if not set
                    previousVolume = currentVolume
                    android.util.Log.d("VolumeControl", "Initialized previous volume: $previousVolume")
                }
                
            } catch (e: Exception) {
                // Log error but don't crash
                android.util.Log.e("VolumeControl", "Error in volume observer: ${e.message}")
            }
        }
        
        override fun onChange(selfChange: Boolean) {
            onChange(selfChange, null)
        }
    }
}