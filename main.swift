// MicWarm: keeps a Bluetooth headset mic (AirPods etc.) open so dictation apps
// like Wispr Flow start instantly instead of waiting for the headset-mode switch.
// Audio is never read or stored: the IO callback is a no-op.
import Cocoa
import CoreAudio
import AVFoundation
import ServiceManagement

// MARK: - Core Audio helpers

func prop<T>(_ obj: AudioObjectID, _ sel: AudioObjectPropertySelector,
             _ scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal, _ fallback: T) -> T {
    var addr = AudioObjectPropertyAddress(mSelector: sel, mScope: scope, mElement: kAudioObjectPropertyElementMain)
    var value = fallback
    var size = UInt32(MemoryLayout<T>.size)
    return AudioObjectGetPropertyData(obj, &addr, 0, nil, &size, &value) == noErr ? value : fallback
}

func allDevices() -> [AudioDeviceID] {
    var addr = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDevices,
                                          mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
    var size: UInt32 = 0
    guard AudioObjectGetPropertyDataSize(AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size) == noErr else { return [] }
    var ids = [AudioDeviceID](repeating: 0, count: Int(size) / MemoryLayout<AudioDeviceID>.size)
    guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size, &ids) == noErr else { return [] }
    return ids
}

func hasInput(_ dev: AudioDeviceID) -> Bool {
    var addr = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyStreams,
                                          mScope: kAudioObjectPropertyScopeInput, mElement: kAudioObjectPropertyElementMain)
    var size: UInt32 = 0
    return AudioObjectGetPropertyDataSize(dev, &addr, 0, nil, &size) == noErr && size > 0
}

func isBluetooth(_ dev: AudioDeviceID) -> Bool {
    let t: UInt32 = prop(dev, kAudioDevicePropertyTransportType, kAudioObjectPropertyScopeGlobal, 0)
    return t == kAudioDeviceTransportTypeBluetooth || t == kAudioDeviceTransportTypeBluetoothLE
}

func deviceName(_ dev: AudioDeviceID) -> String {
    var addr = AudioObjectPropertyAddress(mSelector: kAudioObjectPropertyName,
                                          mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
    var name: Unmanaged<CFString>?
    var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
    guard AudioObjectGetPropertyData(dev, &addr, 0, nil, &size, &name) == noErr, let n = name else { return "Unknown" }
    return n.takeRetainedValue() as String
}

/// The Bluetooth mic to keep warm: the default input if it is Bluetooth, else the first Bluetooth input.
func targetDevice() -> AudioDeviceID? {
    let def: AudioDeviceID = prop(AudioObjectID(kAudioObjectSystemObject), kAudioHardwarePropertyDefaultInputDevice,
                                  kAudioObjectPropertyScopeGlobal, 0)
    if def != 0, isBluetooth(def), hasInput(def) { return def }
    return allDevices().first { isBluetooth($0) && hasInput($0) }
}

// MARK: - Keepalive stream

final class Warmer {
    private(set) var device: AudioDeviceID = 0
    private var procID: AudioDeviceIOProcID?
    private var startedAt = Date()
    private var gotFirstCallback = false
    var onWarm: ((TimeInterval) -> Void)?

    var running: Bool { procID != nil }

    func start(_ dev: AudioDeviceID) {
        if running && dev == device { return }
        stop()
        startedAt = Date()
        gotFirstCallback = false
        var id: AudioDeviceIOProcID?
        let created = AudioDeviceCreateIOProcIDWithBlock(&id, dev, DispatchQueue.global(qos: .utility)) { [weak self] _, _, _, _, _ in
            // Samples are ignored. Only note when the mic first delivers audio.
            guard let self, !self.gotFirstCallback else { return }
            self.gotFirstCallback = true
            let elapsed = Date().timeIntervalSince(self.startedAt)
            DispatchQueue.main.async { self.onWarm?(elapsed) }
        }
        guard created == noErr, let id else { NSLog("MicWarm: create IOProc failed \(created)"); return }
        let started = AudioDeviceStart(dev, id)
        guard started == noErr else {
            NSLog("MicWarm: start failed \(started)")
            AudioDeviceDestroyIOProcID(dev, id)
            return
        }
        device = dev
        procID = id
        NSLog("MicWarm: holding \(deviceName(dev))")
    }

    func stop() {
        guard let id = procID else { return }
        AudioDeviceStop(device, id)
        AudioDeviceDestroyIOProcID(device, id)
        procID = nil
        NSLog("MicWarm: released \(deviceName(device))")
        device = 0
    }
}

// MARK: - App

final class App: NSObject, NSApplicationDelegate {
    let warmer = Warmer()
    var statusItem: NSStatusItem!
    var locked = false
    var asleep = false
    var lastWarmup: TimeInterval?
    var enabled: Bool {
        get { UserDefaults.standard.object(forKey: "enabled") as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: "enabled") }
    }

    func applicationDidFinishLaunching(_ n: Notification) {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        warmer.onWarm = { [weak self] t in self?.lastWarmup = t; self?.refreshMenu() }

        // Device list or default input changed: AirPods connected, disconnected, or switched.
        let sys = AudioObjectID(kAudioObjectSystemObject)
        for sel in [kAudioHardwarePropertyDevices, kAudioHardwarePropertyDefaultInputDevice] {
            var addr = AudioObjectPropertyAddress(mSelector: sel, mScope: kAudioObjectPropertyScopeGlobal,
                                                  mElement: kAudioObjectPropertyElementMain)
            AudioObjectAddPropertyListenerBlock(sys, &addr, .main) { [weak self] _, _ in
                // Give a freshly connected device a moment to settle.
                DispatchQueue.main.asyncAfter(deadline: .now() + 1) { self?.reevaluate() }
            }
        }

        // Release on sleep / display sleep / lock so the Mac can idle-sleep and AirPods rest.
        let ws = NSWorkspace.shared.notificationCenter
        ws.addObserver(forName: NSWorkspace.willSleepNotification, object: nil, queue: .main) { [weak self] _ in self?.asleep = true; self?.reevaluate() }
        ws.addObserver(forName: NSWorkspace.screensDidSleepNotification, object: nil, queue: .main) { [weak self] _ in self?.asleep = true; self?.reevaluate() }
        ws.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in self?.wake() }
        ws.addObserver(forName: NSWorkspace.screensDidWakeNotification, object: nil, queue: .main) { [weak self] _ in self?.wake() }
        let dnc = DistributedNotificationCenter.default()
        dnc.addObserver(forName: .init("com.apple.screenIsLocked"), object: nil, queue: .main) { [weak self] _ in self?.locked = true; self?.reevaluate() }
        dnc.addObserver(forName: .init("com.apple.screenIsUnlocked"), object: nil, queue: .main) { [weak self] _ in self?.locked = false; self?.reevaluate() }

        AVCaptureDevice.requestAccess(for: .audio) { _ in DispatchQueue.main.async { self.reevaluate() } }
        refreshMenu()
    }

    func wake() {
        asleep = false
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) { self.reevaluate() }
    }

    func reevaluate() {
        let authorized = AVCaptureDevice.authorizationStatus(for: .audio) == .authorized
        if enabled, authorized, !locked, !asleep, let dev = targetDevice() {
            warmer.start(dev)
        } else {
            warmer.stop()
        }
        refreshMenu()
    }

    func refreshMenu() {
        let warm = warmer.running
        statusItem.button?.image = NSImage(systemSymbolName: warm ? "mic.fill" : "mic.slash",
                                           accessibilityDescription: "MicWarm")
        let menu = NSMenu()
        let status: String
        if AVCaptureDevice.authorizationStatus(for: .audio) == .denied { status = "No mic permission (System Settings › Privacy)" }
        else if warm { status = "Warm: \(deviceName(warmer.device))" }
        else if !enabled { status = "Off" }
        else if locked || asleep { status = "Paused (locked/asleep)" }
        else { status = "Waiting for AirPods" }
        menu.addItem(withTitle: status, action: nil, keyEquivalent: "")
        if let t = lastWarmup { menu.addItem(withTitle: String(format: "Last mic wake-up: %.2fs", t), action: nil, keyEquivalent: "") }
        menu.addItem(.separator())
        let toggle = menu.addItem(withTitle: "Keep AirPods mic warm", action: #selector(toggleEnabled), keyEquivalent: "")
        toggle.state = enabled ? .on : .off
        let login = menu.addItem(withTitle: "Start at login", action: #selector(toggleLogin), keyEquivalent: "")
        login.state = SMAppService.mainApp.status == .enabled ? .on : .off
        menu.addItem(.separator())
        menu.addItem(withTitle: "Quit MicWarm", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        for item in menu.items where item.action != nil && item.action != #selector(NSApplication.terminate(_:)) { item.target = self }
        statusItem.menu = menu
    }

    @objc func toggleEnabled() { enabled.toggle(); reevaluate() }

    @objc func toggleLogin() {
        do {
            if SMAppService.mainApp.status == .enabled { try SMAppService.mainApp.unregister() }
            else { try SMAppService.mainApp.register() }
        } catch { NSLog("MicWarm: login item error \(error)") }
        refreshMenu()
    }

    func applicationWillTerminate(_ n: Notification) { warmer.stop() }
}

let app = NSApplication.shared
let delegate = App()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
