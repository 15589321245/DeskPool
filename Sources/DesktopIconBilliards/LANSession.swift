import Foundation
import Network
import BilliardsCore

struct LANPacket: Codable {
    static let currentProtocolVersion = 6

    var kind: String
    var snapshot: MotionSnapshot? = nil
    var turn: Int? = nil
    var player: Int? = nil
    var direction: [Double]? = nil
    var power: Double? = nil
    var point: [Double]? = nil
    var scores: [Int: Int]? = nil
    var remaining: Int? = nil
    var identity: String? = nil
    var name: String? = nil
    var names: [Int: String]? = nil
    var sentAt: Double? = nil
    var sequence: UInt64? = nil
    var room: RoomGame? = nil
    var protocolVersion: Int? = nil
}

final class PlayerRegistry {
    private var identities: [String: Int] = [:]
    private(set) var connections: [Int: Int] = [:]
    private(set) var names: [Int: String]
    private var nextID = 1

    init(hostName: String) { names = [0: hostName] }

    func register(identity: String, name: String, connection: Int) -> Int {
        let player: Int
        if let existing = identities[identity] { player = existing }
        else { player = nextID; nextID += 1; identities[identity] = player }
        connections = connections.filter { $0.value != player || $0.key == connection }
        connections[connection] = player
        names[player] = String(name.prefix(32))
        return player
    }

    func retainConnections(_ active: [Int]) {
        connections = connections.filter { active.contains($0.key) }
    }

    var activePlayers: [Int] { [0] + Array(Set(connections.values)).sorted() }

    func player(for identity: String) -> Int? { identities[identity] }
}

final class StateSequence {
    private var last: UInt64 = 0
    func accept(_ sequence: UInt64) -> Bool {
        guard sequence > last else { return false }
        last = sequence
        return true
    }
    func reset() { last = 0 }
}

final class LANSession {
    var onPacket: (LANPacket, Int) -> Void = { _, _ in }
    var onStatus: (String) -> Void = { _ in }
    var onPlayersChanged: ([Int]) -> Void = { _ in }
    var onDatagram: () -> Void = {}
    var onAdvertisement: (Bool) -> Void = { _ in }
    private let queue = DispatchQueue(label: "DesktopIconBilliards.LAN")
    private var listener: NWListener?
    private var datagramListener: NWListener?
    private var datagramClient: NWConnection?
    private var datagramPeers: [Int: NWConnection] = [:]
    private var datagramTokens: [String: Int] = [:]
    private var datagramCandidates: [ObjectIdentifier: NWConnection] = [:]
    private var lastKeyframe: [Int: Double] = [:]
    private var lastDatagramSeen: [Int: Double] = [:]
    private var lastDatagramConfirmed: [Int: Double] = [:]
    private var peerDatagramSequence: [Int: UInt64] = [:]
    private var outgoingSequence: UInt64 = 0
    private let receivedSequence = StateSequence()
    private var lastUDPSequence: UInt64 = 0
    private let datagramToken = UUID().uuidString

    private static func errorCode(_ error: NWError) -> String {
        switch error {
        case .posix(let code): return "\(code.rawValue)"
        case .dns(let code): return "\(code)"
        case .tls(let code): return "\(code)"
        default: return "未知"
        }
    }
    private var connections: [Int: NWConnection] = [:]
    private var authorized: Set<Int> = []
    private var received: [Int: Data] = [:]
    private var pendingStates: [Int: Data] = [:]
    private var stateSending: Set<Int> = []
    private var nextPlayer = 1
    private let isHost: Bool
    private let endpoint: NWEndpoint?
    private let port: NWEndpoint.Port
    private var stopped = false

    init(host: String?, portNumber: UInt16 = 7777, endpoint: NWEndpoint? = nil,
         serviceName: String? = nil, serviceType: String? = nil) throws {
        isHost = host == nil && endpoint == nil
        let port = NWEndpoint.Port(rawValue: portNumber)!
        self.port = port
        self.endpoint = endpoint ?? host.map { .hostPort(host: NWEndpoint.Host($0), port: port) }
        let tcp = NWProtocolTCP.Options()
        tcp.noDelay = true
        let parameters = NWParameters(tls: nil, tcp: tcp)
        if !isHost {
            queue.async { [weak self] in self?.connectGuest() }
        } else {
            let listener = try NWListener(using: parameters, on: port)
            if portNumber == 7777 || serviceType != nil {
                listener.service = NWListener.Service(name: serviceName ?? Host.current().localizedName ?? "桌面台球",
                                                       type: serviceType ?? "_dibilliards._tcp")
                listener.serviceRegistrationUpdateHandler = { [weak self] change in
                    let active: Bool
                    switch change {
                    case .add: active = true
                    case .remove: active = false
                    @unknown default: active = false
                    }
                    DispatchQueue.main.async { self?.onAdvertisement(active) }
                }
            }
            self.listener = listener
            if let udp = try? NWListener(using: .udp, on: port) {
                self.datagramListener = udp
                udp.newConnectionHandler = { [weak self] connection in
                    guard let self else { return }
                    self.datagramCandidates[ObjectIdentifier(connection)] = connection
                    connection.start(queue: self.queue)
                    self.receiveDatagram(connection)
                }
                udp.start(queue: queue)
            }
            listener.newConnectionHandler = { [weak self] connection in
                guard let self else { return }
                let player = self.nextPlayer
                self.nextPlayer += 1
                self.connections[player] = connection
                self.received[player] = Data()
                self.watch(connection, player: player)
                connection.start(queue: self.queue)
            }
            listener.stateUpdateHandler = { [weak self] state in
                if case .failed(let error) = state {
                    DispatchQueue.main.async { self?.onStatus("监听失败：\(error.localizedDescription)") }
                }
            }
            listener.start(queue: queue)
        }
    }

    private func connectGuest() {
        guard !stopped, let endpoint else { return }
        let tcp = NWProtocolTCP.Options()
        tcp.noDelay = true
        let connection = NWConnection(to: endpoint, using: NWParameters(tls: nil, tcp: tcp))
        connections[0] = connection
        received[0] = Data()
        watch(connection, player: 0)
        connection.start(queue: queue)
    }

    private func disconnected(_ connection: NWConnection, player: Int) {
        guard connections[player] === connection else { return }
        connections.removeValue(forKey: player)
        authorized.remove(player)
        received.removeValue(forKey: player)
        if let udp = datagramPeers.removeValue(forKey: player) {
            datagramCandidates.removeValue(forKey: ObjectIdentifier(udp))
            udp.cancel()
        }
        datagramTokens = datagramTokens.filter { $0.value != player }
        lastKeyframe.removeValue(forKey: player)
        lastDatagramSeen.removeValue(forKey: player)
        lastDatagramConfirmed.removeValue(forKey: player)
        peerDatagramSequence.removeValue(forKey: player)
        if !isHost {
            datagramClient?.cancel(); datagramClient = nil
            receivedSequence.reset(); lastUDPSequence = 0
        }
        pendingStates.removeValue(forKey: player)
        stateSending.remove(player)
        if !isHost && !stopped {
            DispatchQueue.main.async { self.onStatus("连接中断，正在重连") }
            queue.asyncAfter(deadline: .now() + 2) { [weak self] in self?.connectGuest() }
        } else if isHost {
            DispatchQueue.main.async {
                self.onStatus("玩家 \(player + 1) 已断开")
                self.onPlayersChanged(self.players)
            }
        }
    }

    private func watch(_ connection: NWConnection, player: Int) {
        connection.stateUpdateHandler = { [weak self] state in
            DispatchQueue.main.async {
                switch state {
                case .ready:
                    self?.onStatus("已连接")
                    if self?.isHost == true {
                        self?.send(LANPacket(kind: "welcome", player: player), to: player)
                        self?.onPlayersChanged(self?.players ?? [])
                    } else {
                        self?.send(LANPacket(kind: "udp-register", identity: self?.datagramToken))
                        self?.queue.async { [weak self] in self?.startDatagram() }
                    }
                case .failed(let error):
                    if self?.isHost == false {
                        self?.onStatus("连接失败，正在重试（\(Self.errorCode(error))）")
                    }
                    self?.queue.async { [weak self] in self?.disconnected(connection, player: player) }
                case .cancelled: if self?.isHost == false { self?.onStatus("连接已断开") }
                case .waiting: if self?.isHost == false { self?.onStatus("正在等待网络连接") }
                default: break
                }
            }
        }
        receive(connection, player: player)
    }

    var players: [Int] {
        queue.sync { [0] + (isHost ? connections.keys.sorted() : []).filter { $0 != 0 } }
    }

    private func receive(_ connection: NWConnection, player: Int) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [weak self] data, _, done, error in
            guard let self else { return }
            if let data { self.received[player, default: Data()].append(data) }
            while let end = self.received[player]?.firstIndex(of: 10) {
                let line = self.received[player]!.prefix(upTo: end)
                self.received[player]!.removeSubrange(...end)
                if let packet = try? JSONDecoder().decode(LANPacket.self, from: line) {
                    self.accept(packet, player: player, datagram: false)
                }
            }
            if !done && error == nil { self.receive(connection, player: player) }
            else { self.disconnected(connection, player: player) }
        }
    }

    private func accept(_ packet: LANPacket, player: Int, datagram: Bool) {
        if isHost && !datagram && packet.kind == "udp-register", let token = packet.identity {
            datagramTokens[token] = player
            return
        }
        if datagram { DispatchQueue.main.async { self.onDatagram() } }
        if !isHost && packet.kind == "state", let sequence = packet.sequence {
            guard receivedSequence.accept(sequence) else { return }
        }
        DispatchQueue.main.async {
            self.onPacket(packet, player)
        }
    }

    private func startDatagram() {
        guard !stopped, let endpoint, datagramClient == nil else { return }
        let connection = NWConnection(to: endpoint, using: .udp)
        datagramClient = connection
        connection.stateUpdateHandler = { [weak self, weak connection] state in
            if case .failed = state, let self, let connection {
                self.resetDatagram(connection)
            }
        }
        connection.start(queue: queue)
        receiveDatagram(connection)
        sendDatagramHeartbeat(connection)
    }

    private func resetDatagram(_ connection: NWConnection) {
        guard datagramClient === connection else { return }
        datagramClient = nil
        connection.cancel()
        queue.asyncAfter(deadline: .now() + 2) { [weak self] in
            guard let self, !self.stopped, self.connections[0] != nil else { return }
            self.startDatagram()
        }
    }

    func stopDatagrams() {
        queue.async { [weak self] in
            self?.datagramClient?.cancel()
            self?.datagramClient = nil
        }
    }

    private func sendDatagramHeartbeat(_ connection: NWConnection) {
        guard !stopped, datagramClient === connection else { return }
        if let data = try? JSONEncoder().encode(LANPacket(kind: "udp-register", identity: datagramToken,
                                                         sequence: lastUDPSequence)) {
            connection.send(content: data, completion: .contentProcessed { _ in })
        }
        queue.asyncAfter(deadline: .now() + 1) { [weak self] in self?.sendDatagramHeartbeat(connection) }
    }

    private func receiveDatagram(_ connection: NWConnection) {
        connection.receiveMessage { [weak self] data, _, _, error in
            guard let self else { return }
            if let data, let packet = try? JSONDecoder().decode(LANPacket.self, from: data) {
                if self.isHost, packet.kind == "udp-register", let token = packet.identity,
                   let player = self.datagramTokens[token] {
                    if let previous = self.datagramPeers[player], previous !== connection {
                        self.datagramCandidates.removeValue(forKey: ObjectIdentifier(previous))
                        previous.cancel()
                    }
                    self.datagramPeers[player] = connection
                    self.lastDatagramSeen[player] = ProcessInfo.processInfo.systemUptime
                    if let sequence = packet.sequence, sequence > (self.peerDatagramSequence[player] ?? 0) {
                        self.peerDatagramSequence[player] = sequence
                        self.lastDatagramConfirmed[player] = ProcessInfo.processInfo.systemUptime
                    }
                } else if !self.isHost, connection === self.datagramClient {
                    if packet.kind == "state", let sequence = packet.sequence {
                        self.lastUDPSequence = max(self.lastUDPSequence, sequence)
                    }
                    self.accept(packet, player: 0, datagram: true)
                }
            }
            if error == nil { self.receiveDatagram(connection) }
            else {
                self.datagramCandidates.removeValue(forKey: ObjectIdentifier(connection))
                self.datagramPeers = self.datagramPeers.filter { $0.value !== connection }
                if !self.isHost { self.resetDatagram(connection) }
            }
        }
    }

    func send(_ packet: LANPacket, to player: Int? = nil) {
        queue.async { [weak self] in
            guard let self else { return }
            var packet = packet
            if packet.kind == "state" {
                self.outgoingSequence &+= 1
                packet.sequence = self.outgoingSequence
                if var snapshot = packet.snapshot {
                    snapshot.positions = snapshot.positions.map { $0.map { ($0 * 10000).rounded() / 10000 } }
                    packet.snapshot = snapshot
                }
            }
            guard let data = try? JSONEncoder().encode(packet) else { return }
            var line = data
            line.append(10)
            for (id, connection) in self.connections where player == nil || player == id {
                if self.isHost && packet.kind == "state" && !self.authorized.contains(id) { continue }
                if packet.kind == "state" {
                    let now = ProcessInfo.processInfo.systemUptime
                    if let udp = self.datagramPeers[id], now - (self.lastDatagramSeen[id] ?? 0) < 3 {
                        udp.send(content: data, completion: .contentProcessed { _ in })
                        if now - (self.lastDatagramConfirmed[id] ?? 0) < 3 {
                            if now - (self.lastKeyframe[id] ?? 0) < 1 { continue }
                            self.lastKeyframe[id] = now
                        }
                    }
                    self.pendingStates[id] = line
                    self.flushState(to: id, connection: connection)
                } else {
                    connection.send(content: line, completion: .contentProcessed { _ in })
                }
            }
        }
    }

    func authorize(_ player: Int) {
        queue.async { [weak self] in
            guard let self, self.connections[player] != nil else { return }
            self.authorized.insert(player)
        }
    }

    private func flushState(to player: Int, connection: NWConnection) {
        guard !stateSending.contains(player), let data = pendingStates.removeValue(forKey: player) else { return }
        stateSending.insert(player)
        connection.send(content: data, completion: .contentProcessed { [weak self] _ in
            self?.queue.async { [weak self] in
                guard let self, self.connections[player] === connection else { return }
                self.stateSending.remove(player)
                self.flushState(to: player, connection: connection)
            }
        })
    }

    func reject(_ player: Int, reason: String) {
        queue.async { [weak self] in
            guard let self, let connection = self.connections[player],
                  var data = try? JSONEncoder().encode(LANPacket(kind: "rejected", name: reason)) else { return }
            data.append(10)
            connection.send(content: data, completion: .contentProcessed { [weak self] _ in
                self?.queue.asyncAfter(deadline: .now() + 0.3) { [weak self] in
                    guard let self else { return }
                    self.disconnected(connection, player: player)
                    connection.cancel()
                }
            })
        }
    }

    func stop() {
        queue.async { [weak self] in
            guard let self else { return }
            self.stopped = true
            self.connections.values.forEach { $0.cancel() }
            self.listener?.cancel()
            self.datagramClient?.cancel()
            self.datagramCandidates.values.forEach { $0.cancel() }
            self.datagramListener?.cancel()
        }
    }
}
