import Foundation
import Capacitor
import AVFoundation
import MediaPlayer

/**
 * Please read the Capacitor iOS Plugin Development Guide
 * here: https://capacitorjs.com/docs/plugins/ios
 */
@objc(VolumeControlPlugin)
public class VolumeControlPlugin: CAPPlugin {
    
    private var volumeView: MPVolumeView?
    private var volumeSlider: UISlider?
    private var isWatching = false
    private var disableSystemVolumeHandler = false
    private var previousVolume: Float = 0.5
    private var volumeObserver: NSObjectProtocol?
    private var isSettingVolume = false
    private var targetVolume: Float = -1
    
    public override func load() {
        setupAudioSession()
        setupVolumeView()
        // Initialize previous volume
        previousVolume = AVAudioSession.sharedInstance().outputVolume
    }
    
    deinit {
        clearVolumeObserver()
    }
    
    @objc func getVolumeLevel(_ call: CAPPluginCall) {
        let volumeType = call.getString("type") ?? "music"
        
        do {
            let volume = try getCurrentVolume(for: volumeType)
            call.resolve(["value": volume])
        } catch {
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
            // Set flag to prevent observer from triggering during programmatic changes
            isSettingVolume = true
            targetVolume = value
            
            try setVolume(value, for: volumeType)
            
            // Reset flag after a short delay
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                self.isSettingVolume = false
                self.targetVolume = -1
            }
            
            call.resolve(["value": value])
        } catch {
            isSettingVolume = false
            targetVolume = -1
            call.reject("Failed to set volume level: \(error.localizedDescription)")
        }
    }
    
    @objc func watchVolume(_ call: CAPPluginCall) {
        guard !isWatching else {
            call.reject("Volume watching is already active")
            return
        }
        
        disableSystemVolumeHandler = call.getBool("disableSystemVolumeHandler") ?? false
        
        print("VolumeControl: Starting volume watching with disableSystemVolumeHandler: \(disableSystemVolumeHandler)")
        
        do {
            try startVolumeWatching()
            call.resolve()
        } catch {
            call.reject("Failed to start volume watching: \(error.localizedDescription)")
        }
    }
    
    @objc func clearWatch(_ call: CAPPluginCall) {
        stopVolumeWatching()
        call.resolve()
    }
    
    @objc func isWatching(_ call: CAPPluginCall) {
        call.resolve(["value": isWatching])
    }
    
    // MARK: - Private Methods
    
    private func setupAudioSession() {
        do {
            let audioSession = AVAudioSession.sharedInstance()
            try audioSession.setCategory(.playback, mode: .default, options: [.mixWithOthers])
            try audioSession.setActive(true)
            print("VolumeControl: Audio session setup successful")
        } catch {
            print("VolumeControl: Failed to setup audio session: \(error)")
        }
    }
    
    private func setupVolumeView() {
        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            
            self.volumeView = MPVolumeView(frame: CGRect(x: -2000, y: -2000, width: 1, height: 1))
            
            if let volumeView = self.volumeView {
                // Add to a view that exists
                if let webView = self.bridge?.webView {
                    webView.addSubview(volumeView)
                }
                
                volumeView.isHidden = true
                volumeView.showsVolumeSlider = true
                volumeView.showsRouteButton = false
                volumeView.alpha = 0.01
                
                // Find the volume slider with multiple attempts
                self.findVolumeSlider(attempts: 0)
            }
        }
    }
    
    private func findVolumeSlider(attempts: Int) {
        guard let volumeView = volumeView, attempts < 10 else { 
            print("VolumeControl: Failed to find volume slider after \(attempts) attempts")
            return 
        }
        
        for view in volumeView.subviews {
            if let slider = view as? UISlider {
                volumeSlider = slider
                print("VolumeControl: Volume slider found after \(attempts + 1) attempts")
                return
            }
        }
        
        // If not found, try again after a short delay
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
            self.findVolumeSlider(attempts: attempts + 1)
        }
    }
    
    private func getCurrentVolume(for volumeType: String) throws -> Float {
        let audioSession = AVAudioSession.sharedInstance()
        return audioSession.outputVolume
    }
    
    private func setVolume(_ volume: Float, for volumeType: String) throws {
        guard let volumeSlider = volumeSlider else {
            throw NSError(domain: "VolumeControl", code: 1, userInfo: [NSLocalizedDescriptionKey: "Volume slider not available"])
        }
        
        DispatchQueue.main.async {
            volumeSlider.setValue(volume, animated: false)
            volumeSlider.sendActions(for: .touchUpInside)
        }
    }
    
    private func startVolumeWatching() throws {
        // Initialize previous volume
        previousVolume = AVAudioSession.sharedInstance().outputVolume
        print("VolumeControl: Initial volume: \(previousVolume)")
        
        // Set up volume observation
        volumeObserver = NotificationCenter.default.addObserver(
            forName: AVAudioSession.systemVolumeDidChangeNotification,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            self?.handleVolumeChange(notification)
        }
        
        isWatching = true
        
        // If disableSystemVolumeHandler is true, we need to intercept volume changes
        if disableSystemVolumeHandler {
            setupVolumeButtonInterception()
        }
        
        print("VolumeControl: Volume watching started successfully")
    }
    
    private func stopVolumeWatching() {
        clearVolumeObserver()
        isWatching = false
        disableSystemVolumeHandler = false
        isSettingVolume = false
        targetVolume = -1
        
        // Restore system volume behavior
        restoreSystemVolume()
        
        print("VolumeControl: Volume watching stopped")
    }
    
    private func clearVolumeObserver() {
        if let observer = volumeObserver {
            NotificationCenter.default.removeObserver(observer)
            volumeObserver = nil
            print("VolumeControl: Volume observer removed")
        }
    }
    
    private func setupVolumeButtonInterception() {
        DispatchQueue.main.async { [weak self] in
            guard let self = self, let volumeView = self.volumeView else { return }
            volumeView.isHidden = false
            volumeView.alpha = 0.001 // Very low but not zero
            volumeView.frame = CGRect(x: -2000, y: -2000, width: 1, height: 1)
            print("VolumeControl: Volume button interception enabled")
        }
    }
    
    private func restoreSystemVolume() {
        DispatchQueue.main.async { [weak self] in
            guard let self = self, let volumeView = self.volumeView else { return }
            volumeView.isHidden = true
            volumeView.alpha = 0.01
            print("VolumeControl: System volume behavior restored")
        }
    }
    
    private func handleVolumeChange(_ notification: Notification) {
        // Skip if we're currently setting volume programmatically
        if isSettingVolume {
            print("VolumeControl: Skipping volume change - programmatic change in progress")
            return
        }
        
        guard let userInfo = notification.userInfo,
              let newVolumeNumber = userInfo["AVSystemController_AudioVolumeNotificationParameter"] as? NSNumber else {
            print("VolumeControl: Could not extract volume from notification")
            return
        }
        
        let newVolume = newVolumeNumber.floatValue
        let direction: String
        
        print("VolumeControl: Volume changed from \(previousVolume) to \(newVolume)")
        
        if newVolume > previousVolume {
            direction = "up"
        } else if newVolume < previousVolume {
            direction = "down"
        } else {
            print("VolumeControl: No volume change detected")
            return // No change
        }
        
        // If we're intercepting system volume changes, reset the system volume
        if disableSystemVolumeHandler && volumeSlider != nil {
            print("VolumeControl: Intercepting volume change - resetting to previous volume")
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.01) { [weak self] in
                self?.resetSystemVolume()
            }
        } else {
            // Update our reference if not intercepting
            previousVolume = newVolume
        }
        
        // Notify JavaScript layer
        let data: [String: Any] = [
            "direction": direction,
            "level": newVolume
        ]
        
        print("VolumeControl: Notifying JS layer - direction: \(direction), level: \(newVolume)")
        notifyListeners("volumeChanged", data: data)
    }
    
    private func resetSystemVolume() {
        guard let volumeSlider = volumeSlider else { 
            print("VolumeControl: Cannot reset volume - slider not available")
            return 
        }
        
        isSettingVolume = true
        
        var resetVolume = previousVolume
        
        // Ensure we don't reset to extreme values
        if resetVolume < 0.05 {
            resetVolume = 0.05
        } else if resetVolume > 0.95 {
            resetVolume = 0.95
        }
        
        volumeSlider.setValue(resetVolume, animated: false)
        volumeSlider.sendActions(for: .touchUpInside)
        
        print("VolumeControl: Volume reset to \(resetVolume)")
        
        // Reset flag after a short delay
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
            self.isSettingVolume = false
        }
    }
}