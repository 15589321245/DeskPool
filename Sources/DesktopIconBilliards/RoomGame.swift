import Foundation
import BilliardsCore

enum RoomMode: String, Codable, CaseIterable {
    case assigned, free, called

    var title: String {
        switch self {
        case .assigned: return "分球竞速"
        case .free: return "自由计分"
        case .called: return "点名球"
        }
    }
}

enum RoomPhase: String, Codable { case lobby, playing, finished }

struct RoomGame: Codable, Equatable {
    static let calledWinScore = 5

    var phase: RoomPhase = .lobby
    var mode: RoomMode = .assigned
    var players: [Int] = [0]
    /// Owner for each icon, in the physics engine's zero-based icon order.
    var owners: [Int] = []
    /// Index in the physics body's array, where zero is the cue ball.
    var targetBall: Int?
    var winner: Int?
    var turnSerial = 0
    var paused = false
    var placementBlocked = false
    var message = ""

    func allowsJoin(existingPlayer: Int?) -> Bool {
        phase != .playing || existingPlayer.map { players.contains($0) } == true
    }

    mutating func updateLobbyPlayers(_ active: [Int]) {
        guard phase == .lobby else { return }
        let next = active.sorted()
        if players != next { players = next; message = "" }
    }

    mutating func toggleMode() {
        guard phase == .lobby else { return }
        let modes = RoomMode.allCases
        mode = modes[(modes.firstIndex(of: mode)! + 1) % modes.count]
        message = "模式已更改"
    }

    mutating func start(iconCount: Int) -> Bool {
        guard phase == .lobby, !players.isEmpty, players.count <= iconCount else {
            message = "玩家数不能超过图标数"
            return false
        }
        // Even if everyone scores four, leave one ball for the winning shot.
        let calledCapacity = (iconCount - 1) / (Self.calledWinScore - 1)
        guard mode != .called || players.count <= calledCapacity else {
            message = calledCapacity > 0 ? "点名球最多支持 \(calledCapacity) 人" : "点名球至少需要 \(Self.calledWinScore) 颗图标球"
            return false
        }
        let assignedCount = (iconCount / players.count) * players.count
        owners = mode == .assigned
            ? (0..<iconCount).map { $0 < assignedCount ? players[$0 % players.count] : -1 } : []
        targetBall = mode == .called ? (1...iconCount).randomElement() : nil
        phase = .playing
        winner = nil
        paused = false
        message = ""
        return true
    }

    func owner(ofSunkIndex index: Int) -> Int? {
        guard mode == .assigned, owners.indices.contains(index - 1) else { return nil }
        return owners[index - 1]
    }

    func remaining(for player: Int, sunk: Set<Int>) -> Int {
        owners.enumerated().filter { $0.element == player && !sunk.contains($0.offset + 1) }.count
    }

    /// A foul restores opponents' icons. If the final own icon was sunk on a foul,
    /// restore one own icon as well so that a foul cannot end the round.
    mutating func settle(table: BilliardsMotion, shooter: Int, before: Set<Int>,
                         positions: [V2], scratched: Bool,
                         scoreBeforeShot: Int) -> (scored: Int, foul: Bool, restored: Bool) {
        let newlySunk = table.sunk.subtracting(before).filter { $0 > 0 }.sorted()
        if mode == .called {
            if scratched || newlySunk.contains(where: { $0 != targetBall }) {
                table.giveBallInHand()
                return (0, true, restoreBalls(newlySunk, table: table, positions: positions))
            }
            guard !newlySunk.isEmpty else { return (0, false, true) }
            if scoreBeforeShot + 1 >= Self.calledWinScore {
                winner = shooter
                phase = .finished
                targetBall = nil
            } else {
                targetBall = table.icons.indices.map { $0 + 1 }
                    .filter { !table.sunk.contains($0) }.randomElement()
            }
            return (1, false, true)
        }
        guard mode == .assigned else {
            return (newlySunk.count, scratched, true)
        }
        let wrong = newlySunk.filter { owner(ofSunkIndex: $0) != shooter }
        let own = newlySunk.filter { owner(ofSunkIndex: $0) == shooter }
        let foul = scratched || !wrong.isEmpty
        var restore = wrong
        if foul && !own.isEmpty && remaining(for: shooter, sunk: table.sunk) == 0 {
            restore.append(own.last!)
        }
        if foul { table.giveBallInHand() }
        guard restoreBalls(restore, table: table, positions: positions) else {
            return (0, true, false)
        }
        let scored = own.filter { table.sunk.contains($0) }.count
        if !foul && remaining(for: shooter, sunk: table.sunk) == 0 {
            winner = shooter
            phase = .finished
        }
        return (scored, foul, true)
    }

    private func restoreBalls(_ indices: [Int], table: BilliardsMotion, positions: [V2]) -> Bool {
        for index in indices {
            guard positions.indices.contains(index - 1),
                  table.restoreIcon(index - 1, near: positions[index - 1]) else { return false }
        }
        return true
    }
}
