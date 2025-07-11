import Foundation
import Capacitor
import MediaPlayer
import AVFoundation
import AVFAudio

@objc(VolumeControlPlugin)
public class VolumeControlPlugin: CAPPlugin {
    
    private var volumeHandler: VolumeControlHandler?
    private var isWatching = false
    
    public override func load() {
        volumeHandler = VolumeControlHandler()
    }
    
    @objc func isWatching(_ call: CAPPluginCall) {
        call.resolve([
            "value": isWatching
        ])
    }
    
    @objc func getVolumeLevel(_ call: CAPPluginCall) {
        let volumeType = call.getString("type") ?? "music"
        
        do {
            let volume = try getCurrentVolume(for: volumeType)
            NSLog("VolumeControlPlugin - getVolumeLevel: %f for type: %@", volume, volumeType)
            call.resolve(["value": volume])
        } catch {
            NSLog("VolumeControlPlugin - Failed to get volume level: %@", error.localizedDescription)
            call.reject("Failed to get volume level: \(error.localizedDescription)")
        }
    }
    
    @objc func setVolumeLevel(_ call: CAPPluginCall) {
        guard let value = call.getFloat("value") else {
            call.reject("Missing required parameter: value")
            return
        }
        
        guard value >= 0.0 && value <= 1.0 else {
            call.reject("Volume value must be between 0.0 and 1.0")
            return
        }
        
        let volumeType = call.getString("type") ?? "music"
        
        do {
            try setVolume(value, for: volumeType)
            NSLog("VolumeControlPlugin - setVolumeLevel: %f for type: %@", value, volumeType)
            call.resolve(["value": value])
        } catch {
            NSLog("VolumeControlPlugin - Failed to set volume level: %@", error.localizedDescription)
            call.reject("Failed to set volume level: \(error.localizedDescription)")
        }
    }
    
    @objc func watchVolume(_ call: CAPPluginCall) {
        guard !isWatching else {
            call.reject("Volume buttons has already been watched")
            return
        }
        
        let disableSystemVolumeHandler = call.getBool("disableSystemVolumeHandler", false)
        
        NSLog("VolumeControlPlugin - watchVolume: disableSystemVolumeHandler=%@", disableSystemVolumeHandler ? "true" : "false")
        
        guard let handler = volumeHandler else {
            call.reject("Volume handler not initialized")
            return
        }
        
        // Set up the volume change callback
        handler.volumeChangeCallback = { [weak self] direction, level in
            NSLog("VolumeControlPlugin - Volume changed: %@ to level: %f", direction, level)
            
            let ret = JSObject()
            ret["direction"] = direction
            ret["level"] = level
            
            self?.notifyListeners("volumeChanged", data: ret)
        }
        
        do {
            try handler.startWatching(disableSystemVolumeHandler: disableSystemVolumeHandler)
            isWatching = true
            
            let ret = JSObject()
            ret["callbackId"] = "volume-watch-\(Date().timeIntervalSince1970)"
            call.resolve(ret)
            
        } catch {
            NSLog("VolumeControlPlugin - Failed to start watching: %@", error.localizedDescription)
            call.reject("Failed to start volume watching: \(error.localizedDescription)")
        }
    }
    
    @objc func clearWatch(_ call: CAPPluginCall) {
        guard isWatching else {
            call.reject("Volume buttons has not been watched")
            return
        }
        
        volumeHandler?.stopWatching()
        isWatching = false
        
        NSLog("VolumeControlPlugin - clearWatch: Volume watching stopped")
        call.resolve()
    }
    
    // MARK: - Private Methods
    
    private func getCurrentVolume(for volumeType: String) throws -> Float {
        let audioSession = AVAudioSession.sharedInstance()
        return audioSession.outputVolume
    }
    
    private func setVolume(_ volume: Float, for volumeType: String) throws {
        guard let handler = volumeHandler else {
            throw NSError(domain: "VolumeControl", code: 1, userInfo: [NSLocalizedDescriptionKey: "Volume handler not initialized"])
        }
        
        try handler.setVolume(volume)
    }
}

// MARK: - Volume Control Handler

public class VolumeControlHandler: NSObject {
    
    private var audioSession: AVAudioSession?
    private var volumeView: MPVolumeView?
    private var volumeSlider: UISlider?
    private var volumeObservation: NSKeyValueObservation?
    
    private var isWatchingVolume = false
    private var disableSystemVolumeHandler = false
    private var previousVolume: Float = 0.5
    private var isSettingVolume = false
    
    public var volumeChangeCallback: ((String, Float) -> Void)?
    
    override public init() {
        super.init()
        setupAudioSession()
        setupVolumeView()
    }
    
    deinit {
        stopWatching()
        volumeView?.removeFromSuperview()
    }
    
    private func setupAudioSession() {
        audioSession = AVAudioSession.sharedInstance()
        
        do {
            try audioSession?.setCategory(.playback, options: [.mixWithOthers])
            try audioSession?.setActive(true)
            
            // Get initial volume
            previousVolume = audioSession?.outputVolume ?? 0.5
            NSLog("VolumeControlHandler - Initial volume: %f", previousVolume)
            
        } catch {
            NSLog("VolumeControlHandler - Failed to setup audio session: %@", error.localizedDescription)
        }
    }
    
    private func setupVolumeView() {
        volumeView = MPVolumeView(frame: CGRect(x: -1000, y: -1000, width: 100, height: 100))
        volumeView?.isHidden = true
        volumeView?.alpha = 0.0
        
        if let window = UIApplication.shared.windows.first {
            window.addSubview(volumeView!)
        }
        
        // Find volume slider with retry logic
        findVolumeSlider()
    }
    
    private func findVolumeSlider() {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
            if let slider = self.volumeView?.subviews.first(where: { $0 is UISlider }) as? UISlider {
                self.volumeSlider = slider
                NSLog("VolumeControlHandler - Volume slider found")
            } else {
                NSLog("VolumeControlHandler - Volume slider not found, retrying...")
                // Retry after another delay
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                    if let slider = self.volumeView?.subviews.first(where: { $0 is UISlider }) as? UISlider {
                        self.volumeSlider = slider
                        NSLog("VolumeControlHandler - Volume slider found on retry")
                    } else {
                        NSLog("VolumeControlHandler - Volume slider still not found")
                    }
                }
            }
        }
    }
    
    public func startWatching(disableSystemVolumeHandler: Bool) throws {
        guard !isWatchingVolume else {
            throw NSError(domain: "VolumeControl", code: 2, userInfo: [NSLocalizedDescriptionKey: "Already watching volume"])
        }
        
        self.disableSystemVolumeHandler = disableSystemVolumeHandler
        
        // Show/hide volume view based on system handler setting
        volumeView?.isHidden = !disableSystemVolumeHandler
        
        // Update previous volume
        previousVolume = audioSession?.outputVolume ?? 0.5
        NSLog("VolumeControlHandler - Starting to watch volume, initial: %f, disableSystem: %@", previousVolume, disableSystemVolumeHandler ? "true" : "false")
        
        // Start observing volume changes
        volumeObservation = audioSession?.observe(\.outputVolume, options: [.new, .old]) { [weak self] session, change in
            self?.handleVolumeChange(change: change)
        }
        
        isWatchingVolume = true
    }
    
    public func stopWatching() {
        guard isWatchingVolume else { return }
        
        volumeObservation?.invalidate()
        volumeObservation = nil
        volumeView?.isHidden = true
        isWatchingVolume = false
        
        NSLog("VolumeControlHandler - Stopped watching volume")
    }
    
    public func setVolume(_ volume: Float) throws {
        guard let slider = volumeSlider else {
            throw NSError(domain: "VolumeControl", code: 3, userInfo: [NSLocalizedDescriptionKey: "Volume slider not available"])
        }
        
        isSettingVolume = true
        
        DispatchQueue.main.async {
            slider.setValue(volume, animated: false)
            slider.sendActions(for: .touchUpInside)
            
            // Reset flag after delay
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                self.isSettingVolume = false
            }
        }
        
        NSLog("VolumeControlHandler - Set volume to: %f", volume)
    }
    
    private func handleVolumeChange(change: NSKeyValueObservedChange<Float>) {
        guard let newVolume = change.newValue,
              let oldVolume = change.oldValue,
              !isSettingVolume else {
            return
        }
        
        // Only process significant changes
        let difference = abs(newVolume - oldVolume)
        guard difference > 0.001 else { return }
        
        let direction = newVolume > oldVolume ? "up" : "down"
        
        NSLog("VolumeControlHandler - Volume changed %@ from %f to %f (diff: %f)", direction, oldVolume, newVolume, difference)
        
        let finalVolume: Float
        
        if disableSystemVolumeHandler {
            // Reset to previous volume to prevent system volume change
            NSLog("VolumeControlHandler - Resetting volume to previous: %f", previousVolume)
            do {
                try setVolume(previousVolume)
                finalVolume = previousVolume
            } catch {
                NSLog("VolumeControlHandler - Failed to reset volume: %@", error.localizedDescription)
                finalVolume = newVolume
                previousVolume = newVolume
            }
        } else {
            // Allow system volume change
            previousVolume = newVolume
            finalVolume = newVolume
        }
        
        // Notify callback
        volumeChangeCallback?(direction, finalVolume)
    }
}