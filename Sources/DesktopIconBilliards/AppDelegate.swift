import AppKit
import BilliardsCore
import Carbon.HIToolbox
import UserNotifications
import Network

/// Borderless panel that can take key events without activating the app, so the
/// game lives on the desktop instead of stealing focus from the current window.
final class OverlayPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

private var hotKeyRef: EventHotKeyRef?
private var desktopHotKeyRef: EventHotKeyRef?
private var desktopHotKeyAction: (() -> Void)?

private func hotKeyHandler(_ next: EventHandlerCallRef?, _ event: EventRef?,
                           _ userData: UnsafeMutableRawPointer?) -> OSStatus {
    guard let event else { return OSStatus(eventNotHandledErr) }
    var id = EventHotKeyID(signature: 0, id: 0)
    let result = GetEventParameter(event, EventParamName(kEventParamDirectObject),
                                   EventParamType(typeEventHotKeyID), nil,
                                   MemoryLayout<EventHotKeyID>.size, nil, &id)
    guard result == noErr, id.signature == OSType(0x44494231) else { return OSStatus(eventNotHandledErr) }
    if id.id == 1 { DispatchQueue.main.async { NSApp.terminate(nil) } }
    else if id.id == 2 { DispatchQueue.main.async { desktopHotKeyAction?() } }
    else { return OSStatus(eventNotHandledErr) }
    return noErr
}

public final class AppDelegate: NSObject, NSApplicationDelegate, UNUserNotificationCenterDelegate {
    private var panel: OverlayPanel?
    private var view: GameView?
    private var session: LANSession?
    private var turn = 0
    private var localPlayer = 0
    private var shotOwner = 0
    private var scoredThrough = 0
    private var scores: [Int: Int] = [:]
    private var shotInProgress = false
    private var room: RoomGame?
    private var shotStartSunk: Set<Int> = []
    private var shotStartPositions: [V2] = []
    private var shotScratched = false
    private var lastAnnouncedTurn = -1
    private var lastSnapshotSentAt = 0.0
    private var turnStartedAt = ProcessInfo.processInfo.systemUptime
    private var lastAimSentAt = 0.0
    private var lastPingSentAt = 0.0
    private var lastDiagnosticsAt = 0.0
    private var lastStateReceivedAt = 0.0
    private var meanStateInterval = 0.0
    private var roundTripMS: Double?
    private var lastDatagramAt = 0.0
    private var roomAdvertised = false
    private var notificationPermissionDenied = false
    private static let tableZoomKey = "TableZoom"
    private let localName = Host.current().localizedName ?? ProcessInfo.processInfo.hostName
    private lazy var registry = PlayerRegistry(hostName: localName)
    private lazy var localIdentity: String = {
        let defaults = UserDefaults.standard
        if let saved = defaults.string(forKey: "LANPlayerIdentity") { return saved }
        let identity = UUID().uuidString
        defaults.set(identity, forKey: "LANPlayerIdentity")
        return identity
    }()

    public func applicationDidFinishLaunching(_ notification: Notification) {
        let savedZoom = UserDefaults.standard.integer(forKey: Self.tableZoomKey)
        let zoom = GameView.tableZoomLevels.contains(savedZoom) ? savedZoom : GameView.defaultTableZoom
        guard let launch = RoomDiscovery.launch(arguments: CommandLine.arguments, zoom: zoom) else {
            NSApp.terminate(nil)
            return
        }
        let samples = DesktopItems.load()
        guard !samples.isEmpty else {
            let alert = NSAlert()
            alert.messageText = "桌面上没有图标"
            alert.informativeText = "请在桌面放至少一个文件或文件夹，并在系统设置中允许桌面文件夹访问，然后重新打开 DeskPool。"
            NSApp.activate(ignoringOtherApps: true)
            alert.runModal()
            NSApp.terminate(nil)
            return
        }
        let items = (0..<21).map { samples[$0 % samples.count] }
        guard let screen = NSScreen.main else { NSApp.terminate(nil); return }
        let frame = screen.frame, visible = screen.visibleFrame
        let work = TableRect(Double(visible.minX - frame.minX), Double(frame.maxY - visible.maxY),
                             Double(visible.maxX - frame.minX), Double(frame.maxY - visible.minY))
        let table = BilliardsMotion(workArea: work, sizes: items.map(\.size), aspectRatio: 16.0 / 9.0)
        let view = GameView(items: items, table: table, screen: screen)
        view.onTableZoomChanged = { UserDefaults.standard.set($0, forKey: Self.tableZoomKey) }
        self.view = view
        view.onQuit = { NSApp.terminate(nil) }
        view.onDesktopAccess = { [weak self] in
            guard desktopHotKeyRef != nil else {
                let alert = NSAlert()
                alert.messageText = "无法启用桌面操作"
                alert.informativeText = "Ctrl+Option+D 快捷键不可用，请先关闭占用此快捷键的应用后重新启动游戏。"
                alert.runModal()
                return
            }
            self?.setDesktopAccess(true)
        }
        setupNetwork(view: view, table: table, endpoint: launch.endpoint)

        let panel = OverlayPanel(contentRect: frame, styleMask: [.borderless, .nonactivatingPanel],
                                 backing: .buffered, defer: false)
        // One step above the Finder icon layer: hides the real icons while playing,
        // stays below every normal window, and restores the desktop on close.
        panel.level = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.desktopIconWindow)) + 1)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.ignoresMouseEvents = false
        panel.acceptsMouseMovedEvents = true
        panel.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle]
        panel.hidesOnDeactivate = false
        panel.isMovable = false
        panel.becomesKeyOnlyIfNeeded = false
        let canvas = NSView(frame: CGRect(origin: .zero, size: frame.size))
        panel.contentView = canvas
        canvas.addSubview(view)
        view.setTableZoom(launch.zoom)
        panel.orderFrontRegardless()
        panel.makeKey()
        panel.makeFirstResponder(view)
        view.start()
        self.panel = panel
        self.view = view
        desktopHotKeyAction = { [weak self] in
            guard let self, let panel = self.panel else { return }
            self.setDesktopAccess(!panel.ignoresMouseEvents)
        }

        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard),
                                 eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetApplicationEventTarget(), hotKeyHandler, 1, &spec, nil, nil)
        let id = EventHotKeyID(signature: OSType(0x44494231), id: 1)
        RegisterEventHotKey(UInt32(kVK_ANSI_X), UInt32(controlKey | optionKey), id,
                            GetApplicationEventTarget(), 0, &hotKeyRef)
        let desktopID = EventHotKeyID(signature: OSType(0x44494231), id: 2)
        RegisterEventHotKey(UInt32(kVK_ANSI_D), UInt32(controlKey | optionKey), desktopID,
                            GetApplicationEventTarget(), 0, &desktopHotKeyRef)

        let displayID = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber
        let scale = screen.backingScaleFactor
        NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification, object: nil,
            queue: .main) { _ in
                let current = NSScreen.screens.first {
                    ($0.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber) == displayID
                }
                if current == nil || current?.frame != frame || current?.backingScaleFactor != scale {
                    NSApp.terminate(nil)
                }
            }
    }

    public func applicationWillTerminate(_ notification: Notification) {
        view?.stop()
        session?.stop()
        panel?.orderOut(nil)
        if let hotKeyRef { UnregisterEventHotKey(hotKeyRef) }
        if let desktopHotKeyRef { UnregisterEventHotKey(desktopHotKeyRef) }
        desktopHotKeyAction = nil
    }

    private func setDesktopAccess(_ enabled: Bool) {
        guard let panel, let view else { return }
        view.setDesktopAccess(enabled)
        panel.ignoresMouseEvents = enabled
        if enabled { panel.resignKey() } else { panel.makeKey() }
    }

    private func setupNetwork(view: GameView, table: BilliardsMotion, endpoint: NWEndpoint?) {
        do {
            let guest = endpoint != nil
            let session = try LANSession(host: nil, endpoint: endpoint)
            self.session = session
            view.isNetworkGuest = guest
            view.canPlay = false
            if !guest {
                scores = [0: 0]
                view.networkScores = scores
                view.networkNames = registry.names
                room = RoomGame()
                view.roomState = room
                view.hostLANAddress = LANAddress.current()
            }
            view.networkStatus = guest ? "正在连接房主" : "房主 · 等待玩家加入"
            localPlayer = guest ? -1 : 0
            view.localPlayerID = localPlayer
            UNUserNotificationCenter.current().delegate = self
            UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { [weak self] granted, _ in
                UNUserNotificationCenter.current().getNotificationSettings { settings in
                    let denied = !granted || settings.alertSetting != .enabled
                    DispatchQueue.main.async { self?.notificationPermissionDenied = denied }
                }
            }
            session.onStatus = { [weak self, weak view] status in
                view?.networkStatus = status
                view?.needsDisplay = true
                if guest && status == "连接中断，正在重连" {
                    self?.localPlayer = -1
                    self?.roundTripMS = nil
                    self?.lastStateReceivedAt = 0
                    self?.meanStateInterval = 0
                    self?.lastDatagramAt = 0
                    view?.resetNetworkState()
                }
                if guest && status == "已连接", let self {
                    self.session?.send(LANPacket(kind: "hello", identity: self.localIdentity,
                                                 name: self.localName, protocolVersion: LANPacket.currentProtocolVersion))
                }
            }
            session.onPlayersChanged = { [weak self] players in
                guard let self else { return }
                self.registry.retainConnections(players)
                self.syncRoomConnections()
            }
            session.onPacket = { [weak self] packet, sender in
                self?.receive(packet, from: sender, table: table)
            }
            session.onDatagram = { [weak self] in
                self?.lastDatagramAt = ProcessInfo.processInfo.systemUptime
            }
            session.onAdvertisement = { [weak self] active in self?.roomAdvertised = active }
            view.onAim = { [weak self] direction in
                guard let self else { return }
                let now = ProcessInfo.processInfo.systemUptime
                guard now - self.lastAimSentAt >= 0.05 else { return }
                self.lastAimSentAt = now
                self.session?.send(LANPacket(kind: "aim", direction: [direction.x, direction.y]))
            }
            view.onShoot = { [weak self] power in
                guard let self else { return }
                if !guest { self.beginShot(owner: 0, table: table) }
                else {
                    self.session?.send(LANPacket(kind: "shoot", direction: [table.aim.x, table.aim.y],
                                                 power: power))
                }
            }
            view.onPlace = { [weak self] point in
                let b = table.bounds
                self?.session?.send(LANPacket(kind: "place", point: [(point.x - b.left) / b.width,
                                                                      (point.y - b.top) / b.height]))
            }
            view.onRestart = { [weak self] in
                if !guest { self?.roomAction("lobby", table: table) }
            }
            view.onRoomAction = { [weak self] action in
                if !guest { self?.roomAction(action, table: table) }
            }
            view.onTick = { [weak self] in self?.networkTick(table: table) }
            updateTurnDisplay()
        } catch {
            view.networkStatus = "联机启动失败：\(error.localizedDescription)"
            view.canPlay = false
        }
    }

    private func receive(_ packet: LANPacket, from sender: Int, table: BilliardsMotion) {
        guard let view else { return }
        if view.isNetworkGuest {
            var statusChanged = false
            if packet.kind == "rejected" {
                session?.stop()
                let alert = NSAlert()
                alert.messageText = "无法加入房间"
                alert.informativeText = packet.name ?? "房间已开始，请等待本局结束。"
                alert.runModal()
                NSApp.terminate(nil)
                return
            }
            if packet.kind == "identity", let player = packet.player {
                guard packet.protocolVersion == LANPacket.currentProtocolVersion else {
                    session?.stop()
                    let alert = NSAlert()
                    alert.messageText = "房主版本不兼容"
                    alert.informativeText = "请房主和加入者都更新到最新版后重新连接。"
                    alert.runModal()
                    NSApp.terminate(nil)
                    return
                }
                localPlayer = player
                view.localPlayerID = player
                statusChanged = true
            }
            if packet.kind == "state", let snapshot = packet.snapshot, let turn = packet.turn {
                let now = ProcessInfo.processInfo.systemUptime
                if lastStateReceivedAt > 0 {
                    let interval = now - lastStateReceivedAt
                    meanStateInterval = meanStateInterval == 0 ? interval : meanStateInterval * 0.8 + interval * 0.2
                }
                lastStateReceivedAt = now
                view.receiveSnapshot(snapshot, sourceTime: packet.sentAt)
                statusChanged = statusChanged || self.turn != turn
                self.turn = turn
                if let nextRoom = packet.room {
                    statusChanged = statusChanged || room?.turnSerial != nextRoom.turnSerial ||
                        room?.phase != nextRoom.phase || room?.paused != nextRoom.paused
                    room = nextRoom
                    view.roomState = nextRoom
                    if nextRoom.phase == .lobby { lastAnnouncedTurn = -1 }
                }
                if let scores = packet.scores, scores != view.networkScores {
                    view.networkScores = scores
                    view.needsDisplay = true
                }
                view.networkCountdown = packet.remaining
                if let names = packet.names, names != view.networkNames {
                    view.networkNames = names
                    view.needsDisplay = true
                    statusChanged = true
                }
            }
            if packet.kind == "pong", let sentAt = packet.sentAt {
                roundTripMS = max(0, (ProcessInfo.processInfo.systemUptime - sentAt) * 1000)
            }
            if statusChanged { updateTurnDisplay() }
            return
        }
        if packet.kind == "ping", let sentAt = packet.sentAt {
            session?.send(LANPacket(kind: "pong", sentAt: sentAt), to: sender)
            return
        }
        if packet.kind == "hello", let identity = packet.identity, !identity.isEmpty,
           let name = packet.name, !name.isEmpty {
            guard packet.protocolVersion == LANPacket.currentProtocolVersion else {
                session?.reject(sender, reason: "版本不兼容，请更新到最新版。")
                return
            }
            if let room {
                guard room.allowsJoin(existingPlayer: registry.player(for: identity)) else {
                    session?.reject(sender, reason: "本局已开始，请等本局结束后加入。")
                    return
                }
            }
            if room?.phase != .playing && registry.player(for: identity) == nil &&
                registry.activePlayers.count >= table.icons.count {
                session?.reject(sender, reason: "房间已满。")
                return
            }
            let player = registry.register(identity: identity, name: name, connection: sender)
            session?.authorize(sender)
            if room?.phase != .finished && scores[player] == nil { scores[player] = 0 }
            view.networkNames = registry.names
            view.networkScores = scores
            session?.send(LANPacket(kind: "identity", player: player,
                                    protocolVersion: LANPacket.currentProtocolVersion), to: sender)
            syncRoomConnections()
            return
        }
        guard let player = registry.connections[sender], player == turn,
              room?.phase == .playing, room?.paused == false else { return }
        switch packet.kind {
        case "aim":
            if let d = packet.direction, d.count == 2 {
                table.aimAt(table.white.position + V2(d[0], d[1]) * 100)
            }
        case "shoot":
            if let d = packet.direction, d.count == 2 {
                table.aimAt(table.white.position + V2(d[0], d[1]) * 100)
            }
            if let power = packet.power, table.shoot(power: power) {
                beginShot(owner: player, table: table)
            }
        case "place":
            if let p = packet.point, p.count == 2 {
                let b = table.bounds
                table.placeWhite(V2(b.left + p[0] * b.width, b.top + p[1] * b.height))
            }
        default: break
        }
    }

    private func beginShot(owner: Int, table: BilliardsMotion) {
        shotOwner = owner
        scoredThrough = table.pocketedIcons
        shotStartSunk = table.sunk
        shotStartPositions = table.icons.map(\.position)
        shotScratched = false
        shotInProgress = true
        room?.message = ""
        view?.roomState = room
    }

    private func syncRoomConnections() {
        guard var state = room, let view else { return }
        let active = registry.activePlayers
        if state.phase == .lobby {
            state.updateLobbyPlayers(active)
            for player in active where scores[player] == nil { scores[player] = 0 }
        } else if state.phase == .playing && !shotInProgress {
            let wasPaused = state.paused
            state.paused = state.placementBlocked || !Set(state.players).isSubset(of: Set(active))
            if wasPaused && !state.paused {
                state.turnSerial += 1
                turnStartedAt = ProcessInfo.processInfo.systemUptime
            }
        }
        room = state
        view.roomState = state
        view.networkScores = scores
        view.networkNames = registry.names
        updateTurnDisplay()
    }

    private func roomAction(_ action: String, table: BilliardsMotion) {
        guard localPlayer == 0, var state = room, let view else { return }
        switch action {
        case "mode": state.toggleMode()
        case "start":
            state.updateLobbyPlayers(registry.activePlayers)
            if state.start(iconCount: table.icons.count) {
                table.reset()
                scores = Dictionary(uniqueKeysWithValues: state.players.map { ($0, 0) })
                shotInProgress = false
                turn = state.players.first ?? 0
                state.turnSerial += 1
                turnStartedAt = ProcessInfo.processInfo.systemUptime
                lastAnnouncedTurn = -1
            }
        case "lobby":
            guard state.phase != .lobby else { return }
            let mode = state.mode
            state = RoomGame()
            state.mode = mode
            state.updateLobbyPlayers(registry.activePlayers)
            table.reset()
            scores = Dictionary(uniqueKeysWithValues: state.players.map { ($0, 0) })
            shotInProgress = false
            turn = 0
            lastAnnouncedTurn = -1
        default: return
        }
        room = state
        view.roomState = state
        view.networkScores = scores
        updateTurnDisplay()
    }

    private func networkTick(table: BilliardsMotion) {
        guard let view else { return }
        let tickTime = ProcessInfo.processInfo.systemUptime
        if view.isNetworkGuest {
            if tickTime - lastPingSentAt >= 2 {
                lastPingSentAt = tickTime
                session?.send(LANPacket(kind: "ping", sentAt: tickTime))
            }
            if tickTime - lastDiagnosticsAt >= 1 {
                lastDiagnosticsAt = tickTime
                let latency = roundTripMS.map { "\(Int($0.rounded())) ms" } ?? "--"
                let interval = meanStateInterval > 0 ? "\(Int((meanStateInterval * 1000).rounded())) ms" : "--"
                let transport = lastDatagramAt > 0 && tickTime - lastDatagramAt < 2 ? "UDP" : "TCP"
                let permission = notificationPermissionDenied ? " · 系统通知未允许" : ""
                view.networkDiagnostics = "更新 \(view.updateRate)/秒 · 重绘 \(view.drawRate) 次/秒\n\(transport) · 往返 \(latency) · 间隔 \(interval)\(permission)"
            }
            return
        }
        if tickTime - lastDiagnosticsAt >= 1 {
            lastDiagnosticsAt = tickTime
            if room?.phase == .lobby { view.hostLANAddress = LANAddress.current() }
            let broadcast = roomAdvertised ? "广播已启用" : "广播未确认"
            view.networkDiagnostics = "更新 \(view.updateRate)/秒 · 重绘 \(view.drawRate) 次/秒\n房间\(broadcast)"
        }
        if shotInProgress {
            shotScratched = shotScratched || table.whiteSunk
            if room?.mode == .free && table.pocketedIcons > scoredThrough {
                scores[shotOwner, default: 0] += table.pocketedIcons - scoredThrough
                scoredThrough = table.pocketedIcons
                view.networkScores = scores
            } else if let state = room, state.mode == .assigned {
                for player in state.players {
                    scores[player] = state.owners.filter { $0 == player }.count - state.remaining(for: player, sunk: table.sunk)
                }
                view.networkScores = scores
            }
        }
        if shotInProgress && (table.state == .ready || table.state == .ballInHand || table.state == .finished),
           var state = room, state.phase == .playing {
            shotInProgress = false
            let outcome = state.settle(table: table, shooter: shotOwner, before: shotStartSunk,
                                       positions: shotStartPositions, scratched: shotScratched,
                                       scoreBeforeShot: scores[shotOwner, default: 0])
            if state.mode == .assigned {
                for player in state.players {
                    scores[player] = state.owners.filter { $0 == player }.count - state.remaining(for: player, sunk: table.sunk)
                }
            } else if state.mode == .called || state.mode == .sixPockets {
                scores[shotOwner, default: 0] += outcome.scored
            } else if table.state == .finished {
                state.phase = .finished
                let top = scores.values.max() ?? 0
                let winners = state.players.filter { scores[$0, default: 0] == top }
                state.winner = winners.count == 1 ? winners.first : nil
            }
            if !outcome.restored {
                state.paused = true
                state.placementBlocked = true
                state.message = "无法复位球，请房主返回准备室"
            } else if state.phase == .playing && (outcome.foul || outcome.scored == 0) {
                let index = state.players.firstIndex(of: shotOwner) ?? 0
                turn = state.players[(index + 1) % state.players.count]
                if outcome.foul {
                    state.message = "犯规，换下一位摆白球"
                } else if state.mode == .sixPockets && table.sunk.subtracting(shotStartSunk).contains(where: { $0 > 0 }) {
                    state.message = "袋口已点亮，换下一位"
                } else {
                    state.message = "未进球，换下一位"
                }
            } else if state.mode == .called && state.phase == .playing {
                state.message = "目标球入袋 +1 分，继续击球"
            } else if state.mode == .sixPockets && state.phase == .playing {
                state.message = "点亮 \(outcome.scored) 个袋口，继续击球"
            } else { state.message = "" }
            state.turnSerial += 1
            room = state
            view.roomState = state
            view.networkScores = scores
            turnStartedAt = tickTime
            syncRoomConnections()
        }
        let players = room?.players ?? [0]
        if room?.phase == .playing && room?.paused == false && Self.turnTimedOut(playerCount: players.count,
                             elapsed: ProcessInfo.processInfo.systemUptime - turnStartedAt,
                             shotInProgress: shotInProgress, state: table.state) {
            let index = players.firstIndex(of: turn) ?? 0
            turn = players[(index + 1) % players.count]
            room?.turnSerial += 1
            room?.message = "超时，换下一位"
            view.roomState = room
            turnStartedAt = ProcessInfo.processInfo.systemUptime
            updateTurnDisplay()
        }
        let now = ProcessInfo.processInfo.systemUptime
        let remaining: Int? = room?.phase == .playing && room?.paused == false && players.count > 1 && !shotInProgress &&
            (table.state == .ready || table.state == .ballInHand)
            ? max(0, Int(ceil(20 - (now - turnStartedAt)))) : nil
        view.networkCountdown = remaining
        if now - lastSnapshotSentAt >= 0.03 {
            lastSnapshotSentAt = now
            session?.send(LANPacket(kind: "state", snapshot: table.snapshot(), turn: turn,
                                    scores: scores, remaining: remaining, names: registry.names,
                                    sentAt: now, room: room))
        }
    }

    static func turnTimedOut(playerCount: Int, elapsed: Double,
                             shotInProgress: Bool, state: GameState) -> Bool {
        playerCount > 1 && elapsed >= 20 && !shotInProgress &&
            (state == .ready || state == .ballInHand)
    }

    private func updateTurnDisplay() {
        guard let view else { return }
        view.canPlay = room?.phase == .playing && room?.paused == false && localPlayer == turn
        let name = view.networkNames?[turn] ?? "玩家 \(turn + 1)"
        view.networkStatus = room?.phase == .lobby ? "等待房主开始" :
            (room?.phase == .finished ? "本局结束，等待房主开始下一局" :
                (room?.paused == true ? "等待玩家重连" : (view.canPlay ? "轮到你击球" : "轮到 \(name)")))
        view.needsDisplay = true
        if view.canPlay, let serial = room?.turnSerial,
           Self.shouldNotifyTurn(serial: serial, last: lastAnnouncedTurn, local: localPlayer, turn: turn) {
            lastAnnouncedTurn = serial
            view.showTurnReminder()
            let notice = UNMutableNotificationContent()
            notice.title = "轮到你击球"
            notice.body = "桌面图标台球 · \(localName)"
            notice.sound = .default
            UNUserNotificationCenter.current().add(
                UNNotificationRequest(identifier: UUID().uuidString, content: notice, trigger: nil)) { [weak self] error in
                    if error != nil { DispatchQueue.main.async { self?.notificationPermissionDenied = true } }
                }
        }
    }

    static func shouldNotifyTurn(serial: Int, last: Int, local: Int, turn: Int) -> Bool {
        local >= 0 && local == turn && serial != last
    }

    public func userNotificationCenter(_ center: UNUserNotificationCenter,
                                       willPresent notification: UNNotification,
                                       withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        completionHandler([.banner, .sound])
    }
}
