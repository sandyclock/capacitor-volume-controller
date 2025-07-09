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
            try setVolume(value, for: volumeType)
            call.resolve(["value": value])
        } catch {
            call.reject("Failed to set volume level: \(error.localizedDescription)")
        }
    }
    
    @objc func watchVolume(_ call: CAPPluginCall) {
        guard !isWatching else {
            call.reject("Volume watching is already active")
            return
        }
        
        disableSystemVolumeHandler = call.getBool("disableSystemVolumeHandler") ?? false
        
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
            try audioSession.setCategory(.playback, mode: .default, options: [])
            try audioSession.setActive(true)
        } catch {
            print("Failed to setup audio session: \(error)")
        }
    }
    
    private func setupVolumeView() {
        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            
            self.volumeView = MPVolumeView(frame: CGRect(x: -1000, y: -1000, width: 100, height: 100))
            
            if let volumeView = self.volumeView {
                // Add to a view that exists
                if let webView = self.bridge?.webView {
                    webView.addSubview(volumeView)
                }
                
                volumeView.isHidden = true
                volumeView.showsVolumeSlider = true
                volumeView.showsRouteButton = false
                
                // Find the volume slider with a delay to ensure it's created
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                    self.findVolumeSlider()
                }
            }
        }
    }
    
    private func findVolumeSlider() {
        guard let volumeView = volumeView else { return }
        
        for view in volumeView.subviews {
            if let slider = view as? UISlider {
                volumeSlider = slider
                break
            }
        }
        
        // If not found, try again after a short delay
        if volumeSlider == nil {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                self.findVolumeSlider()
            }
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
    }
    
    private func stopVolumeWatching() {
        clearVolumeObserver()
        isWatching = false
        disableSystemVolumeHandler = false
        
        // Restore system volume behavior
        restoreSystemVolume()
    }
    
    private func clearVolumeObserver() {
        if let observer = volumeObserver {
            NotificationCenter.default.removeObserver(observer)
            volumeObserver = nil
        }
    }
    
    private func setupVolumeButtonInterception() {
        DispatchQueue.main.async { [weak self] in
            guard let self = self, let volumeView = self.volumeView else { return }
            volumeView.isHidden = false
            volumeView.alpha = 0.01
            volumeView.frame = CGRect(x: -1000, y: -1000, width: 100, height: 100)
        }
    }
    
    private func restoreSystemVolume() {
        DispatchQueue.main.async { [weak self] in
            guard let self = self, let volumeView = self.volumeView else { return }
            volumeView.isHidden = true
            volumeView.alpha = 1.0
        }
    }
    
    private func handleVolumeChange(_ notification: Notification) {
        guard let userInfo = notification.userInfo,
              let newVolumeNumber = userInfo["AVSystemController_AudioVolumeNotificationParameter"] as? NSNumber else {
            return
        }
        
        let newVolume = newVolumeNumber.floatValue
        let direction: String
        
        if newVolume > previousVolume {
            direction = "up"
        } else if newVolume < previousVolume {
            direction = "down"
        } else {
            return // No change
        }
        
        // If we're intercepting system volume changes, reset the system volume
        if disableSystemVolumeHandler && volumeSlider != nil {
            DispatchQueue.main.async { [weak self] in
                self?.resetSystemVolume()
            }
        }
        
        // Notify JavaScript layer
        let data: [String: Any] = [
            "direction": direction,
            "level": newVolume
        ]
        
        notifyListeners("volumeChanged", data: data)
        
        // Update our reference
        previousVolume = newVolume
    }
    
    private func resetSystemVolume() {
        guard let volumeSlider = volumeSlider else { return }
        
        var resetVolume = previousVolume
        
        // Ensure we don't reset to extreme values
        if resetVolume < 0.05 {
            resetVolume = 0.05
        } else if resetVolume > 0.95 {
            resetVolume = 0.95
        }
        
        volumeSlider.setValue(resetVolume, animated: false)
        volumeSlider.sendActions(for: .touchUpInside)
    }
}