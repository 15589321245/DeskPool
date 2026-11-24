import AppKit
import BilliardsCore

/// The whole game drawn on one flipped (top-left origin) desktop-level view.
final class GameView: NSView {
    private let items: [DesktopItem]
    private let iconImages: [NSImage]
    private let ownedIconImages: [NSImage]
    private var targetIconImages: [Int: NSImage] = [:]
    let table: BilliardsMotion
    private var background: NSImage
    private let backgroundScale: CGFloat
    private let whiteImage: NSImage
    private let introOrigins: [V2]
    private var introElapsed: Double? = 0
    private var guideEnabled = true
    private var hudVisible = false
    private var heldSince: Double?
    private var chargeOrigin: V2?
    private var lastNow = ProcessInfo.processInfo.systemUptime
    private var timer: Timer?
    private let snapshotBuffer = SnapshotBuffer()
    private var hasSnapshot = false
    private var localAim: V2?
    private var turnBannerUntil = 0.0
    private var celebrationStarted = 0.0
    private(set) var desktopAccess = false
    var buttons: [(rect: CGRect, action: () -> Void)] = []
    var onQuit: () -> Void = {}
    var onDesktopAccess: () -> Void = {}
    var onRoomAction: (String) -> Void = { _ in }
    var roomState: RoomGame? {
        didSet {
            if oldValue?.phase != .finished && roomState?.phase == .finished {
                celebrationStarted = ProcessInfo.processInfo.systemUptime
            }
            if oldValue != roomState { needsDisplay = true }
        }
    }
    var localPlayerID = -1
    var isNetworkGuest = false
    var canPlay = true
    var networkStatus: String?
    var networkScores: [Int: Int]?
    var networkNames: [Int: String]?
    var networkDiagnostics: String? {
        didSet {
            if oldValue != networkDiagnostics && hudVisible {
                setNeedsDisplay(CGRect(x: table.bounds.left + 18, y: table.bounds.top + 18,
                                       width: 372, height: 126))
            }
        }
    }
    private(set) var updateRate = 0
    private(set) var drawRate = 0
    private var rateStarted = ProcessInfo.processInfo.systemUptime
    private var rateTicks = 0
    private var drawCalls = 0
    var networkCountdown: Int? {
        didSet {
            if oldValue != networkCountdown {
                setNeedsDisplay(CGRect(x: table.bounds.right - 150, y: table.bounds.top + 32,
                                       width: 150, height: 25))
            }
        }
    }
    var onAim: (V2) -> Void = { _ in }
    var onShoot: (Double) -> Void = { _ in }
    var onPlace: (V2) -> Void = { _ in }
    var onRestart: () -> Void = {}
    var onTick: () -> Void = {}

    private static let introDuration = 1.25
    private static let introStagger = 0.025

    init(items: [DesktopItem], table: BilliardsMotion, screen: NSScreen) {
        self.items = items
        let cached = items.map { Artwork.cachedIcon($0.image) }
        iconImages = cached
        ownedIconImages = cached.map { Artwork.outlinedIcon($0) }
        self.table = table
        backgroundScale = screen.backingScaleFactor
        background = Artwork.tableBackground(size: screen.frame.size,
                                             scale: screen.backingScaleFactor,
                                             table: table)
        whiteImage = Artwork.cachedIcon(DesktopItems.load(demo: true).first?.image
                                        ?? Artwork.cueBall(radius: table.whiteRadius))
        let count = max(1, items.count)
        let columns = max(1, Int((Double(count) * 1.7).squareRoot().rounded(.up)))
        let rows = max(1, Int((Double(count) / Double(columns)).rounded(.up)))
        introOrigins = (0..<items.count).map { index in
            let column = index % columns, row = index / columns
            let fx = columns == 1 ? 0.5 : Double(column) / Double(columns - 1)
            let fy = rows == 1 ? 0.5 : Double(row) / Double(rows - 1)
            return V2(table.bounds.left + table.bounds.width * (0.10 + 0.80 * fx),
                      table.bounds.top + table.bounds.height * (0.12 + 0.76 * fy))
        }
        super.init(frame: CGRect(origin: .zero, size: screen.frame.size))
        wantsLayer = true
    }

    required init?(coder: NSCoder) { fatalError("unused") }

    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }

    func start() {
        let timer = Timer(timeInterval: 1.0 / 60, repeats: true) { [weak self] _ in self?.tick() }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    func stop() {
        timer?.invalidate()
        timer = nil
    }

    func setDesktopAccess(_ enabled: Bool) {
        desktopAccess = enabled
        if enabled {
            heldSince = nil
            chargeOrigin = nil
            table.setCharge(0)
        }
        needsDisplay = true
    }

    func receiveSnapshot(_ snapshot: MotionSnapshot, sourceTime: Double? = nil) {
        guard isNetworkGuest else { return }
        if !hasSnapshot {
            let previousRadius = table.pocketRadius
            table.apply(snapshot)
            if abs(previousRadius - table.pocketRadius) > 0.01 {
                background = Artwork.tableBackground(size: bounds.size, scale: backgroundScale, table: table)
                needsDisplay = true
            }
            hasSnapshot = true
        }
        snapshotBuffer.append(snapshot, at: ProcessInfo.processInfo.systemUptime, sourceTime: sourceTime)
    }

    func resetNetworkState() {
        snapshotBuffer.reset()
        hasSnapshot = false
        canPlay = false
        needsDisplay = true
    }

    func showTurnReminder() {
        turnBannerUntil = ProcessInfo.processInfo.systemUptime + 4
        NSSound.beep()
        needsDisplay = true
    }

    private func tick() {
        let now = ProcessInfo.processInfo.systemUptime
        let dt = now - lastNow
        lastNow = now
        rateTicks += 1
        if now - rateStarted >= 1 {
            updateRate = Int((Double(rateTicks) / (now - rateStarted)).rounded())
            drawRate = Int((Double(drawCalls) / (now - rateStarted)).rounded())
            rateTicks = 0
            drawCalls = 0
            rateStarted = now
        }
        let oldPoses = isNetworkGuest ? table.poses : []
        let oldWhite = table.white.position
        let oldState = table.state
        let oldSunk = table.sunk
        let oldCue = isNetworkGuest && heldSince != nil ? table.cue() : nil
        if let elapsed = introElapsed {
            let next = elapsed + max(0, min(0.05, dt))
            introElapsed = next >= Self.introDuration + 6 * Self.introStagger ? nil : next
        } else {
            if isNetworkGuest {
                if let snapshot = snapshotBuffer.sample(at: now) {
                    table.apply(snapshot)
                    if let localAim, canPlay {
                        table.aimAt(table.white.position + localAim * 100)
                    }
                }
            } else if roomState?.phase != .lobby && roomState?.phase != .finished && roomState?.paused != true {
                table.step(dt, now: now)
            }
            if let held = heldSince {
                table.setCharge(min(1, (now - held) / 0.9))
            }
        }
        onTick()
        if desktopAccess { return }
        if roomState?.phase == .finished && now - celebrationStarted < 8 { needsDisplay = true }
        if turnBannerUntil > 0 && now >= turnBannerUntil {
            turnBannerUntil = 0
            needsDisplay = true
        }
        if isNetworkGuest && introElapsed == nil {
            if oldState != table.state || oldSunk != table.sunk {
                needsDisplay = true
            }
            else {
                for (before, after) in zip(oldPoses, table.poses) {
                    if abs(before.x - after.x) > 0.1 || abs(before.y - after.y) > 0.1 ||
                        abs(before.angle - after.angle) > 0.1 {
                        invalidatePose(before)
                        invalidatePose(after)
                    }
                }
                if oldWhite.distance(to: table.white.position) > 0.1 {
                    invalidateWhite(oldWhite)
                    invalidateWhite(table.white.position)
                }
                if heldSince != nil {
                    invalidateAim(oldCue, [])
                    invalidateAim(table.cue(), [])
                    invalidateCharge()
                }
            }
        } else { needsDisplay = true }
    }

    private func invalidatePose(_ pose: Pose) {
        let side = max(pose.width, pose.height) * 1.6 + 24
        setNeedsDisplay(CGRect(x: pose.x - side / 2, y: pose.y - side / 2,
                               width: side, height: side))
    }

    private func invalidateWhite(_ position: V2) {
        let side = max(table.whiteDisplaySize?.x ?? 0, table.whiteDisplaySize?.y ?? 0,
                       table.whiteRadius * 2) + 24
        setNeedsDisplay(CGRect(x: position.x - side / 2, y: position.y - side / 2,
                               width: side, height: side))
    }

    private func invalidateCharge() {
        guard let origin = chargeOrigin else { return }
        setNeedsDisplay(CGRect(x: origin.x - 150, y: origin.y - 80, width: 300, height: 160))
    }

    private func invalidateLine(_ start: V2, _ end: V2) {
        let padding = 10.0
        setNeedsDisplay(CGRect(x: min(start.x, end.x) - padding,
                               y: min(start.y, end.y) - padding,
                               width: abs(start.x - end.x) + padding * 2,
                               height: abs(start.y - end.y) + padding * 2))
    }

    private func invalidateAim(_ cue: (tip: V2, tail: V2)?, _ guide: [GuideLine]) {
        if let cue { invalidateLine(cue.tail, cue.tip) }
        for line in guide { invalidateLine(line.start, line.end) }
    }

    // MARK: drawing

    override func draw(_ dirtyRect: CGRect) {
        drawCalls += 1
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }
        ctx.clear(dirtyRect)
        if desktopAccess {
            let rect = CGRect(x: table.bounds.left + 18, y: table.bounds.top + 18,
                              width: 250, height: 32)
            let path = NSBezierPath(roundedRect: rect, xRadius: 8, yRadius: 8)
            Artwork.color(13, 25, 23, 160).setFill(); path.fill()
            text("桌面操作中 · Ctrl+Option+D 返回游戏", CGPoint(x: rect.minX + 10, y: rect.minY + 8),
                 font: .systemFont(ofSize: 11, weight: .medium), color: Artwork.color(235, 250, 243))
            return
        }
        if backgroundIntersects(dirtyRect) { background.draw(in: bounds) }
        buttons = []
        drawIcons(ctx, dirtyRect: dirtyRect)
        drawWhite(dirtyRect: dirtyRect)
        if introElapsed == nil && canPlay {
            drawCue(ctx)
            if guideEnabled { drawGuide(ctx) }
            drawCharge()
        }
        if hudVisible { drawHUD() }
        if let networkStatus {
            text(networkStatus, CGPoint(x: table.bounds.right - 220, y: table.bounds.top + 20),
                 font: .systemFont(ofSize: 12, weight: .medium), color: Artwork.color(235, 250, 243))
        }
        if let seconds = networkCountdown {
            text("倒计时 \(seconds) 秒", CGPoint(x: table.bounds.right - 110, y: table.bounds.top + 35),
                 font: .systemFont(ofSize: 11, weight: .medium), color: Artwork.color(235, 250, 243, 165))
        }
        if let room = roomState, room.phase == .playing, !room.message.isEmpty {
            text(room.message, CGPoint(x: table.bounds.left + table.bounds.width / 2, y: table.bounds.top + 58),
                 font: .systemFont(ofSize: 11, weight: .medium),
                 color: Artwork.color(255, 224, 168, 175), align: .center)
        }
        if table.state != .finished, networkScores != nil { drawRanking() }
        if table.state == .ballInHand && canPlay { drawHint() }
        if roomState?.phase == .finished {
            drawCelebration(ctx)
            drawSummary()
        } else if roomState == nil && table.state == .finished { drawSummary() }
        if roomState?.phase == .lobby || roomState?.paused == true { drawLobby() }
        if turnBannerUntil > ProcessInfo.processInfo.systemUptime && roomState?.phase == .playing {
            let rect = CGRect(x: table.bounds.left + table.bounds.width / 2 - 110,
                              y: table.bounds.top + 18, width: 220, height: 36)
            Artwork.color(13, 25, 23, 235).setFill()
            NSBezierPath(roundedRect: rect, xRadius: 9, yRadius: 9).fill()
            text("轮到你击球！", CGPoint(x: rect.midX, y: rect.minY + 9),
                 font: .systemFont(ofSize: 14, weight: .semibold),
                 color: Artwork.color(169, 255, 210), align: .center)
        }
    }

    private func backgroundIntersects(_ dirtyRect: CGRect) -> Bool {
        let b = table.bounds
        let rail = 5.0
        let edges = [
            CGRect(x: b.left - rail, y: b.top - rail, width: b.width + rail * 2, height: rail * 2),
            CGRect(x: b.left - rail, y: b.bottom - rail, width: b.width + rail * 2, height: rail * 2),
            CGRect(x: b.left - rail, y: b.top, width: rail * 2, height: b.height),
            CGRect(x: b.right - rail, y: b.top, width: rail * 2, height: b.height),
        ]
        if edges.contains(where: { $0.intersects(dirtyRect) }) { return true }
        let r = table.pocketRadius + 3
        return table.pockets.contains {
            CGRect(x: $0.x - r, y: $0.y - r, width: r * 2, height: r * 2)
                .intersects(dirtyRect)
        }
    }

    private func drawIcons(_ ctx: CGContext, dirtyRect: CGRect) {
        for (index, pose) in table.poses.enumerated() {
            var x = pose.x, y = pose.y, width = pose.width, height = pose.height
            var fraction = 1.0, fade = 0.0
            if let elapsed = introElapsed {
                let t = max(0, min(1, (elapsed - Double(index % 7) * Self.introStagger) / Self.introDuration))
                let ease = t * t * t * (t * (t * 6 - 15) + 10)
                let origin = introOrigins[index]
                let dx = pose.x - origin.x, dy = pose.y - origin.y
                let distance = max(1, (dx * dx + dy * dy).squareRoot())
                let arc = pow(sin(Double.pi * t), 2) * min(65, distance * 0.10) * (index % 2 == 0 ? 1 : -1)
                x = origin.x + dx * ease - dy / distance * arc
                y = origin.y + dy * ease + dx / distance * arc
            } else if table.sunk.contains(index + 1) {
                guard let exit = table.exitVisual(index + 1) else { continue }
                x = exit.x; y = exit.y; fade = exit.fade
                width = max(1, width * (1 - fade * 0.54))
                height = max(1, height * (1 - fade * 0.54))
                fraction = pow(1 - fade, 1.35)
            }
            let margin = fade > 0 ? 90.0 : 16.0
            let iconRect = CGRect(x: x - width / 2 - margin, y: y - height / 2 - margin,
                                  width: width + margin * 2, height: height + margin * 2)
            if !iconRect.intersects(dirtyRect) { continue }
            ctx.saveGState()
            ctx.translateBy(x: x, y: y)
            ctx.rotate(by: -pose.angle * Double.pi / 180)
            let owned = roomState?.mode == .assigned && roomState?.phase == .playing &&
                roomState?.owners.indices.contains(index) == true && roomState?.owners[index] == localPlayerID &&
                !table.sunk.contains(index + 1)
            let isTarget = roomState?.phase == .playing && roomState?.targetBall == index + 1 &&
                !table.sunk.contains(index + 1)
            var icon = owned ? ownedIconImages[index] : iconImages[index]
            if isTarget {
                if let cached = targetIconImages[index] {
                    icon = cached
                } else {
                    icon = Artwork.outlinedIcon(icon, rgb: (255, 212, 105))
                    targetIconImages[index] = icon
                }
            }
            icon.draw(in: CGRect(x: -width / 2, y: -height / 2, width: width, height: height),
                      from: .zero, operation: .sourceOver, fraction: fraction)
            ctx.restoreGState()
            if owned || isTarget {
                let badge = CGRect(x: x + width / 2 - (isTarget ? 22 : 10),
                                   y: y - height / 2 - 7, width: isTarget ? 32 : 19, height: 19)
                let path = NSBezierPath(roundedRect: badge, xRadius: 9.5, yRadius: 9.5)
                (isTarget ? Artwork.color(79, 53, 13, 245) : Artwork.color(12, 71, 48, 240)).setFill()
                path.fill()
                (isTarget ? Artwork.color(255, 212, 105) : Artwork.color(154, 255, 200)).setStroke()
                path.lineWidth = 1; path.stroke()
                text(isTarget ? "目标" : "我", CGPoint(x: badge.midX, y: badge.minY + 2),
                     font: .systemFont(ofSize: 12, weight: .bold),
                     color: isTarget ? Artwork.color(255, 244, 213) : Artwork.color(244, 255, 248), align: .center)
            }
            if fade > 0 { drawParticles(ctx, index: index, fade: fade, at: V2(x, y)) }
        }
    }

    private func drawParticles(_ ctx: CGContext, index: Int, fade: Double, at center: V2) {
        for i in 0..<9 {
            let angle = Double(i) * 2 * Double.pi / 9 + Double(index) * 0.61
            let distance = fade * (20 + Double(i % 3) * 8)
            let size = max(0.7, (1 - fade) * (2.5 + Double(i % 3)))
            let alpha = (230 * pow(sin(Double.pi * fade), 0.65)).rounded() / 255
            let rect = CGRect(x: center.x + cos(angle) * distance - size,
                              y: center.y + sin(angle) * distance - size,
                              width: size * 2, height: size * 2)
            ctx.setFillColor(Artwork.color(173, 255, 221, Int(alpha * 255)).cgColor)
            ctx.fillEllipse(in: rect)
        }
    }

    private func drawWhite(dirtyRect: CGRect) {
        guard !table.whiteSunk else { return }
        let size = table.whiteDisplaySize ?? V2(table.whiteRadius * 2, table.whiteRadius * 2)
        let frame = CGRect(x: table.white.x - size.x / 2, y: table.white.y - size.y / 2,
                           width: size.x, height: size.y)
        if frame.intersects(dirtyRect) { whiteImage.draw(in: frame) }
    }

    private func drawCue(_ ctx: CGContext) {
        guard let cue = table.cue() else { return }
        let thickness = 1.0
        ctx.saveGState()
        ctx.setShadow(offset: .zero, blur: 5, color: Artwork.color(238, 211, 170, 25).cgColor)
        ctx.setLineCap(.round)
        func stroke(_ from: V2, _ to: V2, _ width: Double, _ color: NSColor) {
            ctx.setStrokeColor(color.cgColor)
            ctx.setLineWidth(width)
            ctx.beginPath()
            ctx.move(to: CGPoint(x: from.x, y: from.y))
            ctx.addLine(to: CGPoint(x: to.x, y: to.y))
            ctx.strokePath()
        }
        stroke(cue.tail, cue.tip, 3 * thickness, Artwork.color(239, 193, 126, 28))
        ctx.restoreGState()
    }

    private func drawGuide(_ ctx: CGContext) {
        let colors: [GuideRole: NSColor] = [
            .incoming: Artwork.color(235, 250, 245, 196),
            .white: Artwork.color(167, 216, 255, 208),
            .target: Artwork.color(112, 239, 181, 224),
        ]
        ctx.setLineWidth(2)
        ctx.setLineDash(phase: 0, lengths: [8, 8])
        for line in table.aimGuide() {
            let color = colors[line.role] ?? .white
            ctx.setStrokeColor(color.cgColor)
            ctx.beginPath()
            ctx.move(to: CGPoint(x: line.start.x, y: line.start.y))
            ctx.addLine(to: CGPoint(x: line.end.x, y: line.end.y))
            ctx.strokePath()
            ctx.setLineDash(phase: 0, lengths: [])
            ctx.strokeEllipse(in: CGRect(x: line.end.x - 4, y: line.end.y - 4, width: 8, height: 8))
            ctx.setLineDash(phase: 0, lengths: [8, 8])
        }
        ctx.setLineDash(phase: 0, lengths: [])
    }

    private func drawCharge() {
        guard let origin = chargeOrigin, table.state == .ready else { return }
        let fontSize = 14.0
        let pad = max(4, fontSize / 2)
        let width = fontSize * 8, height = fontSize * 2 + pad
        let bounds = table.bounds
        var x = origin.x + fontSize
        if x + width > bounds.right { x = origin.x - fontSize - width }
        var y = origin.y + fontSize
        if y + height > bounds.bottom { y = origin.y - fontSize - height }
        x = max(bounds.left, x); y = max(bounds.top, y)
        let frame = CGRect(x: x, y: y, width: width, height: height)
        let path = NSBezierPath(roundedRect: frame, xRadius: pad, yRadius: pad)
        Artwork.color(13, 25, 23, 248).setFill(); path.fill()
        Artwork.color(105, 221, 179, 240).setStroke(); path.lineWidth = 1; path.stroke()
        text("力度", CGPoint(x: x + pad, y: y + height / 2 - fontSize / 2),
             font: .systemFont(ofSize: fontSize), color: Artwork.color(235, 250, 243))
        let left = x + pad * 2 + fontSize * 2
        let top = y + (height - pad) / 2
        let barWidth = width - pad - (left - x)
        let bar = NSBezierPath(roundedRect: CGRect(x: left, y: top, width: barWidth, height: pad),
                               xRadius: pad / 2, yRadius: pad / 2)
        Artwork.color(49, 76, 70).setFill(); bar.fill()
        let fillWidth = (barWidth * table.charge).rounded()
        if fillWidth > 0 {
            let fill = NSBezierPath(roundedRect: CGRect(x: left, y: top, width: fillWidth, height: pad),
                                    xRadius: min(pad, fillWidth) / 2, yRadius: min(pad, fillWidth) / 2)
            Artwork.color(111, 239, 185).setFill(); fill.fill()
        }
    }

    private func drawHUD() {
        let bounds = table.bounds
        let frame = CGRect(x: bounds.left + 18, y: bounds.top + 18, width: 372,
                           height: networkDiagnostics == nil ? 104 : 126)
        let path = NSBezierPath(roundedRect: frame, xRadius: 12, yRadius: 12)
        Artwork.color(13, 25, 23, 235).setFill(); path.fill()
        Artwork.color(105, 221, 179, 120).setStroke(); path.lineWidth = 1; path.stroke()
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "开发版"
        text("桌面图标台球 · \(version)", CGPoint(x: frame.minX + 14, y: frame.minY + 12),
             font: .systemFont(ofSize: 13, weight: .semibold), color: Artwork.color(235, 250, 243))
        let stats = String(format: "用时 %@   进球 %d   剩余 %d", Self.clock(table.roundSeconds),
                           table.pocketedIcons, table.icons.count - table.pocketedIcons)
        text(stats, CGPoint(x: frame.minX + 14, y: frame.minY + 38),
             font: .systemFont(ofSize: 12), color: Artwork.color(178, 214, 200))
        var x = frame.minX + 14
        let y = frame.minY + 64
        for (title, width, action) in [
            ("辅助线 · \(guideEnabled ? "开" : "关")", 96.0, { [weak self] in self?.guideEnabled.toggle() }),
            ("重新开始", 84.0, { [weak self] in self?.restart() }),
            ("退出", 60.0, { [weak self] in self?.onQuit() }),
            ("操作桌面", 86.0, { [weak self] in self?.onDesktopAccess() }),
        ] as [(String, Double, () -> Void)] {
            let rect = CGRect(x: x, y: y, width: width, height: 26)
            button(title, rect: rect)
            buttons.append((rect, action))
            x += width + 8
        }
        if let networkDiagnostics {
            text(networkDiagnostics, CGPoint(x: frame.minX + 14, y: frame.minY + 96),
                 font: .systemFont(ofSize: 11), color: Artwork.color(178, 214, 200))
        }
    }

    private func drawLobby() {
        guard let room = roomState else { return }
        let rows = max(1, (room.players.count + 1) / 2)
        let height = CGFloat(150 + rows * 23)
        let centerX = table.bounds.left + table.bounds.width / 2
        let centerY = table.bounds.top + table.bounds.height / 2
        let frame = CGRect(x: centerX - 225, y: centerY - height / 2, width: 450, height: height)
        let path = NSBezierPath(roundedRect: frame, xRadius: 14, yRadius: 14)
        Artwork.color(13, 25, 23, 242).setFill(); path.fill()
        Artwork.color(105, 221, 179, 160).setStroke(); path.lineWidth = 1; path.stroke()
        text(room.paused ? "等待玩家重新连接" : "联机准备 · \(room.mode.title)",
             CGPoint(x: frame.minX + 16, y: frame.minY + 14),
             font: .systemFont(ofSize: 16, weight: .semibold), color: Artwork.color(235, 250, 243))
        let description: String
        if room.paused {
            description = "本局暂停；房主可返回准备室。"
        } else if room.mode == .assigned && !room.players.isEmpty {
            let each = table.icons.count / room.players.count
            let neutral = table.icons.count % room.players.count
            description = "每人 \(each) 球" + (neutral > 0 ? " · 中立 \(neutral) 球" : "") + "；带“我”字的是自己的球。"
        } else if room.mode == .called {
            description = "打进金色标记的目标球得 1 分，先到 \(RoomGame.calledWinScore) 分获胜。"
        } else {
            description = "房主选择模式并开始；所有图标球均可击打。"
        }
        text(description,
             CGPoint(x: frame.minX + 16, y: frame.minY + 42),
             font: .systemFont(ofSize: 12), color: Artwork.color(178, 214, 200))
        for (index, player) in room.players.enumerated() {
            let column = index / rows, row = index % rows
            let status = room.phase == .lobby ? "在线" : "参赛中"
            let mine = player == localPlayerID ? "（我）" : ""
            text("\(playerName(player))\(mine) · \(status)",
                 CGPoint(x: frame.minX + 16 + CGFloat(column * 210), y: frame.minY + 68 + CGFloat(row * 23)),
                 font: .systemFont(ofSize: 12), color: Artwork.color(235, 250, 243))
        }
        if !room.message.isEmpty {
            text(room.message, CGPoint(x: frame.minX + 16, y: frame.maxY - 70),
                 font: .systemFont(ofSize: 11), color: Artwork.color(255, 215, 153))
        }
        let y = frame.maxY - 40
        if room.phase == .lobby {
            if localPlayerID == 0 {
                let mode = CGRect(x: frame.minX + 16, y: y, width: 140, height: 27)
                let start = CGRect(x: frame.minX + 164, y: y, width: 100, height: 27)
                button("切换模式", rect: mode)
                button("开始游戏", rect: start, primary: true)
                buttons.append((mode, { [weak self] in self?.onRoomAction("mode") }))
                buttons.append((start, { [weak self] in self?.onRoomAction("start") }))
            } else {
                text("等待房主开始", CGPoint(x: frame.minX + 16, y: y + 6),
                     font: .systemFont(ofSize: 12), color: Artwork.color(178, 214, 200))
            }
        } else if localPlayerID == 0 {
            let back = CGRect(x: frame.minX + 16, y: y, width: 120, height: 27)
            button("返回准备室", rect: back)
            buttons.append((back, { [weak self] in self?.onRoomAction("lobby") }))
        }
    }

    private func drawHint() {
        let message = "自由球 · 点击台面空处摆放白球"
        let font = NSFont.systemFont(ofSize: 13, weight: .medium)
        let size = (message as NSString).size(withAttributes: [.font: font])
        let bounds = table.bounds
        let frame = CGRect(x: bounds.left + bounds.width / 2 - size.width / 2 - 14,
                           y: bounds.top + (roomState == nil ? 20 : 80), width: size.width + 28, height: 30)
        let path = NSBezierPath(roundedRect: frame, xRadius: 9, yRadius: 9)
        Artwork.color(13, 25, 23, 235).setFill(); path.fill()
        text(message, CGPoint(x: frame.midX, y: frame.midY - 8), font: font,
             color: Artwork.color(235, 250, 243), align: .center)
    }

    private func drawSummary() {
        if let scores = networkScores { drawNetworkSummary(scores); return }
        let bounds = table.bounds
        let frame = CGRect(x: bounds.left + bounds.width / 2 - 180,
                           y: bounds.top + bounds.height / 2 - 100, width: 360, height: 200)
        let path = NSBezierPath(roundedRect: frame, xRadius: 16, yRadius: 16)
        Artwork.color(13, 25, 23, 246).setFill(); path.fill()
        Artwork.color(105, 221, 179, 200).setStroke(); path.lineWidth = 1.5; path.stroke()
        text("清台!", CGPoint(x: frame.midX, y: frame.minY + 26),
             font: .systemFont(ofSize: 22, weight: .bold), color: Artwork.color(111, 239, 185),
             align: .center)
        text("总用时 \(Self.clock(table.roundSeconds))", CGPoint(x: frame.midX, y: frame.minY + 70),
             font: .systemFont(ofSize: 15), color: Artwork.color(235, 250, 243), align: .center)
        text("图标总数 \(table.icons.count)", CGPoint(x: frame.midX, y: frame.minY + 98),
             font: .systemFont(ofSize: 15), color: Artwork.color(235, 250, 243), align: .center)
        let restartRect = CGRect(x: frame.midX - 108, y: frame.minY + 140, width: 100, height: 30)
        let quitRect = CGRect(x: frame.midX + 8, y: frame.minY + 140, width: 100, height: 30)
        button("重新开始", rect: restartRect, primary: true)
        button("退出", rect: quitRect)
        buttons.append((restartRect, { [weak self] in self?.restart() }))
        buttons.append((quitRect, { [weak self] in self?.onQuit() }))
    }

    private func ranked(_ scores: [Int: Int]) -> [(player: Int, goals: Int)] {
        scores.map { (player: $0.key, goals: $0.value) }
            .sorted { $0.goals == $1.goals ? $0.player < $1.player : $0.goals > $1.goals }
    }

    private func playerName(_ player: Int) -> String {
        String((networkNames?[player] ?? "玩家 \(player + 1)").prefix(12))
    }

    private func drawRanking() {
        guard let scores = networkScores, !scores.isEmpty else { return }
        let rows = ranked(scores)
        let assigned = roomState?.mode == .assigned && roomState?.phase == .playing
        let called = roomState?.mode == .called
        let header = assigned ? 43 : 26
        let frame = CGRect(x: table.bounds.right - 152, y: table.bounds.top + 64,
                           width: 150, height: CGFloat(header + rows.count * 19))
        let path = NSBezierPath(roundedRect: frame, xRadius: 8, yRadius: 8)
        Artwork.color(8, 20, 20, 70).setFill(); path.fill()
        text(called ? "点名球 · \(RoomGame.calledWinScore) 分获胜" : "进球榜",
             CGPoint(x: frame.minX + 10, y: frame.minY + 6),
             font: .systemFont(ofSize: 11, weight: .medium), color: Artwork.color(235, 250, 243, 155))
        if assigned, let room = roomState {
            text("带“我”字的是我的球 · 剩 \(room.remaining(for: localPlayerID, sunk: table.sunk))",
                 CGPoint(x: frame.minX + 10, y: frame.minY + 23),
                 font: .systemFont(ofSize: 10), color: Artwork.color(169, 255, 210, 165))
        }
        for (index, row) in rows.enumerated() {
            let rank = rows.firstIndex { $0.goals == row.goals }! + 1
            text("\(rank). \(playerName(row.player))  \(row.goals)",
                 CGPoint(x: frame.minX + 10, y: frame.minY + CGFloat(header - 1 + index * 19)),
                 font: .systemFont(ofSize: 11), color: Artwork.color(235, 250, 243, 155))
        }
    }

    private func drawNetworkSummary(_ scores: [Int: Int]) {
        let rows = ranked(scores)
        let height = CGFloat(max(200, 118 + rows.count * 24))
        let centerX = table.bounds.left + table.bounds.width / 2
        let centerY = table.bounds.top + table.bounds.height / 2
        let frame = CGRect(x: centerX - 180, y: centerY - height / 2,
                           width: 360, height: height)
        let path = NSBezierPath(roundedRect: frame, xRadius: 16, yRadius: 16)
        Artwork.color(13, 25, 23, 135).setFill(); path.fill()
        Artwork.color(105, 221, 179, 80).setStroke(); path.lineWidth = 1; path.stroke()
        let title = roomState?.winner.map { "🎉 \(playerName($0)) 获胜！" } ?? "🎉 本局结算 · 按进球数"
        let unit = roomState?.mode == .called ? "分" : "球"
        text(title, CGPoint(x: frame.midX, y: frame.minY + 20),
             font: .systemFont(ofSize: 18, weight: .semibold),
             color: Artwork.color(235, 250, 243, 205), align: .center)
        for (index, row) in rows.enumerated() {
            let rank = rows.firstIndex { $0.goals == row.goals }! + 1
            text("\(rank). \(playerName(row.player))     \(row.goals) \(unit)",
                 CGPoint(x: frame.midX, y: frame.minY + 56 + CGFloat(index * 24)),
                 font: .systemFont(ofSize: 14), color: Artwork.color(235, 250, 243, 195), align: .center)
        }
        let y = frame.maxY - 45
        let restartRect = CGRect(x: frame.midX - 108, y: y, width: 100, height: 30)
        let quitRect = CGRect(x: frame.midX + 8, y: y, width: 100, height: 30)
        if localPlayerID == 0 {
            button("重新开始", rect: restartRect, primary: true)
            buttons.append((restartRect, { [weak self] in self?.restart() }))
        } else {
            text("等待房主", CGPoint(x: restartRect.midX, y: restartRect.midY - 7),
                 font: .systemFont(ofSize: 11), color: Artwork.color(235, 250, 243, 160), align: .center)
        }
        button("退出", rect: quitRect)
        buttons.append((quitRect, { [weak self] in self?.onQuit() }))
    }

    private func drawCelebration(_ ctx: CGContext) {
        let elapsed = ProcessInfo.processInfo.systemUptime - celebrationStarted
        guard elapsed >= 0 && elapsed < 8 else { return }
        let palette = [Artwork.color(255, 194, 99), Artwork.color(132, 240, 181),
                       Artwork.color(143, 201, 255), Artwork.color(255, 155, 190)]
        let b = table.bounds
        ctx.saveGState()
        ctx.setAlpha(0.35 * min(1, max(0, 8 - elapsed)))
        for index in 0..<36 {
            let phase = Double(index) * 1.618
            let x = b.left + b.width * (0.08 + 0.84 * Double((index * 47) % 101) / 100)
                + sin(elapsed * 2 + phase) * 18
            let y = b.top + (elapsed * (55 + Double(index % 5) * 13) + Double(index * 67))
                .truncatingRemainder(dividingBy: max(1, b.height))
            ctx.setFillColor(palette[index % palette.count].cgColor)
            let size = CGFloat(6 + index % 4)
            ctx.fillEllipse(in: CGRect(x: x, y: y, width: size, height: size))
        }
        ctx.restoreGState()
    }

    private func button(_ title: String, rect: CGRect, primary: Bool = false) {
        let path = NSBezierPath(roundedRect: rect, xRadius: 7, yRadius: 7)
        (primary ? Artwork.color(111, 239, 185) : Artwork.color(49, 76, 70)).setFill()
        path.fill()
        text(title, CGPoint(x: rect.midX, y: rect.midY - 7),
             font: .systemFont(ofSize: 12, weight: .medium),
             color: primary ? Artwork.color(10, 25, 20) : Artwork.color(235, 250, 243), align: .center)
    }

    private func text(_ string: String, _ point: CGPoint, font: NSFont, color: NSColor,
                      align: NSTextAlignment = .left) {
        let style = NSMutableParagraphStyle()
        style.alignment = align
        let attributes: [NSAttributedString.Key: Any] =
            [.font: font, .foregroundColor: color, .paragraphStyle: style]
        var origin = point
        if align == .center {
            origin.x -= (string as NSString).size(withAttributes: attributes).width / 2
        }
        (string as NSString).draw(at: origin, withAttributes: attributes)
    }

    private static func clock(_ seconds: Int) -> String {
        String(format: "%02d:%02d", seconds / 60, seconds % 60)
    }

    // MARK: input

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: bounds,
                                       options: [.mouseMoved, .activeAlways, .inVisibleRect],
                                       owner: self))
    }

    override func cursorUpdate(with event: NSEvent) {
        NSCursor.crosshair.set()
    }

    private func point(_ event: NSEvent) -> V2 {
        let p = convert(event.locationInWindow, from: nil)
        return V2(Double(p.x), Double(p.y))
    }

    private func aim(_ event: NSEvent) {
        guard introElapsed == nil, canPlay else { return }
        let target = point(event)
        if isNetworkGuest {
            let d = target - table.white.position
            if d.length > 2 {
                let direction = V2(d.x / d.length, d.y / d.length)
                if let localAim, localAim.distance(to: direction) < 0.003 { return }
                let oldCue = table.cue()
                let oldGuide = guideEnabled ? table.aimGuide() : []
                localAim = direction
                table.aimAt(target)
                onAim(direction)
                invalidateAim(oldCue, oldGuide)
                invalidateAim(table.cue(), guideEnabled ? table.aimGuide() : [])
            }
        } else {
            table.aimAt(target)
        }
    }

    override func mouseMoved(with event: NSEvent) { aim(event) }
    override func mouseDragged(with event: NSEvent) { aim(event) }

    override func mouseDown(with event: NSEvent) {
        let p = point(event)
        let cg = CGPoint(x: p.x, y: p.y)
        if let hit = buttons.first(where: { $0.rect.contains(cg) }) {
            hit.action()
            return
        }
        guard introElapsed == nil, canPlay else { return }
        if table.state == .ballInHand {
            if isNetworkGuest { onPlace(p) } else { table.placeWhite(p) }
            return
        }
        if table.state == .ready {
            heldSince = ProcessInfo.processInfo.systemUptime
            chargeOrigin = p
        }
    }

    override func mouseUp(with event: NSEvent) {
        guard let held = heldSince else { return }
        let power = max(BilliardsMotion.minShotCharge, min(1, (ProcessInfo.processInfo.systemUptime - held) / 0.9))
        if isNetworkGuest { invalidateCharge(); invalidateAim(table.cue(), []) }
        heldSince = nil
        chargeOrigin = nil
        let p = point(event)
        let bounds = table.bounds
        if canPlay && bounds.left <= p.x && p.x <= bounds.right && bounds.top <= p.y && p.y <= bounds.bottom {
            if isNetworkGuest { onShoot(power) }
            else if table.shoot(power: power) { onShoot(power) }
        } else {
            table.setCharge(0)
        }
    }

    override func keyDown(with event: NSEvent) {
        switch event.charactersIgnoringModifiers?.lowercased() {
        case "r": restart()
        case "g": guideEnabled.toggle(); needsDisplay = true
        case "h": hudVisible.toggle(); needsDisplay = true
        default:
            if event.keyCode == 53 { onQuit() } else { super.keyDown(with: event) }
        }
    }

    func restart() {
        if roomState != nil { onRestart(); return }
        if isNetworkGuest { onRestart(); return }
        table.reset()
        onRestart()
        heldSince = nil
        chargeOrigin = nil
        needsDisplay = true
    }
}
