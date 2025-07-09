package com.yourcompany.plugins.volumecontrol

import android.content.Context
import android.media.AudioManager
import android.view.KeyEvent
import android.view.View
import com.getcapacitor.JSObject
import com.getcapacitor.Plugin
import com.getcapacitor.PluginCall
import com.getcapacitor.PluginMethod
import com.getcapacitor.annotation.CapacitorPlugin

@CapacitorPlugin(name = "VolumeControl")
class VolumeControlPlugin : Plugin() {
    
    private lateinit var audioManager: AudioManager
    private var savedCall: PluginCall? = null
    private var isStarted = false
    private var suppressVolumeIndicator = false
    
    override fun load() {
        audioManager = context.getSystemService(Context.AUDIO_SERVICE) as AudioManager
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
            
            // Set volume with or without showing system UI
            val flags = if (suppressVolumeIndicator) {
                0 // No flags means no system UI
            } else {
                AudioManager.FLAG_SHOW_UI
            }
            
            audioManager.setStreamVolume(streamType, targetVolumeLevel, flags)
            
            val ret = JSObject()
            ret.put("value", value)
            call.resolve(ret)
            
        } catch (e: Exception) {
            call.reject("Failed to set volume level: ${e.message}")
        }
    }
    
    @PluginMethod(returnType = PluginMethod.RETURN_PROMISE)
    fun isWatching(call: PluginCall) {
        val ret = JSObject()
        ret.put("value", isStarted)
        call.resolve(ret)
    }
    
    @PluginMethod(returnType = PluginMethod.RETURN_CALLBACK)
    fun watchVolume(call: PluginCall) {
        if (isStarted) {
            call.reject("Volume buttons has already been watched")
            return
        }
        
        suppressVolumeIndicator = call.getBoolean("suppressVolumeIndicator", false) ?: false
        
        call.setKeepAlive(true)
        savedCall = call
        
        bridge.webView.setOnKeyListener(
            object : View.OnKeyListener {
                override fun onKey(v: View?, keyCode: Int, event: KeyEvent?): Boolean {
                    if (keyCode == KeyEvent.KEYCODE_VOLUME_UP || keyCode == KeyEvent.KEYCODE_VOLUME_DOWN) {
                        val isKeyUp = event?.action == KeyEvent.ACTION_UP
                        if (isKeyUp) {
                            val ret = JSObject()
                            ret.put("direction", if (keyCode == KeyEvent.KEYCODE_VOLUME_UP) "up" else "down")
                            call.resolve(ret)
                        }
                        // Return suppressVolumeIndicator value for volume buttons event actions only
                        // When suppressVolumeIndicator is true, the system volume indicator will not be displayed
                        return suppressVolumeIndicator
                    }
                    return false
                }
            }
        )
        
        isStarted = true
    }
    
    @PluginMethod(returnType = PluginMethod.RETURN_PROMISE)
    fun clearWatch(call: PluginCall) {
        if (!isStarted) {
            call.reject("Volume buttons has not been watched")
            return
        }
        
        bridge.webView.setOnKeyListener(null)
        
        if (savedCall != null) {
            bridge.releaseCall(savedCall!!)
            savedCall = null
        }
        
        isStarted = false
        call.resolve()
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
}