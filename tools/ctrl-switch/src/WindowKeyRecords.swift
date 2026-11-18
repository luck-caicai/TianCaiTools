import Foundation

/// WindowServer's process-targeted make-key record format. This is not a global CGEvent and
/// does not move the hardware cursor. Both edges deliberately address a point outside content.
enum WindowKeyRecords {
    static func pair(windowID: UInt32) -> [[UInt8]] {
        var base = [UInt8](repeating: 0, count: 256)
        func write<T: FixedWidthInteger>(_ number: T, at offset: Int) {
            var little = number.littleEndian
            withUnsafeBytes(of: &little) { base.replaceSubrange(offset..<(offset + $0.count), with: $0) }
        }
        write(UInt32(248), at: 4)
        base[58] = 16
        write(windowID, at: 60)
        for offset in [16, 24, 32, 40] { write(Double(300_000).bitPattern, at: offset) }
        var down = base, up = base
        down[8] = 1
        up[8] = 2
        return [down, up]
    }
}
