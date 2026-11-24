@testable import BilliardsApp
@testable import BilliardsCore
import AppKit
import Network
import UniformTypeIdentifiers

var failures = 0
func check(_ condition: Bool, _ message: String) {
    if condition {
        print("ok   \(message)")
    } else {
        failures += 1
        print("FAIL \(message)")
    }
}

guard let screen = NSScreen.main else {
    print("FAIL no screen available")
    exit(1)
}
let frame = screen.frame
let work = TableRect(0, 0, Double(frame.width), Double(frame.height))
let icon = NSWorkspace.shared.icon(for: .folder)
let items = (0..<21).map { index in
    let name = "Test \(index)"
    return DesktopItem(name: name, url: URL(fileURLWithPath: "/tmp/\(name)"), image: icon)
}
let table = BilliardsMotion(workArea: work, sizes: items.map(\.size))
let view = GameView(items: items, table: table, screen: screen)

// Let the rack fly-in finish; input is ignored during the intro.
view.start()
RunLoop.main.run(until: Date().addingTimeInterval(1.6))
view.stop()

func mouse(_ type: NSEvent.EventType, _ x: Double, _ y: Double) -> NSEvent {
    NSEvent.mouseEvent(with: type, location: CGPoint(x: x, y: frame.height - y), modifierFlags: [],
                       timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: 0,
                       context: nil, eventNumber: 0, clickCount: 1, pressure: 1)!
}

func key(_ character: String, _ code: UInt16) -> NSEvent {
    NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [],
                     timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: 0,
                     context: nil, characters: character, charactersIgnoringModifiers: character,
                     isARepeat: false, keyCode: code)!
}

func settle(_ seconds: Double) {
    var now = ProcessInfo.processInfo.systemUptime
    for _ in 0..<Int(seconds * 60) {
        now += 1.0 / 60
        table.step(1.0 / 60, now: now)
    }
}

do {
    check(RoomDiscovery.request(for: ["DeskPool"]) == .menu, "double-click opens the room selection")
    check(RoomDiscovery.request(for: ["DeskPool", "--demo"]) == .menu, "old demo command opens the room selection")
    check(RoomDiscovery.request(for: ["DeskPool", "--host"]) == .host, "host command opens a room directly")
    check(RoomDiscovery.request(for: ["DeskPool", "--discover"]) == .browse, "discover command opens room search")
    check(RoomDiscovery.request(for: ["DeskPool", "--join", "192.168.0.75"]) == .join("192.168.0.75"),
          "IP command joins directly")
}

// Moving the mouse aims the cue ball.
do {
    let target = CGPoint(x: table.white.x + 300, y: table.white.y)
    view.mouseMoved(with: mouse(.mouseMoved, target.x, target.y))
    check(abs(table.aim.x - 1) < 1e-6 && abs(table.aim.y) < 1e-6, "mouse move aims horizontally")
}

// Press and release inside the table fires a shot.
do {
    let p = CGPoint(x: table.white.x + 300, y: table.white.y)
    view.mouseDown(with: mouse(.leftMouseDown, p.x, p.y))
    view.mouseUp(with: mouse(.leftMouseUp, p.x, p.y))
    check(table.state == .stroke, "press+release fires a shot")
    settle(0.2)
    check(table.state == .rolling, "shot enters rolling")
    settle(20)
    check(table.state == .ready || table.state == .finished, "shot settles")
}

// Releasing outside the cushions cancels the charge instead of shooting.
do {
    table.reset()
    let inside = CGPoint(x: table.white.x + 200, y: table.white.y)
    view.mouseDown(with: mouse(.leftMouseDown, inside.x, inside.y))
    view.mouseUp(with: mouse(.leftMouseUp, 5, 5))
    check(table.state == .ready, "release outside the table cancels the shot")
}

// Holding longer charges a stronger shot.
do {
    table.reset()
    let p = CGPoint(x: table.white.x + 200, y: table.white.y)
    view.mouseDown(with: mouse(.leftMouseDown, p.x, p.y))
    view.start()
    RunLoop.main.run(until: Date().addingTimeInterval(0.15))
    view.mouseUp(with: mouse(.leftMouseUp, p.x, p.y))
    view.stop()
    let weak = table.power
    table.reset()
    view.mouseDown(with: mouse(.leftMouseDown, p.x, p.y))
    view.start()
    RunLoop.main.run(until: Date().addingTimeInterval(0.6))
    view.mouseUp(with: mouse(.leftMouseUp, p.x, p.y))
    view.stop()
    check(table.power > weak, "longer hold charges more power (\(weak) -> \(table.power))")
}

// The HUD restart button resets the round.
do {
    settle(0.2)
    view.keyDown(with: key("h", 4))
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(frame.width),
                               pixelsHigh: Int(frame.height), bitsPerSample: 8, samplesPerPixel: 4,
                               hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                               bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    view.draw(view.bounds)
    NSGraphicsContext.restoreGraphicsState()
    let bounds = table.bounds
    let restart = CGPoint(x: bounds.left + 18 + 14 + 96 + 8 + 40, y: bounds.top + 18 + 64 + 13)
    view.mouseDown(with: mouse(.leftMouseDown, restart.x, restart.y))
    check(table.state == .ready && table.roundSeconds == 0, "HUD restart button resets the round")
    view.onDesktopAccess = { view.setDesktopAccess(true) }
    let desktop = CGPoint(x: bounds.left + 18 + 14 + 96 + 8 + 84 + 8 + 60 + 8 + 43,
                          y: bounds.top + 18 + 64 + 13)
    view.mouseDown(with: mouse(.leftMouseDown, desktop.x, desktop.y))
    check(view.desktopAccess, "HUD enables desktop access mode")
    view.setDesktopAccess(false)
    check(!view.desktopAccess, "desktop access mode can return to the game")
}

// R restarts and Esc quits.
do {
    view.mouseDown(with: mouse(.leftMouseDown, table.white.x + 200, table.white.y))
    view.mouseUp(with: mouse(.leftMouseUp, table.white.x + 200, table.white.y))
    view.keyDown(with: key("r", 15))
    check(table.state == .ready, "R key restarts")
    var quit = false
    view.onQuit = { quit = true }
    view.keyDown(with: key("", 53))
    check(quit, "Esc triggers quit")
}

do {
    table.reset()
    let canvas = NSView(frame: CGRect(origin: .zero, size: frame.size))
    canvas.addSubview(view)
    view.setTableZoom(75)
    view.keyDown(with: key("=", 24))
    check(view.tableZoom == 80 && abs(view.bounds.width - frame.width) < 1e-6 &&
          abs(view.bounds.height - frame.height) < 1e-6 &&
          abs(view.frame.width / frame.width - 0.8) < 1e-6 &&
          abs(view.frame.height / frame.height - 0.8) < 1e-6,
          "zoom shortcut scales both axes equally (zoom \(view.tableZoom)%, frame \(view.frame.size), bounds \(view.bounds.size))")
    let target = view.convert(CGPoint(x: table.white.x + 200, y: table.white.y + 100), to: nil)
    view.mouseMoved(with: mouse(.mouseMoved, target.x, frame.height - target.y))
    check(table.aim.distance(to: V2(2 / sqrt(5), 1 / sqrt(5))) < 1e-6,
          "scaled view maps the mouse back to the same shot angle")
    view.setTableZoom(100)
    view.removeFromSuperview()
}

// The host can allocate equal groups and let returning players rejoin.
do {
    var room = RoomGame()
    room.updateLobbyPlayers([0, 1])
    check(room.start(iconCount: 21), "host starts without player readiness")
    check(room.owners.filter { $0 == 0 }.count == 10 && room.owners.filter { $0 == 1 }.count == 10 &&
          room.owners.filter { $0 == -1 }.count == 1, "assigned balls are equal with one neutral obstacle")
    check(!room.allowsJoin(existingPlayer: nil) && room.allowsJoin(existingPlayer: 1),
          "running round rejects new players but accepts a returning participant")
    room.phase = .finished
    check(room.allowsJoin(existingPlayer: nil), "new players may join after the round ends")
    room = RoomGame()
    room.toggleMode()
    check(room.mode == .free && room.start(iconCount: 21) && room.owners.isEmpty,
          "host can choose free scoring before the round")
}

do {
    view.roomState = RoomGame()
    view.localPlayerID = 0
    var action = ""
    view.onRoomAction = { action = $0 }
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(frame.width),
                               pixelsHigh: Int(frame.height), bitsPerSample: 8, samplesPerPixel: 4,
                               hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                               bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    view.draw(view.bounds)
    NSGraphicsContext.restoreGraphicsState()
    let b = table.bounds
    let height = 173.0
    let start = CGPoint(x: b.left + b.width / 2 - 225 + 164 + 50,
                        y: b.top + b.height / 2 - height / 2 + height - 40 + 13)
    view.mouseDown(with: mouse(.leftMouseDown, start.x, start.y))
    check(action == "start", "host lobby presents a start button without a readiness step")
    view.roomState = nil
    view.localPlayerID = -1
}

do {
    func fixture() -> (RoomGame, BilliardsMotion, [V2]) {
        var room = RoomGame()
        room.updateLobbyPlayers([0, 1])
        _ = room.start(iconCount: 4)
        let table = BilliardsMotion(workArea: TableRect(0, 0, 1600, 900),
                                    sizes: Array(repeating: V2(64, 64), count: 4))
        return (room, table, table.icons.map(\.position))
    }
    do {
        var (room, table, positions) = fixture()
        var snapshot = table.snapshot()
        snapshot.sunk = [1, 2]
        table.apply(snapshot)
        let outcome = room.settle(table: table, shooter: 0, before: [], positions: positions,
                                  scratched: false, scoreBeforeShot: 0)
        check(outcome.foul && outcome.restored && outcome.scored == 1 && table.sunk == [0, 1],
              "opponent's pocketed ball is restored and the cue ball is taken in hand")
        let (_, guestTable, _) = fixture()
        guestTable.apply(table.snapshot())
        check(guestTable.state == .ballInHand && guestTable.whiteSunk,
              "the guest receives the ball-in-hand state after a foul")
    }
    do {
        var (room, table, positions) = fixture()
        var snapshot = table.snapshot()
        snapshot.sunk = [1, 3]
        table.apply(snapshot)
        let outcome = room.settle(table: table, shooter: 0, before: [1], positions: positions,
                                  scratched: false, scoreBeforeShot: 1)
        check(!outcome.foul && room.phase == .finished && room.winner == 0,
              "clearing one's own balls legally wins the round")
    }
    do {
        var (room, table, positions) = fixture()
        var snapshot = table.snapshot()
        snapshot.sunk = [1, 2, 3]
        table.apply(snapshot)
        let outcome = room.settle(table: table, shooter: 0, before: [1], positions: positions,
                                  scratched: false, scoreBeforeShot: 1)
        check(outcome.foul && outcome.restored && room.phase == .playing && room.winner == nil && table.sunk == [0, 1],
              "foul on the final own ball restores it and cannot win")
    }
}

do {
    var room = RoomGame()
    room.toggleMode()
    room.toggleMode()
    check(room.mode == .called, "host can select called-ball mode")
    room.updateLobbyPlayers(Array(0..<6))
    check(!room.start(iconCount: 21), "called-ball mode reserves enough balls to reach the winning score")
    room.updateLobbyPlayers([0, 1])
    let game = BilliardsMotion(workArea: work, sizes: Array(repeating: V2(64, 64), count: 21))
    let started = room.start(iconCount: game.icons.count)
    check(started && room.targetBall != nil, "called-ball round starts with one target")
    if let target = room.targetBall {
        let positions = game.icons.map(\.position)
        let wrong = target == 1 ? 2 : 1
        var snapshot = game.snapshot()
        snapshot.sunk = [target, wrong]
        game.apply(snapshot)
        let foul = room.settle(table: game, shooter: 0, before: [], positions: positions,
                               scratched: false, scoreBeforeShot: 4)
        check(foul.foul && foul.restored && foul.scored == 0 && game.sunk == [0] &&
              game.state == .ballInHand && room.targetBall == target && room.phase == .playing,
              "potting the target with a wrong ball restores both and gives ball in hand without scoring")
        snapshot.sunk = [target]
        game.apply(snapshot)
        let legal = room.settle(table: game, shooter: 1, before: [], positions: positions,
                                scratched: false, scoreBeforeShot: 0)
        check(legal.scored == 1 && !legal.foul && room.targetBall != nil && room.targetBall != target &&
              game.sunk == [target], "legal pot scores one and selects a remaining target")
        if let next = room.targetBall {
            snapshot.sunk = [target, next]
            game.apply(snapshot)
            let win = room.settle(table: game, shooter: 1, before: [target], positions: positions,
                                  scratched: false, scoreBeforeShot: 4)
            check(win.scored == 1 && room.phase == .finished && room.winner == 1 &&
                  room.targetBall == nil, "fifth legal point ends the round and declares the winner")
        }
    }
}

do {
    let sequence = StateSequence()
    check(sequence.accept(42) && !sequence.accept(41) && !sequence.accept(42) && sequence.accept(43),
          "late or duplicate UDP states cannot roll back the game")
    sequence.reset()
    check(sequence.accept(1), "sequence resets on reconnect")
    check(AppDelegate.shouldNotifyTurn(serial: 7, last: 6, local: 2, turn: 2),
          "joining player gets a reminder when their turn begins")
    check(!AppDelegate.shouldNotifyTurn(serial: 7, last: 7, local: 2, turn: 2),
          "repeated network updates do not repeat the turn reminder")
    check(!AppDelegate.shouldNotifyTurn(serial: 8, last: 7, local: 2, turn: 1),
          "other player's turn does not trigger a local reminder")
    check(AppDelegate.shouldNotifyTurn(serial: 8, last: 7, local: 2, turn: 2),
          "another turn by the same player triggers a new reminder")
    let registry = PlayerRegistry(hostName: "房主 Mac")
    let first = registry.register(identity: "device-a", name: "小明的 Mac", connection: 7)
    registry.retainConnections([0])
    let again = registry.register(identity: "device-a", name: "小明的 Mac", connection: 12)
    let other = registry.register(identity: "device-b", name: "另一台 Mac", connection: 13)
    check(first == again && first != other && registry.names[again] == "小明的 Mac",
          "reconnecting device retains its player identity and name")
    check(registry.activePlayers == [0, first, other], "active players follow live connections")
}

do {
    check(!AppDelegate.turnTimedOut(playerCount: 1, elapsed: 120,
                                     shotInProgress: false, state: .ready),
          "solo player has no shot clock")
    check(!AppDelegate.turnTimedOut(playerCount: 2, elapsed: 19.9,
                                     shotInProgress: false, state: .ready),
          "turn stays active before 20 seconds")
    check(AppDelegate.turnTimedOut(playerCount: 2, elapsed: 20,
                                    shotInProgress: false, state: .ready),
          "idle turn expires at 20 seconds")
    check(!AppDelegate.turnTimedOut(playerCount: 2, elapsed: 20,
                                     shotInProgress: true, state: .rolling),
          "shot in progress never times out")
}

do {
    let start = table.snapshot()
    var end = start
    end.positions[0][0] += 0.2
    let middle = MotionSnapshot.interpolated(from: start, to: end, fraction: 0.5)
    check(abs(middle.positions[0][0] - start.positions[0][0] - 0.1) < 1e-9,
          "guest smooths positions between network updates")
    var rollingStart = start
    rollingStart.state = .rolling
    var rollingEnd = end
    rollingEnd.state = .rolling
    let predicted = MotionSnapshot.predicted(from: rollingStart, to: rollingEnd,
                                             interval: 0.05, ahead: 0.05)
    check(abs(predicted.positions[0][0] - rollingEnd.positions[0][0] - 0.2) < 1e-9,
          "guest predicts motion during delayed network updates")
    let stopped = MotionSnapshot.predicted(from: rollingEnd, to: end, interval: 0.05, ahead: 0.1)
    check(stopped.positions == end.positions, "guest does not predict after motion stops")
    let buffer = SnapshotBuffer(delay: 0.08)
    buffer.append(rollingStart, at: 10.0)
    buffer.append(rollingEnd, at: 10.05)
    let buffered = buffer.sample(at: 10.105)!
    check(abs(buffered.positions[0][0] - rollingStart.positions[0][0] - 0.1) < 1e-8,
          "buffer interpolates between irregularly received frames")
    buffer.append(end, at: 11.0)
    check(buffer.sample(at: 11.0)?.positions == end.positions,
          "buffer discards stale frames after a long interruption")
    let clocked = SnapshotBuffer(delay: 0.08)
    var frame0 = rollingStart
    var frame1 = rollingStart
    var frame2 = rollingStart
    frame0.positions[0][0] = 0
    frame1.positions[0][0] = 0.1
    frame2.positions[0][0] = 0.2
    clocked.append(frame0, at: 100.0, sourceTime: 1000.0)
    clocked.append(frame1, at: 100.08, sourceTime: 1000.05)
    clocked.append(frame2, at: 100.11, sourceTime: 1000.10)
    let steady = clocked.sample(at: 100.155)!
    check(abs(steady.positions[0][0] - 0.15) < 1e-8,
          "host timestamps keep playback steady despite uneven packet arrival")
}

do {
    let host = try LANSession(host: nil, portNumber: 38777)
    let guest1 = try LANSession(host: "127.0.0.1", portNumber: 38777)
    let guest2 = try LANSession(host: "127.0.0.1", portNumber: 38777)
    var ids = Set<Int>()
    var snapshots = 0
    var scoreboards = 0
    var countdowns = 0
    var rooms = 0
    var sharedRoom = RoomGame()
    sharedRoom.updateLobbyPlayers([0, 1])
    _ = sharedRoom.start(iconCount: 21)
    var calledRoom = RoomGame()
    calledRoom.mode = .called
    calledRoom.updateLobbyPlayers([0, 1, 2])
    _ = calledRoom.start(iconCount: 21)
    var calledGuests = Set<Int>()
    var datagramGuests = Set<Int>()
    var shots = Set<Int>()
    host.onPacket = { packet, sender in
        if packet.kind == "shoot" { shots.insert(sender) }
    }
    for (index, guest) in [guest1, guest2].enumerated() {
        guest.onPacket = { packet, _ in
            if packet.kind == "welcome", let player = packet.player { ids.insert(player) }
            if packet.kind == "state", packet.snapshot?.positions.count == table.bodies.count {
                snapshots += 1
                if packet.scores == [0: 2, 1: 1] { scoreboards += 1 }
                if packet.remaining == 12 { countdowns += 1 }
                if packet.room == sharedRoom { rooms += 1 }
                if packet.room == calledRoom { calledGuests.insert(index) }
            }
        }
    }
    guest1.onDatagram = { datagramGuests.insert(1) }
    guest2.onDatagram = { datagramGuests.insert(2) }
    let deadline = Date().addingTimeInterval(4)
    while ids.count < 2 && Date() < deadline { RunLoop.main.run(until: Date().addingTimeInterval(0.05)) }
    check(ids.count == 2, "host assigns two distinct players")
    host.send(LANPacket(kind: "state", snapshot: table.snapshot(), turn: 0))
    RunLoop.main.run(until: Date().addingTimeInterval(0.3))
    check(snapshots == 0, "unadmitted connections cannot receive a running game state")
    for id in ids { host.authorize(id) }
    guest1.send(LANPacket(kind: "shoot", power: 0.5))
    guest2.send(LANPacket(kind: "shoot", power: 0.5))
    let shotDeadline = Date().addingTimeInterval(2)
    while shots.count < 2 && Date() < shotDeadline {
        RunLoop.main.run(until: Date().addingTimeInterval(0.05))
    }
    check(shots.count == 2, "host identifies actions from both guests")
    host.send(LANPacket(kind: "state", snapshot: table.snapshot(), turn: 1,
                        scores: [0: 2, 1: 1], remaining: 12, room: sharedRoom))
    let stateDeadline = Date().addingTimeInterval(2)
    while snapshots < 2 && Date() < stateDeadline {
        RunLoop.main.run(until: Date().addingTimeInterval(0.05))
    }
    check(snapshots == 2, "host broadcasts state to both guests")
    check(scoreboards == 2, "host broadcasts live scores to both guests")
    check(countdowns == 2, "host broadcasts countdown to both guests")
    check(rooms == 2, "host broadcasts mode and ball ownership to both guests")
    let udpDeadline = Date().addingTimeInterval(5)
    while (datagramGuests.count < 2 || calledGuests.count < 2) && Date() < udpDeadline {
        host.send(LANPacket(kind: "state", snapshot: table.snapshot(), turn: 1,
                            scores: [0: 2, 1: 1], remaining: 12, room: calledRoom))
        RunLoop.main.run(until: Date().addingTimeInterval(0.1))
    }
    check(datagramGuests.count == 2, "both guests receive real-time states over UDP")
    check(calledGuests.count == 2, "both guests receive the same called-ball target")
    guest1.stopDatagrams()
    RunLoop.main.run(until: Date().addingTimeInterval(3.3))
    var fallbackReceived = false
    guest1.onPacket = { packet, _ in
        if packet.kind == "state", packet.scores == [0: 99] { fallbackReceived = true }
    }
    let fallbackDeadline = Date().addingTimeInterval(6)
    while !fallbackReceived && Date() < fallbackDeadline {
        host.send(LANPacket(kind: "state", snapshot: table.snapshot(), turn: 0, scores: [0: 99]))
        RunLoop.main.run(until: Date().addingTimeInterval(0.1))
    }
    check(fallbackReceived, "TCP restores state when UDP stops")
    guest1.stop(); guest2.stop(); host.stop()
} catch {
    check(false, "LAN session starts: \(error)")
}

do {
    let host = try LANSession(host: nil, portNumber: 38780)
    let guest = try LANSession(host: "127.0.0.1", portNumber: 38780)
    var rejected = false
    host.onPacket = { packet, sender in
        if packet.kind == "hello" { host.reject(sender, reason: "本局已开始") }
    }
    guest.onStatus = { status in
        if status == "已连接" { guest.send(LANPacket(kind: "hello", identity: "new-player", name: "测试", protocolVersion: 2)) }
    }
    guest.onPacket = { packet, _ in
        if packet.kind == "rejected" && packet.name == "本局已开始" { rejected = true }
    }
    let deadline = Date().addingTimeInterval(5)
    while !rejected && Date() < deadline { RunLoop.main.run(until: Date().addingTimeInterval(0.05)) }
    check(rejected, "late join receives the rejection reason over TCP")
    guest.stop(); host.stop()
} catch {
    check(false, "join rejection test starts: \(error)")
}

// A disconnected guest reconnects when the host returns, without relaunching.
do {
    let host1 = try LANSession(host: nil, portNumber: 38778)
    let guest = try LANSession(host: "127.0.0.1", portNumber: 38778)
    var connections = 0
    var reconnecting = false
    guest.onStatus = { status in
        if status == "已连接" { connections += 1 }
        if status == "连接中断，正在重连" { reconnecting = true }
    }
    let initialDeadline = Date().addingTimeInterval(5)
    while connections < 1 && Date() < initialDeadline { RunLoop.main.run(until: Date().addingTimeInterval(0.05)) }
    host1.stop()
    let disconnectDeadline = Date().addingTimeInterval(5)
    while !reconnecting && Date() < disconnectDeadline { RunLoop.main.run(until: Date().addingTimeInterval(0.05)) }
    let host2 = try LANSession(host: nil, portNumber: 38778)
    host2.onPlayersChanged = { [weak host2] players in
        for player in players where player != 0 { host2?.authorize(player) }
    }
    let reconnectDeadline = Date().addingTimeInterval(8)
    while connections < 2 && Date() < reconnectDeadline { RunLoop.main.run(until: Date().addingTimeInterval(0.05)) }
    check(connections >= 2 && reconnecting, "guest reconnects after host returns")
    var restored = false
    var udpRestored = false
    guest.onPacket = { packet, _ in
        if packet.kind == "state", packet.scores == [0: 3, 1: 2], packet.remaining == 8 {
            restored = true
        }
    }
    guest.onDatagram = { udpRestored = true }
    let restoreDeadline = Date().addingTimeInterval(5)
    while (!restored || !udpRestored) && Date() < restoreDeadline {
        host2.send(LANPacket(kind: "state", snapshot: table.snapshot(), turn: 1,
                             scores: [0: 3, 1: 2], remaining: 8))
        RunLoop.main.run(until: Date().addingTimeInterval(0.1))
    }
    check(restored && udpRestored, "reconnected guest receives current state and UDP resumes")
    guest.stop(); host2.stop()
} catch {
    check(false, "reconnect test starts: \(error)")
}

// Discover a private test service without advertising a room to actual players.
do {
    let name = "DIB-test-\(UUID().uuidString.prefix(8))"
    let host = try LANSession(host: nil, portNumber: 38779, serviceName: name, serviceType: "_dibtest._tcp")
    host.onPlayersChanged = { [weak host] players in
        for player in players where player != 0 { host?.authorize(player) }
    }
    let browser = NWBrowser(for: .bonjour(type: "_dibtest._tcp", domain: nil), using: .tcp)
    var found: NWEndpoint?
    browser.browseResultsChangedHandler = { results, _ in
        for result in results {
            if case let .service(serviceName, _, _, _) = result.endpoint, serviceName == name {
                DispatchQueue.main.async { found = result.endpoint }
            }
        }
    }
    browser.start(queue: DispatchQueue(label: "DIB.discovery-test"))
    let deadline = Date().addingTimeInterval(8)
    while found == nil && Date() < deadline { RunLoop.main.run(until: Date().addingTimeInterval(0.05)) }
    check(found != nil, "Bonjour discovers an advertised LAN room")
    if let found {
        let guest = try LANSession(host: nil, portNumber: 38779, endpoint: found)
        var connected = false
        guest.onStatus = { if $0 == "已连接" { connected = true } }
        let connectDeadline = Date().addingTimeInterval(5)
        while !connected && Date() < connectDeadline { RunLoop.main.run(until: Date().addingTimeInterval(0.05)) }
        check(connected, "guest joins a discovered room without an IP address")
        var datagram = false
        guest.onDatagram = { datagram = true }
        let udpDeadline = Date().addingTimeInterval(5)
        while !datagram && Date() < udpDeadline {
            host.send(LANPacket(kind: "state", snapshot: table.snapshot(), turn: 0))
            RunLoop.main.run(until: Date().addingTimeInterval(0.1))
        }
        check(datagram, "discovered room also sends UDP ball positions")
        guest.stop()
    }
    browser.cancel(); host.stop()
} catch {
    check(false, "discovery test starts: \(error)")
}

// Exercise guest drawing on a Retina-sized bitmap with a clipped update region.
do {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 3840, pixelsHigh: 2160,
                               bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
                               isPlanar: false, colorSpaceName: .deviceRGB,
                               bytesPerRow: 0, bitsPerPixel: 0)!
    let context = NSGraphicsContext(bitmapImageRep: rep)!
    let region = CGRect(x: table.bounds.width * 0.45, y: table.bounds.height * 0.45,
                        width: 200, height: 200)
    let start = ProcessInfo.processInfo.systemUptime
    for _ in 0..<30 {
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = context
        context.cgContext.scaleBy(x: 2, y: 2)
        context.cgContext.clip(to: region)
        view.draw(region)
        NSGraphicsContext.restoreGraphicsState()
    }
    let milliseconds = (ProcessInfo.processInfo.systemUptime - start) * 1000 / 30
    print(String(format: "Retina partial draw: %.2f ms average (local test)", milliseconds))
}

if let directory = ProcessInfo.processInfo.environment["DIB_PREVIEW_DIR"] {
    func savePreview(_ name: String) {
        let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(frame.width),
                                   pixelsHigh: Int(frame.height), bitsPerSample: 8, samplesPerPixel: 4,
                                   hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                                   bytesPerRow: 0, bitsPerPixel: 0)!
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        view.draw(view.bounds)
        NSGraphicsContext.restoreGraphicsState()
        try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: directory).appendingPathComponent(name))
    }
    view.localPlayerID = 0
    view.networkNames = [0: "你的 Mac", 1: "朋友的 Mac"]
    view.networkScores = [0: 10, 1: 7]
    var previewRoom = RoomGame()
    previewRoom.updateLobbyPlayers([0, 1])
    view.roomState = previewRoom
    savePreview("lobby.png")
    _ = previewRoom.start(iconCount: table.icons.count)
    view.roomState = previewRoom
    savePreview("assigned.png")
    var called = RoomGame()
    called.mode = .called
    called.updateLobbyPlayers([0, 1])
    _ = called.start(iconCount: table.icons.count)
    view.roomState = called
    view.networkScores = [0: 2, 1: 1]
    savePreview("called.png")
    previewRoom.phase = .finished
    previewRoom.winner = 0
    view.roomState = previewRoom
    savePreview("winner.png")
}

print(failures == 0 ? "\nALL APP TESTS PASSED" : "\n\(failures) APP TEST(S) FAILED")
exit(failures == 0 ? 0 : 1)
