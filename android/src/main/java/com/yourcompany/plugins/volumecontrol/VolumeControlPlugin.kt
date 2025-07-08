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
    
    override fun load() {
        audioManager = context.getSystemService(Context.AUDIO_SERVICE) as AudioManager
    }
    
    @PluginMethod
    fun getVolumeLevel(call: PluginCall) {
        try {
            val volumeType = call.getString("type", "music")
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
            
            val volumeType = call.getString("type", "music")
            val streamType = mapVolumeTypeToStreamType(volumeType)
            
            val maxVolume = audioManager.getStreamMaxVolume(streamType)
            val targetVolume = (value * maxVolume).toInt()
            
            // Set volume with or without showing system UI
            val flags = if (suppressVolumeIndicator) {
                0 // No flags means no system UI
            } else {
                AudioManager.FLAG_SHOW_UI
            }
            
            audioManager.setStreamVolume(streamType, targetVolume, flags)
            
            val ret = JSObject()
            ret.put("value", value)
            call.resolve(ret)
            
        } catch (e: Exception) {
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
            
            // Start observing volume changes
            val handler = Handler(Looper.getMainLooper())
            volumeObserver = VolumeObserver(handler)
            
            val uri = Settings.System.getUriFor(Settings.System.VOLUME_MUSIC)
            context.contentResolver.registerContentObserver(uri, true, volumeObserver!!)
            
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
            }
            
            isWatching = false
            suppressVolumeIndicator = false
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
        private var previousVolume = -1
        
        override fun onChange(selfChange: Boolean, uri: Uri?) {
            super.onChange(selfChange, uri)
            
            try {
                val currentVolume = audioManager.getStreamVolume(AudioManager.STREAM_MUSIC)
                val maxVolume = audioManager.getStreamMaxVolume(AudioManager.STREAM_MUSIC)
                
                if (previousVolume != -1 && previousVolume != currentVolume) {
                    val direction = if (currentVolume > previousVolume) "up" else "down"
                    val normalizedLevel = if (maxVolume > 0) {
                        currentVolume.toFloat() / maxVolume.toFloat()
                    } else {
                        0.0f
                    }
                    
                    val ret = JSObject()
                    ret.put("direction", direction)
                    ret.put("level", normalizedLevel)
                    
                    notifyListeners("volumeChanged", ret)
                }
                
                previousVolume = currentVolume
                
            } catch (e: Exception) {
                // Handle error silently or log
            }
        }
        
        override fun onChange(selfChange: Boolean) {
            onChange(selfChange, null)
        }
    }
}