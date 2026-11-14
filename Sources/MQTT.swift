import Foundation
import dnssd
import Network
import Combine

@MainActor
final class MQTT: ObservableObject {
    enum Status: Equatable {
        case offline, connecting, online, failed(String)
    }

    @Published private(set) var status = Status.offline
    @Published private(set) var connectionCheck = 0
    @Published private(set) var levels = (try? JSONDecoder().decode(
        [UUID: Int].self, from: UserDefaults.standard.data(forKey: "brightnessLevels") ?? Data()
    )) ?? [:]
    private var stripTopics: [UUID: String] = [:]
    private var packetID: UInt16 = 0
    @Published private(set) var scheduleDeadlines: [UUID: Date] = (try? JSONDecoder().decode(
        [UUID: Date].self, from: UserDefaults.standard.data(forKey: "scheduleDeadlines") ?? Data()
    )) ?? [:]
    var scheduledCommands: Set<UUID> { Set(scheduleDeadlines.keys) }
    private var pendingCommand: UUID?
    private var pendingSchedule: Set<UInt16> = []
    private var scheduleTimeout: Task<Void, Never>?
    var isScheduling: Bool { !pendingSchedule.isEmpty }
    private var connection: NWConnection?
    private var timer: Task<Void, Never>?
    private var incoming = Data()
    private var awaitingPing = false
    private var reconnectTask: Task<Void, Never>?
    private var activeBroker: Broker?
    private var activePassword = ""
    private var reconnectDelay: Duration = .seconds(2)
    private var manuallyDisconnected = false
    private var clientID = "LedBar-" + UUID().uuidString.prefix(16)

    func disconnect() {
        if isScheduling { finishSchedule() }
        manuallyDisconnected = true
        reconnectTask?.cancel()
        reconnectTask = nil
        timer?.cancel()
        timer = nil
        connection?.cancel()
        connection = nil
        incoming = Data()
        awaitingPing = false
        status = .offline
    }

    func connect(_ broker: Broker, password: String) {
        manuallyDisconnected = false
        reconnectTask?.cancel()
        reconnectTask = nil
        activeBroker = broker
        activePassword = password
        reconnectDelay = .seconds(2)
        openConnection(broker, password: password)
    }

    func checkConnection() {
        guard status == .online else {
            retryConnection()
            return
        }
        connectionCheck &+= 1
    }

    func retryConnection() {
        guard status != .online, status != .connecting, let activeBroker else { return }
        manuallyDisconnected = false
        reconnectTask?.cancel()
        reconnectTask = nil
        reconnectDelay = .seconds(2)
        status = .connecting
        openConnection(activeBroker, password: activePassword)
    }

    func resumeAfterWake() {
        guard !manuallyDisconnected, let activeBroker else { return }
        reconnectTask?.cancel()
        reconnectTask = nil
        reconnectDelay = .seconds(2)
        status = .connecting
        openConnection(activeBroker, password: activePassword)
    }

    private func openConnection(_ broker: Broker, password: String) {
        timer?.cancel()
        timer = nil
        connection?.cancel()
        connection = nil
        incoming = Data()
        awaitingPing = false
        let host = broker.host.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !host.isEmpty, let number = UInt16(broker.port), number > 0,
              let port = NWEndpoint.Port(rawValue: number),
              !host.contains("://"), !host.contains("/") else {
            fail("Укажите адрес брокера и порт от 1 до 65535.")
            return
        }
        guard broker.username.utf8.count <= 65535, password.utf8.count <= 65535,
              !broker.username.utf8.contains(0), password.isEmpty || !broker.username.isEmpty else {
            fail("Проверьте имя пользователя и пароль.")
            return
        }

        let socket = NWConnection(host: NWEndpoint.Host(host), port: port, using: broker.tls ? .tls : .tcp)
        connection = socket
        status = .connecting
        socket.stateUpdateHandler = { [weak self, weak socket] state in
            Task { @MainActor in
                guard let self, let socket, self.connection === socket else { return }
                switch state {
                case .ready:
                    var flags: UInt8 = 2
                    var body = Self.field("MQTT") + [4, 0, 0, 30] + Self.field(self.clientID)
                    if !broker.username.isEmpty {
                        flags |= 128
                        body.append(Self.field(broker.username))
                    }
                    if !password.isEmpty {
                        flags |= 64
                        body.append(Self.field(password))
                    }
                    body[7] = flags
                    self.send(Self.packet(0x10, body))
                    self.receive(socket)
                case .failed(let error), .waiting(let error):
                    if case .dns(let code) = error, code == kDNSServiceErr_NoSuchRecord {
                        self.fail("DNS не нашёл адрес брокера. Проверьте имя хоста или укажите IP-адрес, если брокер доступен по IP.")
                    } else {
                        self.fail(error.localizedDescription)
                    }
                default:
                    break
                }
            }
        }
        socket.start(queue: .main)
        timer = Task { [weak self] in
            try? await Task.sleep(for: .seconds(10))
            guard !Task.isCancelled, let self, self.status == .connecting else { return }
            self.fail("Брокер не ответил за 10 секунд.")
        }
    }

    func trackBrightness(in config: Configuration) {
        let previous = Set(stripTopics.values)
        stripTopics = Dictionary(uniqueKeysWithValues: config.strips.compactMap { strip in
            config.topics.first { $0.id == strip.topic && $0.isValid }.map { (strip.id, $0.path) }
        })
        guard status == .online else { return }
        let current = Set(stripTopics.values)
        updateSubscriptions(previous.subtracting(current), subscribe: false)
        updateSubscriptions(current.subtracting(previous), subscribe: true)
    }

    private func updateSubscriptions(_ topics: Set<String>, subscribe: Bool) {
        for topic in topics.sorted() {
            packetID = packetID == .max ? 1 : packetID + 1
            var body = Data([UInt8(packetID >> 8), UInt8(packetID & 255)]) + Self.field(topic)
            if subscribe { body.append(0) }
            send(Self.packet(subscribe ? 0x82 : 0xA2, body))
        }
    }

    private func recordBrightness(topic: String, payload: String) {
        guard let level = Int(payload.trimmingCharacters(in: .whitespacesAndNewlines)),
              (0...12).contains(level) else { return }
        var updated = levels
        for (id, path) in stripTopics where path == topic {
            updated[id] = level
        }
        guard updated != levels else { return }
        levels = updated
        if let data = try? JSONEncoder().encode(updated) {
            UserDefaults.standard.set(data, forKey: "brightnessLevels")
        }
    }

    @discardableResult
    func publish(topic: String, payload: String) -> Bool {
        guard status == .online, Topic(path: topic).isValid, payload.utf8.count <= 1_048_576 else { return false }
        send(Self.packet(0x30, Self.field(topic) + Data(payload.utf8)))
        recordBrightness(topic: topic, payload: payload)
        return true
    }

    func scheduleInFiveMinutes(commandID: UUID, messages: [(topic: String, payload: String)]) {
        guard status == .online, !isScheduling, !messages.isEmpty else { return }
        let delayedTopics = messages.map { "$delayed/300/" + $0.topic }
        scheduleDeadlines.removeValue(forKey: commandID)
        guard delayedTopics.allSatisfy({ Topic(path: $0).isValid }) else { return }
        pendingCommand = commandID

        var batch = Data()
        for (topic, message) in zip(delayedTopics, messages) {
            packetID = packetID == .max ? 1 : packetID + 1
            pendingSchedule.insert(packetID)
            let identifier = Data([UInt8(packetID >> 8), UInt8(packetID & 255)])
            batch.append(Self.packet(0x32, Self.field(topic) + identifier + Data(message.payload.utf8)))
        }
        send(batch)
        scheduleTimeout = Task { [weak self] in
            try? await Task.sleep(for: .seconds(5))
            guard !Task.isCancelled else { return }
            self?.finishSchedule()
        }
    }

    func scheduleRemainingFraction(for commandID: UUID, at date: Date = Date()) -> CGFloat {
        guard let deadline = scheduleDeadlines[commandID] else { return 0 }
        let remaining = deadline.timeIntervalSince(date)
        return min(1, max(0, CGFloat(remaining / 300)))
    }

    private func saveScheduleDeadlines() {
        if let data = try? JSONEncoder().encode(scheduleDeadlines) {
            UserDefaults.standard.set(data, forKey: "scheduleDeadlines")
        }
    }

    private func finishSchedule() {
        scheduleTimeout?.cancel()
        scheduleTimeout = nil
        pendingSchedule.removeAll()
        pendingCommand = nil
    }

    private func send(_ data: Data) {
        guard let socket = connection else { return }
        socket.send(content: data, completion: .contentProcessed { [weak self, weak socket] error in
            guard let error else { return }
            Task { @MainActor in
                guard let self, let socket, self.connection === socket else { return }
                self.fail(error.localizedDescription)
            }
        })
    }

    private func receive(_ socket: NWConnection) {
        socket.receive(minimumIncompleteLength: 1, maximumLength: 4096) { [weak self, weak socket] data, _, done, error in
            Task { @MainActor in
                guard let self, let socket, self.connection === socket else { return }
                if let data {
                    self.incoming.append(data)
                    self.processIncoming()
                }
                guard self.connection === socket else { return }
                if let error {
                    self.fail(error.localizedDescription)
                } else if done {
                    self.fail("Брокер закрыл соединение.")
                } else {
                    self.receive(socket)
                }
            }
        }
    }

    private func processIncoming() {
        while incoming.count >= 2 {
            let header = Array(incoming.prefix(5))
            var length = 0
            var offset = 1
            while offset < header.count {
                let byte = header[offset]
                length += Int(byte & 127) << (7 * (offset - 1))
                offset += 1
                if byte < 128 { break }
            }
            guard header[offset - 1] < 128 else {
                if offset == 5 { fail("Некорректная длина пакета MQTT.") }
                return
            }
            guard length <= 2_097_152 else {
                fail("Слишком большой пакет MQTT.")
                return
            }
            guard incoming.count >= offset + length else { return }
            let bytes = Data(incoming.dropFirst(offset).prefix(length))
            incoming = Data(incoming.dropFirst(offset + length))
            if header[0] == 0x20, length == 2, status == .connecting {
                let code = bytes[1]
                guard code == 0, bytes[0] == 0 else {
                    let messages = [1: "Версия MQTT не поддерживается.", 2: "Брокер отклонил идентификатор клиента.", 3: "Брокер недоступен.", 4: "Неверное имя пользователя или пароль.", 5: "Брокер запретил подключение."]
                    fail(messages[Int(code)] ?? "Некорректный ответ на подключение.")
                    return
                }
                timer?.cancel()
                timer = nil
                reconnectDelay = .seconds(2)
                status = .online
                startKeepAlive()
                updateSubscriptions(Set(stripTopics.values), subscribe: true)
            } else if header[0] == 0xD0, length == 0, status == .online {
                awaitingPing = false
            } else if status == .online, header[0] == 0x40, length == 2 {
                let identifier = UInt16(bytes[0]) << 8 | UInt16(bytes[1])
                if pendingSchedule.remove(identifier) != nil, pendingSchedule.isEmpty {
                    if let pendingCommand {
                        scheduleDeadlines[pendingCommand] = Date().addingTimeInterval(300)
                        saveScheduleDeadlines()
                    }
                    finishSchedule()
                }
            } else if status == .online, header[0] == 0x90, length == 3 {
                if bytes[2] == 0x80 { fail("Брокер отклонил подписку на топик яркости.") }
            } else if status == .online, header[0] == 0xB0, length == 2 {
                continue
            } else if status == .online, header[0] & 0xF6 == 0x30, length >= 2 {
                let topicLength = Int(bytes[0]) * 256 + Int(bytes[1])
                guard topicLength > 0, topicLength + 2 <= length else {
                    fail("Некорректный топик входящего сообщения MQTT.")
                    return
                }
                if let topic = String(data: bytes.dropFirst(2).prefix(topicLength), encoding: .utf8),
                   let payload = String(data: bytes.dropFirst(2 + topicLength), encoding: .utf8) {
                    recordBrightness(topic: topic, payload: payload)
                }
            } else {
                fail("Неожиданный пакет MQTT.")
                return
            }
        }
    }

    private func startKeepAlive() {
        timer?.cancel()
        timer = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(15))
                guard !Task.isCancelled, let self, self.status == .online else { return }
                guard !self.awaitingPing else {
                    self.fail("Брокер перестал отвечать.")
                    return
                }
                self.awaitingPing = true
                self.send(Data([0xC0, 0]))
            }
        }
    }

    private func fail(_ message: String) {
        guard !manuallyDisconnected else { return }
        timer?.cancel()
        timer = nil
        connection?.cancel()
        connection = nil
        incoming = Data()
        awaitingPing = false
        status = .failed(message)
        guard let broker = activeBroker else { return }
        reconnectTask?.cancel()
        let delay = reconnectDelay
        reconnectDelay = min(reconnectDelay * 2, .seconds(30))
        reconnectTask = Task { [weak self] in
            try? await Task.sleep(for: delay)
            guard !Task.isCancelled, let self, !self.manuallyDisconnected else { return }
            self.status = .connecting
            self.openConnection(broker, password: self.activePassword)
            self.timer = Task { [weak self] in
                try? await Task.sleep(for: .seconds(10))
                guard !Task.isCancelled, let self, self.status == .connecting else { return }
                self.fail("Брокер не ответил за 10 секунд.")
            }
        }
    }

    private static func field(_ string: String) -> Data {
        let bytes = Data(string.utf8)
        return Data([UInt8(bytes.count >> 8), UInt8(bytes.count & 255)]) + bytes
    }

    private static func packet(_ type: UInt8, _ body: Data) -> Data {
        var header = Data([type])
        var length = body.count
        repeat {
            var byte = UInt8(length % 128)
            length /= 128
            if length > 0 { byte |= 128 }
            header.append(byte)
        } while length > 0
        return header + body
    }
}
