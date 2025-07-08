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
    private var initialSystemVolume: Float = 0.5
    private var volumeObserver: NSObjectProtocol?
    
    public override func load() {
        setupVolumeView()
        setupAudioSession()
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
    
    private func setupVolumeView() {
        DispatchQueue.main.async { [weak self] in
            self?.volumeView = MPVolumeView(frame: CGRect(x: -1000, y: -1000, width: 100, height: 100))
            
            if let volumeView = self?.volumeView {
                self?.bridge?.webView?.addSubview(volumeView)
                volumeView.isHidden = true
                
                // Find the volume slider
                for view in volumeView.subviews {
                    if let slider = view as? UISlider {
                        self?.volumeSlider = slider
                        break
                    }
                }
            }
        }
    }
    
    private func setupAudioSession() {
        do {
            try AVAudioSession.sharedInstance().setCategory(.playback, mode: .default)
            try AVAudioSession.sharedInstance().setActive(true)
        } catch {
            print("Failed to setup audio session: \(error)")
        }
    }
    
    private func getCurrentVolume(for volumeType: String) throws -> Float {
        let audioSession = AVAudioSession.sharedInstance()
        
        // iOS primarily uses system volume, but we can differentiate based on audio category
        switch volumeType {
        case "voice_call":
            // For voice calls, we'd typically use different audio category
            return audioSession.outputVolume
        default:
            return audioSession.outputVolume
        }
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
        guard let volumeSlider = volumeSlider else {
            throw NSError(domain: "VolumeControl", code: 1, userInfo: [NSLocalizedDescriptionKey: "Volume slider not available"])
        }
        
        initialSystemVolume = AVAudioSession.sharedInstance().outputVolume
        
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
        // This is a workaround to intercept volume button presses
        // We monitor volume changes and reset the system volume
        DispatchQueue.main.async { [weak self] in
            self?.volumeView?.isHidden = false
            self?.volumeView?.alpha = 0.01
        }
    }
    
    private func restoreSystemVolume() {
        DispatchQueue.main.async { [weak self] in
            self?.volumeView?.isHidden = true
            self?.volumeView?.alpha = 1.0
        }
    }
    
    private func handleVolumeChange(_ notification: Notification) {
        guard let userInfo = notification.userInfo,
              let volumeChangeType = userInfo["AVSystemController_AudioVolumeChangeReasonKey"] as? String,
              let newVolume = userInfo["AVSystemController_AudioVolumeNotificationParameter"] as? Float else {
            return
        }
        
        let previousVolume = initialSystemVolume
        let direction: String
        
        if newVolume > previousVolume {
            direction = "up"
        } else if newVolume < previousVolume {
            direction = "down"
        } else {
            return // No change
        }
        
        // If we're intercepting system volume changes, reset the system volume
        if disableSystemVolumeHandler {
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
        initialSystemVolume = newVolume
    }
    
    private func resetSystemVolume() {
        guard let volumeSlider = volumeSlider else { return }
        
        var resetVolume = initialSystemVolume
        
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