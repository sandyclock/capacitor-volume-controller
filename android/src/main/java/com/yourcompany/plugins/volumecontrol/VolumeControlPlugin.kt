package com.yourcompany.plugins.volumecontrol

import android.content.Context
import android.media.AudioManager
import android.view.KeyEvent
import com.getcapacitor.JSObject
import com.getcapacitor.Plugin
import com.getcapacitor.PluginCall
import com.getcapacitor.PluginMethod
import com.getcapacitor.annotation.CapacitorPlugin

@CapacitorPlugin(name = "VolumeControl")
class VolumeControlPlugin : Plugin() {
    private var audioManager: AudioManager? = null
    private var streamType = AudioManager.STREAM_MUSIC
    private var isStarted = false
    private var savedCall: PluginCall? = null
    private var suppressVolumeIndicator = false

    override fun load() {
        audioManager = context.getSystemService(Context.AUDIO_SERVICE) as AudioManager
    }

    @PluginMethod
    fun isWatching(call: PluginCall) {
        val ret = JSObject()
        ret.put("value", isStarted)
        call.resolve(ret)
    }

    @PluginMethod
    fun getVolumeLevel(call: PluginCall) {
        try {
            val maxVolume = audioManager?.getStreamMaxVolume(streamType) ?: 15
            val currentVolume = audioManager?.getStreamVolume(streamType) ?: 0
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
            val value = call.getFloat("value") ?: run {
                call.reject("Missing required parameter: value")
                return
            }

            if (value < 0f || value > 1f) {
                call.reject("Volume value must be between 0.0 and 1.0")
                return
            }

            val maxVolume = audioManager?.getStreamMaxVolume(streamType) ?: 15
            val targetVolume = (value * maxVolume).toInt()
            
            val flags = if (suppressVolumeIndicator) 0 else AudioManager.FLAG_SHOW_UI
            audioManager?.setStreamVolume(streamType, targetVolume, flags)
            
            val ret = JSObject()
            ret.put("value", value)
            call.resolve(ret)
        } catch (e: Exception) {
            call.reject("Failed to set volume level", e)
        }
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
        
        bridge.webView.setOnKeyListener { _, keyCode, event ->
            if (keyCode == KeyEvent.KEYCODE_VOLUME_UP || keyCode == KeyEvent.KEYCODE_VOLUME_DOWN) {
                if (event.action == KeyEvent.ACTION_UP) {
                    val ret = JSObject()
                    ret.put("direction", if (keyCode == KeyEvent.KEYCODE_VOLUME_UP) "up" else "down")
                    call.resolve(ret)
                }
                return@setOnKeyListener suppressVolumeIndicator
            }
            false
        }

        isStarted = true
    }

    @PluginMethod
    fun clearWatch(call: PluginCall) {
        if (!isStarted) {
            call.reject("Volume buttons has not been watched")
            return
        }

        bridge.webView.setOnKeyListener(null)
        savedCall?.let { bridge.releaseCall(it) }
        savedCall = null
        isStarted = false
        
        call.resolve()
    }
}