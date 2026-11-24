import BilliardsCore
import Foundation

var failures = 0
func check(_ condition: Bool, _ message: String) {
    if condition {
        print("ok   \(message)")
    } else {
        failures += 1
        print("FAIL \(message)")
    }
}

let work = TableRect(0, 0, 1600, 900)

func makeTable(_ count: Int) -> BilliardsMotion {
    BilliardsMotion(workArea: work, sizes: Array(repeating: V2(64, 64), count: count))
}

func run(_ table: BilliardsMotion, seconds: Double, now: inout Double) {
    let frames = Int(seconds * 60)
    for _ in 0..<frames {
        now += 1.0 / 60
        table.step(1.0 / 60, now: now)
    }
}

// Rack geometry: every icon lands inside the cushions, in a triangle.
do {
    let table = makeTable(15)
    check(table.icons.count == 15, "rack holds one body per icon")
    check(table.rack.count == 15, "rack positions match icon count")
    let inside = table.icons.allSatisfy {
        $0.x > table.bounds.left && $0.x < table.bounds.right
            && $0.y > table.bounds.top && $0.y < table.bounds.bottom
    }
    check(inside, "rack sits inside the cushions")
    check(table.pockets.count == 6, "six pockets")
    check(table.white.x < table.icons.map(\.x).min()!, "cue ball starts left of the rack")
}

// A full-power break settles back to a resting state with no residual motion.
do {
    let table = makeTable(15)
    var now = 0.0
    check(table.shoot(power: 1), "break shot accepted from ready")
    run(table, seconds: 25, now: &now)
    check(table.state == .ready || table.state == .finished, "break settles (state \(table.state))")
    check(table.activeBodies().allSatisfy { $0.speed == 0 }, "all bodies at rest after the break")
    check(table.roundSeconds >= 20, "round clock advances")
}

// Cushion rebound keeps the rebound coefficient and flips the velocity.
do {
    let table = makeTable(1)
    var now = 0.0
    table.shoot(power: 0.3)
    run(table, seconds: 0.12, now: &now)
    check(table.state == .rolling, "shot reaches rolling state")
    table.white.x = table.bounds.left + table.whiteRadius + 1
    table.white.y = (table.bounds.top + table.bounds.bottom) / 2
    table.white.vx = -600
    table.white.vy = 0
    table.step(1.0 / 60, now: now)
    check(table.white.vx > 0, "left cushion reverses horizontal velocity")
    check(abs(table.white.vx - 600 * BilliardsMotion.railRebound) < 40,
          "rebound keeps the rail coefficient (vx \(table.white.vx))")
}

// Head-on collision transfers momentum along the contact normal.
do {
    let table = makeTable(1)
    var now = 0.0
    table.shoot(power: 0.3)
    run(table, seconds: 0.12, now: &now)
    let a = table.white
    let b = table.icons[0]
    a.x = table.bounds.left + 200
    a.y = (table.bounds.top + table.bounds.bottom) / 2
    b.x = a.x + a.radius + b.radius - 2
    b.y = a.y
    b.vx = 0; b.vy = 0
    a.vx = 500; a.vy = 0
    table.step(1.0 / 60, now: now)
    check(b.vx > 0, "struck body gains forward velocity")
    check(a.vx < 500, "striking body loses velocity")
}

// A scratch waits for manual placement, even when plenty of table space is available.
do {
    let table = makeTable(2)
    var now = 0.0
    var sawScratch = false
    table.aimAt(table.pockets[0])
    check(table.shoot(power: 0.8), "scratch shot accepted")
    for _ in 0..<360 {
        now += 1.0 / 60
        table.step(1.0 / 60, now: now)
        if table.sunk.contains(0) { sawScratch = true }
    }
    check(sawScratch, "cue ball pocketed on a scratch")
    check(table.state == .ballInHand && table.sunk.contains(0),
          "cue ball stays in hand until manually placed")
    check(!table.shoot(power: 0.8), "player must place the cue ball before shooting")
}

// Ball-in-hand rejects illegal placements and accepts a legal one.
do {
    let scratch = makeTable(2)
    scratch.giveBallInHand()
    check(!scratch.placeWhite(V2(scratch.bounds.left - 50, scratch.bounds.top + 100)),
          "placement outside cushions rejected")
    check(!scratch.placeWhite(scratch.pockets[3]), "placement on a pocket rejected")
    check(!scratch.placeWhite(scratch.icons[0].position), "placement on an icon rejected")
    check(scratch.placeWhite(V2(scratch.bounds.left + scratch.bounds.width * 0.10,
                                scratch.bounds.top + scratch.bounds.height * 0.5)),
          "legal placement accepted")
    check(scratch.state == .ready && !scratch.whiteSunk, "placement returns the cue ball to play")
}

// Potting the only icon finishes the round (straight line into the top pocket).
do {
    let table = makeTable(1)
    table.icons[0].x = 800
    table.icons[0].y = 300
    table.white.x = 800
    table.white.y = 600
    var now = 0.0
    table.aimAt(table.icons[0].position)
    table.shoot(power: 0.7)
    run(table, seconds: 20, now: &now)
    check(table.pocketedIcons == 1, "icon counted as pocketed")
    check(table.state == .finished, "clearing the table finishes the round")
}

// Collision geometry follows the visible icon size, without a large invisible gap.
do {
    let table = makeTable(2)
    check(table.radius * 2 <= table.tile && table.radius * 2 >= table.tile * 0.8,
          "collision diameter tracks the visible icon")
    var now = 0.0
    table.shoot(power: 0.3)
    run(table, seconds: 0.12, now: &now)
    let a = table.icons[0], b = table.icons[1]
    table.white.x = table.bounds.right - 200
    table.white.y = table.bounds.bottom - 200
    table.white.vx = 0; table.white.vy = 0
    a.x = table.bounds.left + 300
    a.y = (table.bounds.top + table.bounds.bottom) / 2
    b.x = a.x + table.tile * 1.1
    b.y = a.y
    a.vx = 100; a.vy = 0; b.vx = 0; b.vy = 0
    table.step(0.0001, now: now)
    check(b.vx == 0, "icons separated by a visible gap do not collide")
    b.x = a.x + a.radius + b.radius - 0.5
    b.y = a.y
    a.vx = 100; a.vy = 0; b.vx = 0; b.vy = 0
    table.step(0.0001, now: now)
    check(b.vx > 0, "icons transfer momentum at visible contact")
}

// Different screen sizes preserve the host's normalized visual footprint.
do {
    let host = makeTable(2)
    let guest = BilliardsMotion(workArea: TableRect(0, 0, 1100, 700),
                                sizes: Array(repeating: V2(64, 64), count: 2))
    guest.apply(host.snapshot())
    let xError = abs(host.poses[0].width / host.bounds.width - guest.poses[0].width / guest.bounds.width)
    let yError = abs(host.poses[0].height / host.bounds.height - guest.poses[0].height / guest.bounds.height)
    check(xError < 1e-8 && yError < 1e-8, "guest icon footprint matches host across screen sizes")
    let cue = guest.whiteDisplaySize!
    check(abs(cue.x / guest.bounds.width - 2 * host.whiteRadius / host.bounds.width) < 1e-8,
          "guest cue icon footprint matches host")
}

// LAN screens with different shapes must show the same aim and collision geometry.
do {
    let sizes = Array(repeating: V2(64, 64), count: 6)
    let host = BilliardsMotion(workArea: TableRect(0, 0, 1920, 1080), sizes: sizes, aspectRatio: 16.0 / 9.0)
    let guest = BilliardsMotion(workArea: TableRect(0, 0, 1280, 800), sizes: sizes, aspectRatio: 16.0 / 9.0)
    host.aimAt(host.icons[0].position)
    host.setCharge(0.8)
    guest.apply(host.snapshot())
    let factor = guest.bounds.width / host.bounds.width
    check(abs(guest.bounds.height / host.bounds.height - factor) < 1e-9,
          "different LAN screens fit a uniformly scaled table")
    check(abs(guest.white.radius - host.white.radius * factor) < 1e-9 &&
          abs(guest.icons[0].radius - host.icons[0].radius * factor) < 1e-9 &&
          abs(guest.pocketRadius - host.pocketRadius * factor) < 1e-9,
          "guest collision and pocket radii match the host")
    let hostLines = host.aimGuide(), guestLines = guest.aimGuide()
    if let a = hostLines.first, let b = guestLines.first {
        let hx = (a.end.x - host.bounds.left) / host.bounds.width
        let hy = (a.end.y - host.bounds.top) / host.bounds.height
        let gx = (b.end.x - guest.bounds.left) / guest.bounds.width
        let gy = (b.end.y - guest.bounds.top) / guest.bounds.height
        check(abs(hx - gx) < 1e-8 && abs(hy - gy) < 1e-8,
              "guest aim guide reaches the same collision point as host")
    } else { check(false, "both LAN screens draw the aim guide") }
}

// A high-speed off-centre hit should follow the predicted target-ball angle.
do {
    let table = makeTable(1)
    let y = (table.bounds.top + table.bounds.bottom) / 2
    table.white.x = table.bounds.left + 200; table.white.y = y
    table.icons[0].x = table.white.x + 350; table.icons[0].y = y + 25
    table.aimAt(V2(table.white.x + 500, y))
    table.setCharge(1)
    let predicted = table.aimGuide().first { $0.role == .target }
    _ = table.shoot(power: 1)
    var t = 0.0
    while table.icons[0].speed == 0 && t < 2 {
        t += 1.0 / 120
        table.step(1.0 / 120, now: t)
    }
    if let line = predicted, table.icons[0].speed > 0 {
        let guide = line.end - line.start
        let ball = V2(table.icons[0].vx, table.icons[0].vy)
        let error = abs(guide.x * ball.y - guide.y * ball.x) / (guide.length * ball.length)
        check(error < 0.08, "high-speed glancing collision follows the predicted angle (error \(error))")
    } else { check(false, "glancing collision reaches the target") }
}

// Keep a visible local timing for a full rack; gameplay must remain responsive.
do {
    let table = makeTable(21)
    _ = table.shoot(power: 1)
    var peak = 0.0, total = 0.0
    for frame in 1...240 {
        let start = ProcessInfo.processInfo.systemUptime
        table.step(1.0 / 60, now: Double(frame) / 60)
        let elapsed = ProcessInfo.processInfo.systemUptime - start
        total += elapsed; peak = max(peak, elapsed)
    }
    print(String(format: "Full-rack physics: %.2f ms average, %.2f ms peak (local test)",
                 total * 1000 / 240, peak * 1000))
}

// Aiming reaches distant balls even before the player charges the shot.
do {
    let table = makeTable(1)
    let y = (table.bounds.top + table.bounds.bottom) / 2 + 60
    table.white.x = table.bounds.left + 120; table.white.y = y
    table.icons[0].x = table.bounds.right - 180; table.icons[0].y = y
    table.aimAt(table.icons[0].position)
    table.setCharge(0)
    let weak = table.aimGuide().first { $0.role == .incoming }
    table.setCharge(1)
    let strong = table.aimGuide().first { $0.role == .incoming }
    if let weak, let strong {
        let gap = weak.end.distance(to: table.icons[0].position)
        check(abs(gap - table.white.radius - table.icons[0].radius) < 1e-6 &&
              weak.end.distance(to: strong.end) < 1e-6,
              "aim guide reaches a distant ball regardless of charge")
    } else { check(false, "distant-ball guide is visible") }
    _ = table.shoot(power: BilliardsMotion.minShotCharge)
    var now = 0.0
    run(table, seconds: 8, now: &now)
    check(table.icons[0].speed == 0 && abs(table.icons[0].x - (table.bounds.right - 180)) < 1e-6,
          "weak shot still stops before a distant ball")
}

// The aim guide predicts an incoming leg plus outgoing legs on contact.
do {
    let table = makeTable(1)
    table.aimAt(table.icons[0].position)
    let lines = table.aimGuide()
    check(lines.contains { $0.role == .incoming }, "guide shows the incoming path")
    check(lines.contains { $0.role == .target }, "guide shows the struck icon's path")
    check(table.aimGuide().allSatisfy { $0.start.distance(to: $0.end) >= 2 },
          "guide legs have visible length")
}

// Charge is clamped and the shot speed grows with it.
do {
    let table = makeTable(0)
    table.aimAt(V2(table.white.x + 100, table.white.y))
    table.shoot(power: 0)
    let slow = table.power
    table.reset()
    table.aimAt(V2(table.white.x + 100, table.white.y))
    table.shoot(power: 1)
    check(table.power > slow, "full charge is faster than minimum charge")
    check(table.state == .stroke, "shot enters the stroke animation")
}

print(failures == 0 ? "\nALL TESTS PASSED" : "\n\(failures) TEST(S) FAILED")
exit(failures == 0 ? 0 : 1)
