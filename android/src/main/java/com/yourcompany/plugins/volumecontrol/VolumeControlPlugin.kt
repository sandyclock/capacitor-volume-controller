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
            val streamType = getStreamType(call.data)
            val currentVolume = audioManager.getStreamVolume(streamType)
            val maxVolume = audioManager.getStreamMaxVolume(streamType)
            
            // Normalize volume to 0-1 range
            val normalizedVolume = currentVolume.toFloat() / maxVolume.toFloat()
            
            val ret = JSObject()
            ret.put("value", normalizedVolume)
            call.resolve(ret)
        } catch (e: Exception) {
            call.reject("Failed to get volume level", e)
        }
    }
    
    @PluginMethod
    fun setVolumeLevel(call: PluginCall) {
        try {
            val value = call.getFloat("value")
            if (value < 0 || value > 1) {
                call.reject("Volume value must be between 0 and 1")
                return
            }

            val streamType = getStreamType(call.data)
            val maxVolume = audioManager.getStreamMaxVolume(streamType)
            val targetVolumeLevel = (value * maxVolume).toInt()
            
            // Use 0 for flags to avoid showing the UI
            audioManager.setStreamVolume(streamType, targetVolumeLevel, 0)
            
            val ret = JSObject()
            ret.put("value", value)
            call.resolve(ret)
        } catch (e: Exception) {
            call.reject("Failed to set volume level", e)
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
    
    private fun getStreamType(data: JSObject): Int {
        val type = data.getString("type", "music")
        return when (type.toLowerCase()) {
            "music" -> AudioManager.STREAM_MUSIC
            "notification" -> AudioManager.STREAM_NOTIFICATION
            "system" -> AudioManager.STREAM_SYSTEM
            else -> AudioManager.STREAM_MUSIC
        }
    }
}