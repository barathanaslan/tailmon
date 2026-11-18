// What the user arranged in the dropdown — device order, hidden devices,
// cards pinned open or closed — and the rule that keeps the dropdown on the
// screen: when the cards do not all fit, the last ones shrink to one line.
import CoreGraphics
import Foundation

/// Keyed by HostKey (tailnet IP, stable per node). Persisted in UserDefaults.
struct Arrangement: Codable, Equatable {
    /// The user's order. Devices not listed keep the report's order (this
    /// machine first, then by name) after the listed ones, so a new device
    /// appears at the end.
    var order: [String] = []
    var hidden: Set<String> = []
    /// true: the card stays open; false: it stays one line. Absent: automatic
    /// (open while there is room).
    var pinned: [String: Bool] = [:]

    func sorted(_ hosts: [HostResult]) -> [HostResult] {
        let rank = Dictionary(order.enumerated().map { ($1, $0) }, uniquingKeysWith: { a, _ in a })
        return hosts.enumerated().sorted { a, b in
            let ra = rank[HostKey.of(a.element)], rb = rank[HostKey.of(b.element)]
            switch (ra, rb) {
            case let (x?, y?): return x < y
            case (_?, nil): return true
            case (nil, _?): return false
            case (nil, nil): return a.offset < b.offset
            }
        }.map(\.element)
    }

    /// Place in the user's order; nil for a device the user never placed.
    func position(_ key: String) -> Int? { order.firstIndex(of: key) }

    func shown(_ hosts: [HostResult]) -> [HostResult] {
        sorted(hosts).filter { !hidden.contains(HostKey.of($0)) }
    }

    /// Moves a device one place up (-1) or down (+1) among `hosts`, which
    /// fixes the whole current order as the user's.
    mutating func move(_ key: String, by step: Int, among hosts: [HostResult]) {
        var keys = sorted(hosts).map { HostKey.of($0) }
        guard let i = keys.firstIndex(of: key) else { return }
        let j = i + step
        guard keys.indices.contains(j) else { return }
        keys.swapAt(i, j)
        order = keys
    }

    mutating func toggleHidden(_ key: String) {
        if hidden.remove(key) == nil { hidden.insert(key) }
    }

    /// Forgets devices that left the fleet (bounded state).
    mutating func retain(_ keys: Set<String>) {
        order.removeAll { !keys.contains($0) }
        hidden.formIntersection(keys)
        pinned = pinned.filter { keys.contains($0.key) }
    }

    private static let key = "arrangement.v1"

    static func load(_ d: UserDefaults = .standard) -> Arrangement {
        guard let data = d.data(forKey: key),
              let a = try? JSONDecoder().decode(Arrangement.self, from: data)
        else { return Arrangement() }
        return a
    }

    func save(_ d: UserDefaults = .standard) {
        if let data = try? JSONEncoder().encode(self) { d.set(data, forKey: Self.key) }
    }
}

/// How the dropdown's device list is drawn for a given amount of room.
struct CardPlan: Equatable {
    /// Devices drawn as a full card; every other live device is one line.
    var open: Set<String>
    /// The list's height with those choices.
    var height: CGFloat
    /// Even so it is taller than the room: the list scrolls.
    var scrolls: Bool
}

enum CardLayout {
    static let spacing: CGFloat = 8
    /// One-line card: 8 + the 12pt name line + 8.
    static let lineHeight: CGFloat = 31

    struct Item: Equatable {
        var key: String
        /// Height as a full card; nil for a device that only ever is one line
        /// (offline, no agent).
        var full: CGFloat?
        var pin: Bool?
    }

    /// Pinned-open cards are open, pinned-closed ones are one line. The rest
    /// open from the top down for as long as the whole list still fits; from
    /// the first one that does not, they are one line. So the user's order is
    /// also the priority.
    static func plan(_ items: [Item], room: CGFloat) -> CardPlan {
        var open = Set(items.filter { $0.full != nil && $0.pin == true }.map(\.key))
        func height(_ open: Set<String>) -> CGFloat {
            let cards = items.reduce(CGFloat(0)) { sum, it in
                sum + (open.contains(it.key) ? (it.full ?? lineHeight) : lineHeight)
            }
            return cards + spacing * CGFloat(max(items.count - 1, 0))
        }
        for it in items where it.full != nil && it.pin == nil {
            let tried = open.union([it.key])
            guard height(tried) <= room else { break }
            open = tried
        }
        let h = height(open)
        return CardPlan(open: open, height: h, scrolls: h > room)
    }

    /// Height of a full HostCard, from the same numbers the views use
    /// (Views.swift): 10pt padding, 15pt header line, 9pt between sections,
    /// 14pt bars 6pt apart, a GPU pair of 14 + 1 + 11 with 2pt of air above
    /// and below, a 12pt rates line, a 14pt processes line, 14pt process rows
    /// 2pt apart. LayoutTests checks it against the rendered card.
    static func fullHeight(gpus: [Stats.GPU], disks: Int, hasRates: Bool, procs: Int, procsOpen: Bool) -> CGFloat {
        var grid: CGFloat = 14 + 6 + 14 // CPU, RAM
        for g in gpus { grid += 6 + (hasMemoryBar(g) ? 30 : 18) }
        grid += CGFloat(disks) * (6 + 14)
        var h: CGFloat = 10 + 15 + 9 + grid + 10
        if hasRates { h += 9 + 12 }
        if procs > 0 {
            h += 9 + 14
            if procsOpen { h += 1 + 5 + CGFloat(procs) * 14 + CGFloat(procs - 1) * 2 }
        }
        return h
    }

    /// Mirrors GPUPair: the memory bar shows for a dedicated GPU with a known
    /// total, and for unified memory with a used figure.
    static func hasMemoryBar(_ g: Stats.GPU) -> Bool {
        guard g.vramUsedMb != nil else { return false }
        if let total = g.vramTotalMb, total > 0 { return true }
        return g.unified ?? (g.vramTotalMb == nil)
    }
}
