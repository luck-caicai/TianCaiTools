import CoreGraphics
import Foundation

/// No system calls: the event tap only interprets keys, then schedules UI work.
struct SwitcherKeyState {
    enum Action: Equatable { case begin(reverse: Bool), cycle(reverse: Bool), commit, cancel }
    struct Result { var consume = false; var action: Action? }
    static let tab: CGKeyCode = 48
    static let escape: CGKeyCode = 53
    var isEnabled = false
    private(set) var isSelecting = false
    private(set) var swallowedKeys = Set<CGKeyCode>()
    private var waitForOptionRelease = false

    mutating func handle(_ type: CGEventType, key: CGKeyCode, flags: CGEventFlags,
                         isRepeat: Bool = false, canBegin: Bool = true) -> Result {
        let option = flags.contains(.maskAlternate)
        let extra = !flags.intersection([.maskControl, .maskCommand, .maskSecondaryFn]).isEmpty
        if type == .keyUp {
            return Result(consume: swallowedKeys.remove(key) != nil)
        }
        if type == .flagsChanged {
            if !option {
                waitForOptionRelease = false
                if isSelecting { isSelecting = false; return Result(action: .commit) }
            } else if extra, isSelecting {
                isSelecting = false
                waitForOptionRelease = true
                return Result(action: .cancel)
            }
            return Result()
        }
        guard type == .keyDown else { return Result() }
        if key == Self.tab, option, !extra, isEnabled, !waitForOptionRelease {
            if isSelecting {
                swallowedKeys.insert(key)
                return Result(consume: true, action: .cycle(reverse: flags.contains(.maskShift)))
            }
            if !isRepeat, canBegin {
                swallowedKeys.insert(key)
                isSelecting = true
                return Result(consume: true, action: .begin(reverse: flags.contains(.maskShift)))
            }
        }
        // A consumed down must never leak repeats or an unmatched up to the foreground app.
        if swallowedKeys.contains(key) { return Result(consume: true) }
        if isSelecting {
            isSelecting = false
            waitForOptionRelease = option
            if key == Self.escape {
                swallowedKeys.insert(key)
                return Result(consume: true, action: .cancel)
            }
            return Result(action: .cancel)
        }
        return Result()
    }

    mutating func cancel() {
        if isSelecting || !swallowedKeys.isEmpty { waitForOptionRelease = true }
        isSelecting = false
    }

    mutating func reset() {
        isSelecting = false
        swallowedKeys.removeAll()
        waitForOptionRelease = false
    }
}

struct WindowSelection {
    private(set) var ids: [String]
    private(set) var index: Int
    var selectedID: String? { ids.indices.contains(index) ? ids[index] : nil }

    init(ids: [String], currentID: String?, reverse: Bool) {
        self.ids = ids
        if let currentID, let current = ids.firstIndex(of: currentID), !ids.isEmpty {
            index = (current + (reverse ? ids.count - 1 : 1)) % ids.count
        } else { index = reverse ? max(0, ids.count - 1) : 0 }
    }

    mutating func cycle(reverse: Bool) {
        guard !ids.isEmpty else { return }
        index = (index + (reverse ? ids.count - 1 : 1)) % ids.count
    }

    mutating func select(_ id: String) {
        if let next = ids.firstIndex(of: id) { index = next }
    }

    /// Keep the order frozen; a closed window must never change another window's identity.
    mutating func retain(_ live: Set<String>) {
        let previous = selectedID
        let oldIndex = index
        ids.removeAll { !live.contains($0) }
        index = previous.flatMap { ids.firstIndex(of: $0) } ?? min(oldIndex, max(0, ids.count - 1))
    }
}

struct WindowRecency {
    private var order: [String] = []
    mutating func focus(_ id: String) {
        order.removeAll { $0 == id }
        order.insert(id, at: 0)
    }
    mutating func retain(_ live: Set<String>) { order.removeAll { !live.contains($0) } }
    func sorted(_ ids: [String]) -> [String] {
        let live = Set(ids)
        let known = order.filter { live.contains($0) }
        let ranked = Set(known)
        return known + ids.filter { !ranked.contains($0) }
    }
}

/// The same decoded image is shared by this cache and visible card layers.
struct ImageBudget<Value> {
    private struct Entry { let value: Value; let cost: Int }
    let countLimit: Int
    let byteLimit: Int
    private var entries: [String: Entry] = [:]
    private var lru: [String] = []
    private(set) var bytes = 0
    var count: Int { entries.count }
    var keys: Set<String> { Set(entries.keys) }

    mutating func value(for key: String) -> Value? {
        guard let value = entries[key]?.value else { return nil }
        lru.removeAll { $0 == key }; lru.append(key)
        return value
    }

    @discardableResult mutating func insert(_ value: Value, for key: String, cost: Int) -> Set<String> {
        var removed = Set<String>()
        if remove(key) { removed.insert(key) }
        guard cost > 0, cost <= byteLimit, countLimit > 0 else { return removed }
        entries[key] = Entry(value: value, cost: cost)
        lru.append(key); bytes += cost
        while entries.count > countLimit || bytes > byteLimit {
            guard let oldest = lru.first else { break }
            if remove(oldest) { removed.insert(oldest) }
        }
        return removed
    }

    @discardableResult mutating func remove(_ key: String) -> Bool {
        guard let old = entries.removeValue(forKey: key) else { return false }
        bytes -= old.cost; lru.removeAll { $0 == key }; return true
    }

    @discardableResult mutating func retain(_ live: Set<String>) -> Set<String> {
        let removed = Set(entries.keys).subtracting(live)
        removed.forEach { _ = remove($0) }
        return removed
    }

    mutating func removeAll() { entries.removeAll(); lru.removeAll(); bytes = 0 }
}

/// A timeout stops admission; it cannot cancel the OS request or free its real slot.
struct CaptureAdmission {
    private(set) var generation: UInt64 = 0
    private(set) var inFlight: UInt64?
    private(set) var paused = false
    private var nextID: UInt64 = 0
    mutating func newSession() -> UInt64 { generation &+= 1; return generation }
    mutating func invalidateSession() { generation &+= 1 }
    mutating func begin() -> UInt64? {
        guard !paused, inFlight == nil else { return nil }
        nextID &+= 1; inFlight = nextID; return nextID
    }
    mutating func timeout(_ id: UInt64) {
        if inFlight == id { paused = true; invalidateSession() }
    }
    mutating func finish(_ id: UInt64, session: UInt64) -> Bool {
        guard inFlight == id else { return false }
        inFlight = nil
        return !paused && generation == session
    }
    mutating func retry() { if inFlight == nil { paused = false } }
}

enum PreviewSizing {
    static func pixels(for size: CGSize) -> CGSize? {
        guard size.width.isFinite, size.height.isFinite, size.width > 0, size.height > 0 else { return nil }
        let scale = min(1, 480 / size.width, 300 / size.height)
        return CGSize(width: max(1, floor(size.width * scale)), height: max(1, floor(size.height * scale)))
    }
}
