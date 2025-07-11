package com.yourcompany.plugins.volumecontrol

import android.content.Context
import android.database.ContentObserver
import android.media.AudioManager
import android.net.Uri
import android.os.Handler
import android.os.Looper
import android.provider.Settings
import android.view.KeyEvent
import android.view.View
import com.getcapacitor.JSObject
import com.getcapacitor.Plugin
import com.getcapacitor.PluginCall
import com.getcapacitor.PluginMethod
import com.getcapacitor.annotation.CapacitorPlugin
import kotlin.math.round

@CapacitorPlugin(name = "VolumeControl")
class VolumeControlPlugin : Plugin() {
    
    private lateinit var audioManager: AudioManager
    private var savedCall: PluginCall? = null
    private var isStarted = false
    private var suppressVolumeIndicator = false
    private var currentTrackedVolume: Float = 0f
    private var volumeContentObserver: VolumeContentObserver? = null
    
    override fun load() {
        audioManager = context.getSystemService(Context.AUDIO_SERVICE) as AudioManager
        // Initialize tracked volume
        currentTrackedVolume = getCurrentVolumeFromSystem()
    }
    
    private fun roundToTwoDecimals(value: Float): Float {
        return (round(value * 100f) / 100f).coerceIn(0f, 1f)
    }
    
    private fun getCurrentVolumeFromSystem(): Float {
        val streamType = AudioManager.STREAM_MUSIC
        val currentVolume = audioManager.getStreamVolume(streamType)
        val maxVolume = audioManager.getStreamMaxVolume(streamType)
        return roundToTwoDecimals(currentVolume.toFloat() / maxVolume.toFloat())
    }
    
    @PluginMethod
    fun getVolumeLevel(call: PluginCall) {
        try {
            // Always use the most current tracked volume for consistency
            val ret = JSObject()
            ret.put("value", currentTrackedVolume)
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

            val streamType = AudioManager.STREAM_MUSIC
            val maxVolume = audioManager.getStreamMaxVolume(streamType)
            val roundedValue = roundToTwoDecimals(value)
            val targetVolumeLevel = (roundedValue * maxVolume).toInt()
            
            // Use 0 for flags to avoid showing the UI
            audioManager.setStreamVolume(streamType, targetVolumeLevel, 0)
            
            // Update tracked volume immediately
            currentTrackedVolume = roundedValue
            
            val ret = JSObject()
            ret.put("value", roundedValue)
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
        
        suppressVolumeIndicator = call.getBoolean("suppressVolumeIndicator") ?: false
        
        call.setKeepAlive(true)
        savedCall = call
        
        // Start the proper volume content observer for real-time tracking
        startVolumeContentObserver()
        
        // Also monitor hardware key events
        bridge.webView.setOnKeyListener(
            object : View.OnKeyListener {
                override fun onKey(v: View?, keyCode: Int, event: KeyEvent?): Boolean {
                    if (keyCode == KeyEvent.KEYCODE_VOLUME_UP || keyCode == KeyEvent.KEYCODE_VOLUME_DOWN) {
                        val isKeyUp = event?.action == KeyEvent.ACTION_UP
                        if (isKeyUp) {
                            // The ContentObserver will handle the volume change notification
                            // This just suppresses the volume indicator if requested
                        }
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
        
        // Stop volume content observer
        stopVolumeContentObserver()
        
        bridge.webView.setOnKeyListener(null)
        
        if (savedCall != null) {
            bridge.releaseCall(savedCall!!)
            savedCall = null
        }
        
        isStarted = false
        call.resolve()
    }
    
    private fun startVolumeContentObserver() {
        if (volumeContentObserver == null) {
            volumeContentObserver = VolumeContentObserver(Handler(Looper.getMainLooper()))
            context.contentResolver.registerContentObserver(
                Settings.System.CONTENT_URI,
                true,
                volumeContentObserver!!
            )
        }
    }
    
    private fun stopVolumeContentObserver() {
        volumeContentObserver?.let {
            context.contentResolver.unregisterContentObserver(it)
            volumeContentObserver = null
        }
    }
    
    override fun handleOnDestroy() {
        stopVolumeContentObserver()
        super.handleOnDestroy()
    }
    
    private inner class VolumeContentObserver(handler: Handler) : ContentObserver(handler) {
        private var previousVolume = currentTrackedVolume
        
        override fun onChange(selfChange: Boolean, uri: Uri?) {
            super.onChange(selfChange, uri)
            
            // Get the fresh volume from the system
            val newVolume = getCurrentVolumeFromSystem()
            
            // Check if there's actually a change in volume
            if (kotlin.math.abs(newVolume - previousVolume) > 0.001f) {
                // Determine direction
                val direction = if (newVolume > previousVolume) "up" else "down"
                
                // Update tracked volume
                currentTrackedVolume = newVolume
                previousVolume = newVolume
                
                // Notify the callback
                savedCall?.let { call ->
                    val ret = JSObject()
                    ret.put("direction", direction)
                    ret.put("volume", currentTrackedVolume)
                    call.resolve(ret)
                }
            }
        }
        
        override fun deliverSelfNotifications(): Boolean {
            return true
        }
    }
}