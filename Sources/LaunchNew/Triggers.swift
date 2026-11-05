import AppKit
import ApplicationServices
import ServiceManagement

/// Open at login, through the system's login items.
enum LoginItem {
    static var isEnabled: Bool { SMAppService.mainApp.status == .enabled }
    static var needsApproval: Bool { SMAppService.mainApp.status == .requiresApproval }

    static func set(_ enabled: Bool) {
        do {
            if enabled { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
        } catch {
            NSLog("LaunchNew: login item change failed: \(error)")
        }
    }
}

enum Permissions {
    /// Accessibility is needed to take over the F4 / Launchpad key.
    static var accessibility: Bool { AXIsProcessTrusted() }

    static func openTrackpadSettings() {
        open("x-apple.systempreferences:com.apple.Trackpad-Settings.extension")
    }

    private static func open(_ url: String) {
        if let url = URL(string: url) { NSWorkspace.shared.open(url) }
    }
}

/// Swallows the Launchpad key (F4 on Apple keyboards) and toggles the launcher instead.
/// Needs Accessibility, because it has to stop the key reaching the system.
final class LaunchpadKeyTap {
    private var tap: CFMachPort?
    private var source: CFRunLoopSource?
    private let action: @MainActor @Sendable () -> Void

    /// 131: the Launchpad key; 118: F4 when the keys act as standard function keys.
    private static let keyCodes: Set<Int64> = [131, 118]

    init?(action: @escaping @MainActor @Sendable () -> Void) {
        self.action = action
        guard Permissions.accessibility else { return nil }
        let mask = (1 << CGEventType.keyDown.rawValue) | (1 << CGEventType.keyUp.rawValue)
        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap, place: .headInsertEventTap, options: .defaultTap,
            eventsOfInterest: CGEventMask(mask),
            callback: { _, type, event, refcon in
                let me = Unmanaged<LaunchpadKeyTap>.fromOpaque(refcon!).takeUnretainedValue()
                return me.handle(type: type, event: event)
            },
            userInfo: Unmanaged.passUnretained(self).toOpaque()
        ) else { return nil }
        self.tap = tap
        source = CFMachPortCreateRunLoopSource(nil, tap, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
    }

    deinit {
        if let tap { CGEvent.tapEnable(tap: tap, enable: false) }
        if let source { CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes) }
    }

    private func handle(type: CGEventType, event: CGEvent) -> Unmanaged<CGEvent>? {
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            if let tap { CGEvent.tapEnable(tap: tap, enable: true) }
            return Unmanaged.passUnretained(event)
        }
        let code = event.getIntegerValueField(.keyboardEventKeycode)
        let flags = event.flags.intersection([.maskCommand, .maskAlternate, .maskControl, .maskShift])
        guard Self.keyCodes.contains(code), flags.isEmpty else { return Unmanaged.passUnretained(event) }
        if type == .keyDown, event.getIntegerValueField(.keyboardEventAutorepeat) == 0 {
            DispatchQueue.main.async { [action] in action() }
        }
        return nil
    }
}

/// Retains the active callback receiver while another thread replaces or invalidates it.
/// Only the reference is protected here; receivers still synchronize their mutable state.
final class LockedCallbackTarget<Target: AnyObject>: @unchecked Sendable {
    private let lock = NSLock()
    private var target: Target?

    func snapshot() -> Target? {
        lock.withLock { target }
    }

    func replace(with next: Target) {
        let previous = lock.withLock {
            let previous = target
            target = next
            return previous
        }
        // A receiver's deinit may stop a device and wait for its callback. Release it
        // outside the lock so that callback can finish taking its own snapshot.
        withExtendedLifetime(previous) {}
    }

    func clear(ifMatching receiver: Target) {
        let previous: Target? = lock.withLock {
            guard target === receiver else { return nil }
            let previous = target
            target = nil
            return previous
        }
        withExtendedLifetime(previous) {}
    }
}

/// Thumb-and-three-finger pinch on the trackpad, read from the private MultitouchSupport
/// framework (the public gesture events don't report four-finger pinches to other apps).
final class TrackpadPinch {
    private typealias Callback = @convention(c) (UnsafeMutableRawPointer?, UnsafeMutableRawPointer?, Int32, Double, Int32) -> Int32
    private typealias CreateList = @convention(c) () -> Unmanaged<CFArray>?
    private typealias Register = @convention(c) (UnsafeMutableRawPointer, Callback) -> Void
    private typealias Start = @convention(c) (UnsafeMutableRawPointer, Int32) -> Void
    private typealias Stop = @convention(c) (UnsafeMutableRawPointer) -> Void

    private static let current = LockedCallbackTarget<TrackpadPinch>()

    private let pinchIn: @MainActor @Sendable () -> Void
    private let pinchOut: @MainActor @Sendable () -> Void
    private var devices: [UnsafeMutableRawPointer] = []
    private var stop: Stop?

    /// One gesture in progress on one device: where each finger started.
    private struct Gesture {
        var start: [Int32: (Float, Float)] = [:]
        var fired = false
    }
    // Keyed by device, since every trackpad (and Magic Mouse) reports through the same callback.
    private var gestures: [UnsafeMutableRawPointer: Gesture] = [:]
    private let lock = NSLock()

    /// Fraction of the starting spread the fingers must close to (or open past) to count.
    static let inThreshold: Float = 0.75
    static let outThreshold: Float = 1.33

    init?(pinchIn: @escaping @MainActor @Sendable () -> Void, pinchOut: @escaping @MainActor @Sendable () -> Void) {
        self.pinchIn = pinchIn
        self.pinchOut = pinchOut
        guard let handle = dlopen("/System/Library/PrivateFrameworks/MultitouchSupport.framework/MultitouchSupport", RTLD_NOW),
              let createSym = dlsym(handle, "MTDeviceCreateList"),
              let registerSym = dlsym(handle, "MTRegisterContactFrameCallback"),
              let startSym = dlsym(handle, "MTDeviceStart"),
              let stopSym = dlsym(handle, "MTDeviceStop") else { return nil }
        let createList = unsafeBitCast(createSym, to: CreateList.self)
        let register = unsafeBitCast(registerSym, to: Register.self)
        let start = unsafeBitCast(startSym, to: Start.self)
        stop = unsafeBitCast(stopSym, to: Stop.self)
        guard let list = createList()?.takeRetainedValue() as? [AnyObject], !list.isEmpty else { return nil }

        TrackpadPinch.current.replace(with: self)
        for device in list {
            let ptr = Unmanaged.passRetained(device).toOpaque()
            devices.append(ptr)
            register(ptr, { device, data, count, _, _ in
                TrackpadPinch.current.snapshot()?.frame(device, data, count: Int(count))
                return 0
            })
            start(ptr, 0)
        }
    }

    deinit {
        for ptr in devices {
            stop?(ptr)
            Unmanaged<AnyObject>.fromOpaque(ptr).release()
        }
    }

    func invalidate() {
        TrackpadPinch.current.clear(ifMatching: self)
    }

    /// Finger records are 96 bytes: the contact's identifier is an Int32 at offset 16, its
    /// normalised position two floats at offset 32.
    private func frame(_ device: UnsafeMutableRawPointer?, _ data: UnsafeMutableRawPointer?, count: Int) {
        let key = device ?? UnsafeMutableRawPointer(bitPattern: 1)!
        var fingers: [Int32: (Float, Float)] = [:]
        if let data {
            for i in 0..<count {
                let base = data + i * 96
                fingers[base.load(fromByteOffset: 16, as: Int32.self)] =
                    (base.load(fromByteOffset: 32, as: Float.self), base.load(fromByteOffset: 36, as: Float.self))
            }
        }
        lock.lock()
        defer { lock.unlock() }
        guard fingers.count >= 2 else { gestures[key] = nil; return }
        var gesture = gestures[key] ?? Gesture()
        defer { gestures[key] = gesture }
        // Fingers land one after another: start over each time a new one arrives, so the
        // starting spread is the whole hand's. Fingers lifting part-way keep the start.
        if fingers.keys.contains(where: { gesture.start[$0] == nil }) {
            gesture.start = fingers
            return
        }
        guard !gesture.fired else { return }
        let ids = fingers.keys.filter { gesture.start[$0] != nil }
        guard ids.count >= 4 else { return }
        let before = Self.spread(ids.map { gesture.start[$0]! })
        let now = Self.spread(ids.map { fingers[$0]! })
        guard before > 0.02 else { return }
        if now < before * Self.inThreshold {
            gesture.fired = true
            DispatchQueue.main.async { [pinchIn] in pinchIn() }
        } else if now > before * Self.outThreshold {
            gesture.fired = true
            DispatchQueue.main.async { [pinchOut] in pinchOut() }
        }
    }

    /// Mean distance of the points from their centre.
    static func spread(_ points: [(Float, Float)]) -> Float {
        let cx = points.map(\.0).reduce(0, +) / Float(points.count)
        let cy = points.map(\.1).reduce(0, +) / Float(points.count)
        return points.map { hypotf($0.0 - cx, $0.1 - cy) }.reduce(0, +) / Float(points.count)
    }
}

/// Toggles the launcher when the pointer is pushed into a screen corner.
/// Driven by mouse-move events, so it costs nothing while the pointer is still.
@MainActor
final class HotCornerWatcher {
    private var monitors: [Any] = []
    private var dwell: DispatchWorkItem?
    private var armed = true
    var corner: HotCorner = .off { didSet { update() } }
    private let action: () -> Void

    init(action: @escaping () -> Void) {
        self.action = action
    }

    private func update() {
        monitors.forEach(NSEvent.removeMonitor)
        monitors = []
        dwell?.cancel()
        guard corner != .off else { return }
        // Global events come from other apps; the local monitor covers the launcher itself.
        if let m = NSEvent.addGlobalMonitorForEvents(matching: .mouseMoved, handler: { [weak self] _ in
            MainActor.assumeIsolated { self?.check() }
        }) { monitors.append(m) }
        if let m = NSEvent.addLocalMonitorForEvents(matching: .mouseMoved, handler: { [weak self] event in
            self?.check()
            return event
        }) { monitors.append(m) }
    }

    /// Distance from the pointer to the watched corner of the screen it's on.
    private func distance() -> CGFloat {
        let p = NSEvent.mouseLocation
        guard let screen = NSScreen.screens.first(where: { NSMouseInRect(p, $0.frame, false) }) else { return .infinity }
        let f = screen.frame
        let target: CGPoint = switch corner {
        case .topLeft: CGPoint(x: f.minX, y: f.maxY)
        case .topRight: CGPoint(x: f.maxX, y: f.maxY)
        case .bottomLeft: CGPoint(x: f.minX, y: f.minY)
        case .bottomRight: CGPoint(x: f.maxX, y: f.minY)
        case .off: CGPoint(x: CGFloat.infinity, y: .infinity)
        }
        return max(abs(p.x - target.x), abs(p.y - target.y))
    }

    private func check() {
        let d = distance()
        if d <= 2 {
            guard armed, dwell == nil else { return }
            // A short dwell, so flicking across the corner doesn't trigger it.
            let work = DispatchWorkItem { [weak self] in
                guard let self else { return }
                self.dwell = nil
                if self.armed, self.distance() <= 2 {
                    self.armed = false
                    self.action()
                }
            }
            dwell = work
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.12, execute: work)
        } else {
            dwell?.cancel()
            dwell = nil
            if d > 30 { armed = true }
        }
    }
}
