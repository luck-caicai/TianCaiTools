import Foundation

enum WindowActivationTests {
    static func run(_ check: (Bool, String) -> Void) {
        let first = WindowCandidates.merge(published: ["desktop"], focused: "fullscreen", main: "fullscreen",
            previous: [], equal: ==)
        check(first == ["fullscreen", "desktop"], "other-Space key/main window survives an AXWindows omission")
        let next = WindowCandidates.merge(published: [], focused: "desktop", main: nil,
            previous: first, equal: ==)
        check(next == ["desktop", "fullscreen"], "known windows remain validation candidates after changing Spaces")
        let duplicates = WindowCandidates.merge(published: [1, 1, 2], focused: 2, main: 1,
            previous: [2, 3], equal: ==)
        check(duplicates == [2, 1, 3], "key/main and published windows deduplicate before live validation")
        let bounded = WindowCandidates.merge(published: Array(0..<400), focused: 999, main: 998,
            previous: [], equal: ==)
        check(bounded.count == 160 && bounded.prefix(2) == [999, 998], "window scan budget prioritizes key/main")

        func unsigned(_ bytes: [UInt8], at offset: Int, count: Int) -> UInt64 {
            (0..<count).reduce(0) { $0 | (UInt64(bytes[offset + $1]) << ($1 * 8)) }
        }
        for windowID: UInt32 in [1, 2216, UInt32.max] {
            let records = WindowKeyRecords.pair(windowID: windowID)
            check(records.count == 2 && records.allSatisfy { $0.count == 256 }, "key focus keeps a padded down/up pair")
            check(records.map { $0[8] } == [1, 2], "key focus always has matching press and release")
            for record in records {
                check(unsigned(record, at: 4, count: 4) == 248, "declared record fits its backing buffer")
                check(unsigned(record, at: 60, count: 4) == UInt64(windowID), "both edges target the exact window")
                check(record[58] == 16, "process-targeted focus record has the expected routing flag")
                for offset in [16, 24, 32, 40] {
                    let coordinate = Double(bitPattern: unsigned(record, at: offset, count: 8))
                    check(coordinate == 300_000 && coordinate.isFinite, "both coordinate fields stay outside window content")
                }
                check(record[248...].allSatisfy { $0 == 0 }, "record over-read padding remains allocated and zeroed")
            }
            let differences = zip(records[0], records[1]).enumerated().filter { $0.element.0 != $0.element.1 }.map(\.offset)
            check(differences == [8], "paired focus edges share window, location and routing")
        }
    }
}
