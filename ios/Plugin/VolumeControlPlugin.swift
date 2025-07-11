import Foundation
import Capacitor
import MediaPlayer
import AVFoundation
import AVFAudio

@objc(VolumeControlPlugin)
public class VolumeControlPlugin: CAPPlugin {
    
    private var savedCallID: String? = nil
    private var volumeHandler: VolumeControlHandler!
    private var currentTrackedVolume: Float = 0.0
    
    public override func load() {
        volumeHandler = VolumeControlHandler()
        volumeHandler.delegate = self
        // Initialize current tracked volume
        currentTrackedVolume = AVAudioSession.sharedInstance().outputVolume
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
        // Always return the current tracked volume for consistency
        let roundedVolume = round(currentTrackedVolume * 100) / 100
        call.resolve(["value": roundedVolume])
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
            // Update tracked volume immediately
            let roundedValue = round(value * 100) / 100
            currentTrackedVolume = roundedValue
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
        
        call.keepAlive = true
        savedCallID = call.callbackId
        
        volumeHandler.startHandler(disableSystemVolumeHandler)
    }
    
    @objc func clearWatch(_ call: CAPPluginCall) {
        guard volumeHandler.isStarted else {
            call.reject("Volume buttons has not been watched")
            return
        }
        
        if let id = savedCallID {
            volumeHandler.stopHandler()
            if let savedCall = bridge?.savedCall(withID: id) {
                bridge?.releaseCall(savedCall)
            }
            savedCallID = nil
            call.resolve()
        }
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

// MARK: - Volume Handler Delegate
extension VolumeControlPlugin: VolumeControlHandlerDelegate {
    func volumeChanged(to newVolume: Float, direction: String) {
        // Update tracked volume
        currentTrackedVolume = newVolume
        
        // Notify callback
        if let id = savedCallID, let savedCall = bridge?.savedCall(withID: id) {
            var jsObject = JSObject()
            jsObject["direction"] = direction
            jsObject["volume"] = round(newVolume * 100) / 100
            savedCall.resolve(jsObject)
        }
    }
}

// MARK: - Volume Control Handler Delegate
protocol VolumeControlHandlerDelegate: AnyObject {
    func volumeChanged(to newVolume: Float, direction: String)
}

// MARK: - Volume Control Handler
public class VolumeControlHandler: NSObject {
    
    private var initialVolume: CGFloat = 0.0
    private var session: AVAudioSession?
    private var volumeView: MPVolumeView?
    private var appIsActive = false
    private var disableSystemVolumeHandler = false
    private var isAdjustingVolume = false
    private var sessionOptions: AVAudioSession.CategoryOptions?
    private var sessionCategory: String = ""
    private var observation: NSKeyValueObservation? = nil
    private let tag = "VolumeControlHandler"
    
    static let maxVolume: CGFloat = 0.95
    static let minVolume: CGFloat = 0.05
    
    public var isStarted = false
    public weak var delegate: VolumeControlHandlerDelegate?
    
    public var volumeSlider: UISlider? {
        return volumeView?.subviews.first(where: { $0 is UISlider }) as? UISlider
    }
    
    override public init() {
        super.init()
        
        appIsActive = true
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
        setInitialVolume()
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
        self.observation?.invalidate()
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
            try session?.setActive(true)
        } catch {
            print("Error setupSession: \(error)")
        }
        
        // Use the new KVO observation API for better reliability
        observation = session?.observe(\.outputVolume, options: [.new, .old]) { [weak self] session, change in
            guard let self = self,
                  let newVolume = change.newValue,
                  let oldVolume = change.oldValue else {
                return
            }
            
            // Skip if app is not active
            if !self.appIsActive {
                return
            }
            
            // Skip our own adjustments
            if self.isAdjustingVolume {
                self.isAdjustingVolume = false
                return
            }
            
            let difference = abs(newVolume - oldVolume)
            
            // Only respond to meaningful changes
            if difference > 0.001 {
                let direction: String
                if newVolume > oldVolume {
                    direction = "up"
                } else {
                    direction = "down"
                }
                
                // Handle system volume reset if needed
                if !self.disableSystemVolumeHandler {
                    // Don't reset volume if default handling is enabled
                    self.delegate?.volumeChanged(to: newVolume, direction: direction)
                } else {
                    // Reset volume and notify
                    self.setSystemVolume(self.initialVolume)
                    self.delegate?.volumeChanged(to: Float(self.initialVolume), direction: direction)
                }
            }
        }
        
        NotificationCenter.default.addObserver(self, selector: #selector(audioSessionInterruped(notification:)), name: AVAudioSession.interruptionNotification, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(applicationDidChangeActive(notification:)), name: UIApplication.willResignActiveNotification, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(applicationDidChangeActive(notification:)), name: UIApplication.didBecomeActiveNotification, object: nil)
        
        volumeView?.isHidden = !disableSystemVolumeHandler
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
        if let session = session {
            initialVolume = CGFloat(session.outputVolume)
        } else {
            initialVolume = CGFloat(AVAudioSession.sharedInstance().outputVolume)
        }
        
        if initialVolume > VolumeControlHandler.maxVolume {
            initialVolume = VolumeControlHandler.maxVolume
            setSystemVolume(initialVolume)
        } else if initialVolume < VolumeControlHandler.minVolume {
            initialVolume = VolumeControlHandler.minVolume
            setSystemVolume(initialVolume)
        }
    }
    
    @objc func applicationDidChangeActive(notification: NSNotification) {
        self.appIsActive = notification.name.rawValue == UIApplication.didBecomeActiveNotification.rawValue
        
        if appIsActive, isStarted {
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
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.01) {
            if let volumeView = self.volumeView, let volumeSlider = volumeView.subviews.first(where: { $0 is UISlider }) as? UISlider {
                self.isAdjustingVolume = true
                volumeSlider.value = Float(volume)
            }
        }
    }
}