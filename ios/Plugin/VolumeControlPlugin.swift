import Foundation
import Capacitor
import MediaPlayer
import AVFoundation
import AVFAudio

@objc(VolumeControlPlugin)
public class VolumeControlPlugin: CAPPlugin {
    
    private var volumeHandler: VolumeControlHandler!
    
    public override func load() {
        volumeHandler = VolumeControlHandler()
    }
    
    @objc func isWatching(_ call: CAPPluginCall) {
        guard volumeHandler != nil else {
            call.reject("Volume handler has not been initialized yet")
            return
        }
        
        call.resolve([
            "value": volumeHandler.isStarted
        ])
    }
    
    @objc func getVolumeLevel(_ call: CAPPluginCall) {
        if call.getString("type") == "voice_call" {
            readVoiceCallVolume(call)
            return
        }
        do {
            // FORK CHANGE -- upstream 2.0.3 calls `setActive(true)` here too. We do NOT, on
            // the narrower ground that a plain READ should not mutate global session state.
            // NOTE: while a capture route is live this read can return a STALE value
            // regardless -- do not treat getVolumeLevel as authoritative during an agent session.
            let volume = AVAudioSession.sharedInstance().outputVolume
            let roundedVolume = round(volume * 100) / 100
            call.resolve(["value": roundedVolume])
        } catch {
            call.reject("Failed to get volume level: \(error.localizedDescription)")
        }
    }
    
    /// FORK ADDITION -- `getVolumeLevel({ type: 'voice_call' })` on iOS.
    ///
    /// iOS keeps a separate volume for voice-call audio, which is what plays while any part of the
    /// app (a web view's getUserMedia included) records with voice processing. `outputVolume`
    /// reports it only while THIS app's own session is in that mode, so the read enters it briefly:
    /// playAndRecord / voiceChat, mixing with others, activate, wait for the value to settle, read,
    /// then deactivate and restore the previous category.
    ///
    /// 🔴 Call it only while nothing is recording. Measured on an iPad (iOS 18): re-configuring
    /// the session while a web view held the microphone took the microphone away from the page.
    private func readVoiceCallVolume(_ call: CAPPluginCall) {
        DispatchQueue.main.async {
            let session = AVAudioSession.sharedInstance()
            let category = session.category, mode = session.mode, options = session.categoryOptions
            let restore = {
                do { try session.setActive(false, options: .notifyOthersOnDeactivation) } catch { print("readVoiceCallVolume deactivate: \(error)") }
                do { try session.setCategory(category, mode: mode, options: options) } catch { print("readVoiceCallVolume restore: \(error)") }
            }
            do {
                try session.setCategory(.playAndRecord, mode: .voiceChat, options: [.mixWithOthers, .defaultToSpeaker])
                try session.setActive(true)
            } catch {
                restore()
                call.reject("Failed to read the voice-call volume: \(error.localizedDescription)")
                return
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                let volume = session.outputVolume
                restore()
                call.resolve(["value": round(volume * 100) / 100])
            }
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
        
        do {
            try setVolume(value)
            // Return the rounded value after setting
            let roundedValue = round(value * 100) / 100
            call.resolve(["value": roundedValue])

            // Emit an instant change event (KVO will also fire, but this makes it immediate)
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
                let v = AVAudioSession.sharedInstance().outputVolume
                let r = round(v * 100) / 100
                self.notifyListeners("volumeLevelChanged", data: ["value": r])
            }
        } catch {
            call.reject("Failed to set volume level: \(error.localizedDescription)")
        }
    }
    
    @objc func watchVolume(_ call: CAPPluginCall) {
        guard !volumeHandler.isStarted else {
            call.reject("Volume buttons has already been watched")
            return
        }
        
        let disableSystemVolumeHandler = call.getBool("disableSystemVolumeHandler", false)
        
        volumeHandler.startHandler(disableSystemVolumeHandler)
        
        let handlerBlock: VolumeButtonBlock = { [weak self] direction in
            // 🔴 FORK CHANGE -- upstream captures `self` strongly here (retain cycle).
            guard let self = self else { return }
            var jsObject = JSObject()
            jsObject["direction"] = direction
            let volume = AVAudioSession.sharedInstance().outputVolume
            let roundedVolume = round(volume * 100) / 100
            jsObject["value"] = roundedVolume

            // Back-compat event
            self.notifyListeners("volumeButtonPressed", data: jsObject)

            // New: always emit current volume instantly
            var changed = JSObject()
            changed["value"] = roundedVolume
            changed["direction"] = direction
            self.notifyListeners("volumeLevelChanged", data: changed)
        }
        volumeHandler.handlerBlock = handlerBlock
        
        call.resolve()
    }
    
    /// 🔑 FORK ADDITION -- Android-only concept, deliberately a no-op on iOS.
    ///
    /// iOS has no per-Activity volume-key routing: while a voice-processing session is open
    /// the hardware buttons already act on that route, which is exactly the behaviour Android
    /// needs `setVolumeControlStream` to emulate. Implemented as a resolving no-op so callers
    /// can invoke it unconditionally without platform branching.
    @objc func setVolumeControlStream(_ call: CAPPluginCall) {
        call.resolve()
    }

    /// 🔑 FORK ADDITION -- see `setVolumeControlStream`. No-op on iOS.
    @objc func clearVolumeControlStream(_ call: CAPPluginCall) {
        call.resolve()
    }

    /// 🔑 FORK ADDITION. The facts it reports are Android concepts; iOS answers with its
    /// platform and nulls so callers need no platform branching.
    @objc func getAudioEnvironment(_ call: CAPPluginCall) {
        call.resolve([
            "platform": "ios",
            "echoCancellerAvailable": NSNull(), "buildType": NSNull(), "manufacturer": NSNull(),
            "model": NSNull(), "audioMode": NSNull(), "musicMaxSteps": NSNull(), "voiceCallMaxSteps": NSNull()
        ])
    }

    @objc func clearWatch(_ call: CAPPluginCall) {
        guard volumeHandler.isStarted else {
            call.reject("Volume buttons has not been watched")
            return
        }
        
        volumeHandler.stopHandler()
        // 🔴 FORK CHANGE -- upstream leaves handlerBlock installed after a clear.
        volumeHandler.handlerBlock = nil
        call.resolve()
    }

    @objc override public func removeAllListeners(_ call: CAPPluginCall) {
        super.removeAllListeners(call)
    }
    
    // MARK: - Private Methods
    
    private func setVolume(_ volume: Float) throws {
        guard let volumeSlider = volumeHandler.volumeSlider else {
            throw NSError(domain: "VolumeControl", code: 1, userInfo: [NSLocalizedDescriptionKey: "Volume slider not available"])
        }
        
        DispatchQueue.main.async {
            volumeSlider.setValue(volume, animated: false)
            volumeSlider.sendActions(for: .touchUpInside)
        }
    }
}

// MARK: - Volume Control Handler

public typealias VolumeButtonBlock = (_ direction: String) -> Void

public class VolumeControlHandler: NSObject {
    
    private var initialVolume: CGFloat = 0.0
    private var session: AVAudioSession?
    private var volumeView: MPVolumeView?
    
    private var appIsActive = false
    
    private var disableSystemVolumeHandler = false
    private var isAdjustingVolume = false
    private var exactJumpsOnly: Bool = false
    
    private var sessionOptions: AVAudioSession.CategoryOptions?
    private var sessionCategory: String = ""
    
    private var observation: NSKeyValueObservation? = nil
    private let tag = "VolumeControlHandler"
    
    static let maxVolume: CGFloat = 0.95
    static let minVolume: CGFloat = 0.05
    
    public var handlerBlock: VolumeButtonBlock?
    public var currentVolume: Float = 0.0
    public var isStarted = false
    public var volumeSlider: UISlider? {
        return volumeView?.subviews.first(where: { $0 is UISlider }) as? UISlider
    }
    
    override public init() {
        appIsActive = true
        // Matches upstream. An earlier fork revision used `.ambient` on the theory that
        // `.playback` is output-only and would kill a live getUserMedia capture route.
        // 🔴 THAT WAS MEASURED FALSE (measured on an iPhone, iOS 26): under `.playback`
        // getUserMedia acquired the mic and it stayed `readyState=live muted=false`.
        // If this is ever changed back to `.ambient`, justify it by SILENT-SWITCH semantics
        // (`.ambient` obeys the mute switch, `.playback` plays through it) -- never by the mic.
        sessionCategory = AVAudioSession.Category.playback.rawValue
        sessionOptions = AVAudioSession.CategoryOptions.mixWithOthers
        
        volumeView = MPVolumeView(
            frame: CGRect(
                x: CGFloat.infinity,
                y: CGFloat.infinity,
                width: 0,
                height: 0
            )
        )
        
        if let window = UIApplication.shared.windows.first, let view = volumeView {
            window.insertSubview(view, at: 0)
        }
        
        volumeView?.isHidden = true
        exactJumpsOnly = false
    }
    
    deinit {
        stopHandler()
        
        if let volumeView = volumeView {
            DispatchQueue.main.async {
                volumeView.removeFromSuperview()
            }
        }
    }
    
    public func startHandler(_ disableSystemVolumeHandler: Bool) {
        self.setupSession()
        volumeView?.isHidden = false
        self.disableSystemVolumeHandler = disableSystemVolumeHandler
    }
    
    public func stopHandler() {
        guard isStarted else { return }
        isStarted = false
        volumeView?.isHidden = true
        self.observation = nil
        NotificationCenter.default.removeObserver(self)
    }
    
    @objc func setupSession() {
        guard !isStarted else { return }
        isStarted = true
        self.session = AVAudioSession.sharedInstance()
        setInitialVolume()
        do {
            try session?.setCategory(AVAudioSession.Category(rawValue: sessionCategory), options: sessionOptions!)
            // 🔴 REQUIRED -- do not remove. `outputVolume` KVO does NOT fire on an INACTIVE
            // session: with this line absent the observer never fires at all, and the feature
            // only appears to work after an accidental background->foreground cycle (which
            // activates the session via `applicationDidChangeActive`). Measured on device.
            // An earlier fork revision removed this to "protect the agent's mic route"; that
            // was backwards -- activation never threatened the mic; a LIVE MIC kills the
            // volume observation, which no amount of not-activating can fix.
            try session?.setActive(true)
        } catch {
            print("Error setupSession: \(error)")
        }
        
        observation = session?.observe(\.outputVolume, options: [.new, .old, .initial]) { [weak self] session, change in
            guard let newVolume = change.newValue,
                  let oldVolume = change.oldValue,
                  let self = self else {
                return
            }
            
            if !appIsActive {
                // NOTE: Probably control center, skip blocks
                debugPrint("app not active, skip")
                return
            }
            
            let difference = abs(newVolume - oldVolume)
            
            if isAdjustingVolume {
                isAdjustingVolume = false
                return
            }
            
            debugPrint("\(tag) Old Vol:%f New Vol:%f Difference = %f", oldVolume, newVolume, difference)
            
            if exactJumpsOnly && difference < 0.062 && (newVolume == 1.0 || newVolume == 0.0) {
                debugPrint("\(tag) Using a non-standard Jump of %f (%f-%f) which is less than the .0625 because a press of the volume button resulted in hitting min or max volume", difference, oldVolume, newVolume)
            } else if exactJumpsOnly && (difference > 0.063 || difference < 0.062) {
                debugPrint("\(tag) Ignoring non-standard Jump of %f (%f-%f), which is not the .0625 a press of the actually volume button would have resulted in.", difference, oldVolume, newVolume)
                setInitialVolume()
                return
            }
            
            var direction: String
            if newVolume == 1.0 || newVolume > oldVolume {
                direction = "up"
            } else {
                direction = "down"
            }
            currentVolume = newVolume
            
            if !disableSystemVolumeHandler {
                // NOTE: Don't reset volume if default handling is enabled
                handlerBlock?(direction)
                return
            }
            
            // NOTE: Reset volume
            setSystemVolume(initialVolume)
            handlerBlock?(direction)
        }
        
        NotificationCenter.default.addObserver(self, selector: #selector(audioSessionInterruped(notification:)), name: AVAudioSession.interruptionNotification, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(applicationDidChangeActive(notification:)), name: UIApplication.willResignActiveNotification, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(applicationDidChangeActive(notification:)), name: UIApplication.didBecomeActiveNotification, object: nil)
        
        volumeView?.isHidden = !disableSystemVolumeHandler
    }
    
    func useExactJumpsOnly(enabled: Bool) {
        exactJumpsOnly = enabled
    }
    
    @objc func audioSessionInterruped(notification: NSNotification) {
        guard let interruptionDict = notification.userInfo,
              let interruptionType = interruptionDict[AVAudioSessionInterruptionTypeKey] as? UInt else {
            return
        }
        switch AVAudioSession.InterruptionType(rawValue: interruptionType) {
        case .began:
            debugPrint("Audio Session Interruption case started")
        case .ended:
            print("Audio Session interruption case ended")
            do {
                try self.session?.setActive(true)
            } catch {
                print("Error: \(error)")
            }
        default:
            print("Audio Session Interruption Notification case default")
        }
    }
    
    public func setInitialVolume() {
        guard let session = session else { return }
        initialVolume = CGFloat(session.outputVolume)
        
        if initialVolume > VolumeControlHandler.maxVolume {
            initialVolume = VolumeControlHandler.maxVolume
            setSystemVolume(initialVolume)
        } else if initialVolume < VolumeControlHandler.minVolume {
            initialVolume = VolumeControlHandler.minVolume
            setSystemVolume(initialVolume)
        }
        currentVolume = Float(initialVolume)
    }
    
    @objc func applicationDidChangeActive(notification: NSNotification) {
        self.appIsActive = notification.name.rawValue == UIApplication.didBecomeActiveNotification.rawValue
        
        if appIsActive, isStarted {
            // NOTE: There is no guarantee that a begin interruption will have an end interruption
            // so, when the app returns from the background to foreground the audioSessionInterruped method might not be invoked
            // The below is a workaround to restart the session
            if let session = self.session {
                let isPlaying = session.isOtherAudioPlaying
                if !isPlaying {
                    do {
                        try session.setActive(true)
                    } catch {
                        print("Error: \(error)")
                    }
                }
            }
            setInitialVolume()
        }
    }
    
    func setSystemVolume(_ volume: CGFloat) {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
            if let volumeView = self.volumeView, let volumeSlider = volumeView.subviews.first(where: { $0 is UISlider }) as? UISlider {
                self.isAdjustingVolume = true
                volumeSlider.value = Float(volume)
            }
        }
    }
}