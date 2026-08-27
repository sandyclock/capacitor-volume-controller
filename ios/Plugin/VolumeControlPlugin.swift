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
        do {
            // Always get fresh volume from audio session and round to 2 decimals
            let volume = AVAudioSession.sharedInstance().outputVolume
            let roundedVolume = round(volume * 100) / 100
            call.resolve(["value": roundedVolume])
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
        
        do {
            try setVolume(value)
            // Return the rounded value after setting
            let roundedValue = round(value * 100) / 100
            call.resolve(["value": roundedValue])
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

        volumeHandler.handlerBlock = { [weak self] direction in
            guard let self = self else { return }
            let volume = AVAudioSession.sharedInstance().outputVolume
            let rounded = round(volume * 100) / 100

            var pressed = JSObject()
            pressed["direction"] = direction
            pressed["value"] = rounded
            self.notifyListeners("volumeButtonPressed", data: pressed)

            var changed = JSObject()
            changed["value"] = rounded
            changed["direction"] = direction
            self.notifyListeners("volumeLevelChanged", data: changed)
        }

        // 🔴 FORK CHANGE -- resolve ONCE. This used to set `call.keepAlive = true`, stash the
        // callbackId, and re-resolve the SAME PluginCall on every press, never resolving the
        // initial call at all.
        //
        // That silently broke the moment this package adopted upstream's 2.0.x TypeScript
        // contract, which types `watchVolume(options): Promise<void>` with no callback: the
        // promise would never settle, so `await watchVolume({})` hung forever, and because
        // nothing ever called notifyListeners, `addListener('volumeButtonPressed')` received
        // nothing either. Android and web were migrated; iOS was missed.
        //
        // Presses now go out as EVENTS, matching Android, web, and upstream.
        call.resolve()
    }
    
    @objc func clearWatch(_ call: CAPPluginCall) {
        guard volumeHandler.isStarted else {
            call.reject("Volume buttons has not been watched")
            return
        }
        
        // 🔴 FORK CHANGE -- previously the stop was nested inside `if let id = savedCallID`,
        // so a nil id meant the handler was never stopped AND the call never resolved: the
        // JS promise hung. With no saved call to release, stop unconditionally and resolve.
        volumeHandler.stopHandler()
        volumeHandler.handlerBlock = nil
        call.resolve()
    }
    
    /// Explicit override for parity with upstream 2.0.x. `CAPPlugin` supplies a default,
    /// but upstream declares it and the ObjC bridge is clearer for having it named.
    @objc override public func removeAllListeners(_ call: CAPPluginCall) {
        super.removeAllListeners(call)
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
        // 🔴 FORK CHANGE -- upstream (and capacitor-community/volume-buttons, which upstream
        // copied) hardcode `.playback` here. That is OUTPUT-ONLY, and WebKit REFUSES
        // getUserMedia while the session sits in a playback category: calling watchVolume()
        // during a live microphone session KILLS THE MIC. This plugin only needs to OBSERVE
        // `outputVolume`; it has no business owning the route.
        //
        // `.ambient` is the least invasive category that still permits observation: it is
        // non-mixing-hostile, respects the silent switch, and -- critically -- does not
        // tear down an existing recording route the way `.playback` does.
        sessionCategory = AVAudioSession.Category.ambient.rawValue
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
        volumeView?.isHidden = false
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
            // 🔴 FORK CHANGE -- upstream calls `setActive(true)` here. Activating the shared
            // session from a volume OBSERVER can interrupt whoever currently owns the route.
            // KVO on `outputVolume` does not require an active session, so we do not take it.
            // (Upstream 2.0.x went further and added setActive(true) to getVolumeLevel too --
            // deliberately not adopted.)
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