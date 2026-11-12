import SwiftUI

@main
struct LedBarApp: App {
    @NSApplicationDelegateAdaptor(LedBarDelegate.self) private var delegate
    private var mqtt: MQTT { delegate.mqtt }
    @State private var config = Configuration.load()

    var body: some Scene {
        MenuBarExtra("LedBar", systemImage: "lightbulb.led") {
            Controls(config: config, mqtt: mqtt)
                .background(MenuWindowAnimation())
        }
        .menuBarExtraStyle(.window)

        Settings {
            Preferences(config: $config, mqtt: mqtt)
                .onChange(of: encodedConfiguration) { _, _ in
                    config.save()
                    mqtt.trackBrightness(in: config)
                }
        }
    }

    private var encodedConfiguration: Data? {
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        return try? encoder.encode(config)
    }

}

private struct MenuWindowAnimation: NSViewRepresentable {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func makeNSView(context: Context) -> WindowView { WindowView() }

    func updateNSView(_ view: WindowView, context: Context) {
        view.behavior = reduceMotion ? .none : .utilityWindow
    }

    final class WindowView: NSView {
        var behavior: NSWindow.AnimationBehavior = .utilityWindow {
            didSet { window?.animationBehavior = behavior }
        }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            window?.animationBehavior = behavior
        }
    }
}

@MainActor
final class LedBarDelegate: NSObject, NSApplicationDelegate {
    let mqtt = MQTT()

    func applicationDidFinishLaunching(_ notification: Notification) {
        let config = Configuration.load()
        mqtt.trackBrightness(in: config)
        if !config.broker.host.isEmpty { mqtt.connect(config.broker, password: PasswordStore.read()) }
    }
}

struct Controls: View {
    let config: Configuration
    @ObservedObject var mqtt: MQTT
    private var levels: [UUID: Int] { mqtt.levels }

    @GestureState private var masterPreview: CGFloat?

    private var masterLevel: Int {
        let total = config.strips.reduce(0) { $0 + (levels[$1.id] ?? 12) }
        return Int((Double(total) / Double(max(1, config.strips.count))).rounded())
    }

    private func topic(for strip: Strip) -> Topic? {
        config.topics.first { $0.id == strip.topic && $0.isValid }
    }

    private func setLevel(_ level: Int, for strips: [Strip]) {
        for strip in strips {
            guard let topic = topic(for: strip) else { continue }
            mqtt.publish(topic: topic.path, payload: String(level))
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack {
                Text("LedBar").font(.headline)
                Spacer()
                HStack(spacing: 9) {
                    ConnectionStatus(mqtt: mqtt)
                        .help(mqtt.status == .online ? "Подключён" : "Статус MQTT")
                    SettingsLink {
                        Label("Настройки", systemImage: "gearshape")
                    }
                    .simultaneousGesture(TapGesture().onEnded { NSApp.activate(ignoringOtherApps: true) })
                    .help("Настройки")
                    Button {
                        NSApp.terminate(nil)
                    } label: {
                        Label("Выйти", systemImage: "power")
                    }
                    .help("Выйти")
                }
                .labelStyle(.iconOnly)
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
            }

            HStack(alignment: .top, spacing: 6) {
                VStack(spacing: 4) {
                    BrightnessControl(level: masterLevel, name: "Все", sharedGesture: $masterPreview) { level in
                        setLevel(level, for: config.strips)
                    }
                    .disabled(mqtt.status != .online || !config.strips.contains { topic(for: $0) != nil })
                }
                .frame(maxWidth: .infinity)
                Divider().frame(height: 116)
                ForEach(config.strips) { strip in
                    let topic = topic(for: strip)
                    let saved = levels[strip.id] ?? 12
                    VStack(spacing: 4) {
                        BrightnessControl(level: saved, name: strip.name, linkedPreview: topic == nil ? nil : masterPreview) { level in
                            setLevel(level, for: [strip])
                        }
                        .disabled(topic == nil || mqtt.status != .online)

                        if topic == nil {
                            Text("Без топика").font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    .frame(maxWidth: .infinity)
                }
            }

            if !config.commands.isEmpty {
                Divider()
                ScrollView {
                    LazyVGrid(columns: Array(repeating: GridItem(.fixed(56), spacing: 6), count: 4), alignment: .leading, spacing: 6) {
                        ForEach(config.commands) { command in
                            let selected = command.publications.filter { $0.topic != nil }
                            let messages = selected.compactMap { publication -> (topic: String, payload: String)? in
                                guard let topic = config.topics.first(where: { $0.id == publication.topic && $0.isValid }),
                                      publication.payload.utf8.count <= 1_048_576 else { return nil }
                                return (topic.path, publication.payload)
                            }
                            let name = command.name.isEmpty ? "Команда" : command.name
                            Button {
                                for message in messages {
                                    mqtt.publish(topic: message.topic, payload: message.payload)
                                }
                            } label: {
                                Text(name)
                                    .font(.caption.weight(.semibold))
                                    .lineLimit(1)
                                    .padding(.horizontal, 5)
                                    .frame(width: 56, height: 26)
                                    .background(.quaternary, in: RoundedRectangle(cornerRadius: 8))
                                    .overlay {
                                        if mqtt.scheduledCommands.contains(command.id) {
                                            RoundedRectangle(cornerRadius: 8)
                                                .strokeBorder(.green, lineWidth: 1)
                                                .allowsHitTesting(false)
                                        }
                                    }
                                    .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                            .help(name)
                            .overlay {
                                if config.broker.delayedPublishEnabled == true,
                                   !messages.isEmpty, messages.count == selected.count {
                                    SecondaryClick {
                                        mqtt.scheduleInFiveMinutes(commandID: command.id, messages: messages)
                                    }
                                }
                            }
                            .opacity(messages.isEmpty || messages.count != selected.count || mqtt.status != .online ? 0.55 : 1)
                            .disabled(messages.isEmpty || messages.count != selected.count || mqtt.status != .online)
                        }
                    }
                }
                .frame(height: CGFloat(min((config.commands.count + 3) / 4, 4) * 32 - 6))
            }

        }
        .padding(10)
        .frame(width: 264)
    }
}

private struct SecondaryClick: NSViewRepresentable {
    let action: () -> Void

    func makeNSView(context: Context) -> ClickView { ClickView() }

    func updateNSView(_ view: ClickView, context: Context) {
        view.action = action
    }

    final class ClickView: NSView {
        var action: (() -> Void)?

        override func hitTest(_ point: NSPoint) -> NSView? {
            guard NSApp.currentEvent?.type == .rightMouseDown else { return nil }
            return super.hitTest(point)
        }

        override func rightMouseDown(with event: NSEvent) {
            action?()
        }
    }
}

struct BrightnessControl: View {
    let level: Int
    let name: String
    var sharedGesture: GestureState<CGFloat?>?
    var linkedPreview: CGFloat?
    let commit: (Int) -> Void
    @GestureState private var preview: CGFloat?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        let shown = linkedPreview ?? sharedGesture?.wrappedValue ?? preview ?? CGFloat(level) / 12
        VStack(spacing: 4) {
            GeometryReader { geometry in
                let height = geometry.size.height
                ZStack(alignment: .bottom) {
                    RoundedRectangle(cornerRadius: 12).fill(.quaternary)
                    Rectangle()
                        .fill(.linearGradient(colors: [.yellow, Color(red: 1, green: 0.74, blue: 0.32)], startPoint: .top, endPoint: .bottom))
                        .frame(height: height * shown)
                        .animation(reduceMotion ? nil : .easeOut(duration: 0.18), value: level)
                }
                .clipShape(RoundedRectangle(cornerRadius: 12))
                .contentShape(RoundedRectangle(cornerRadius: 12))
                .gesture(DragGesture(minimumDistance: 0, coordinateSpace: .local)
                    .updating(sharedGesture ?? $preview) { value, state, _ in
                        state = fraction(at: value.location.y, height: height)
                    }
                    .onEnded { value in
                        commit(Int((fraction(at: value.location.y, height: height) * 12).rounded()))
                    })
            }
            .frame(width: 45, height: 116)
            VStack(spacing: 2) {
                Text(name)
                    .font(.subheadline.weight(.semibold))
                    .lineLimit(1)
                Text("\(Int((shown * 100).rounded()))%")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
                    .contentTransition(.numericText())
                    .animation(reduceMotion ? nil : .easeOut(duration: 0.18), value: level)
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(name)
        .accessibilityValue("\(Int((Double(level) / 12 * 100).rounded())) процентов")
        .accessibilityAdjustableAction { direction in
            switch direction {
            case .increment: if level < 12 { commit(level + 1) }
            case .decrement: if level > 0 { commit(level - 1) }
            @unknown default: break
            }
        }
    }

    private func fraction(at y: CGFloat, height: CGFloat) -> CGFloat {
        guard height > 0 else { return 0 }
        return min(1, max(0, 1 - y / height))
    }
}

struct ConnectionStatus: View {
    @ObservedObject var mqtt: MQTT

    var body: some View {
        switch mqtt.status {
        case .offline: Label("Отключён", systemImage: "circle").foregroundStyle(.secondary)
        case .connecting: Label("Подключение…", systemImage: "ellipsis").foregroundStyle(.secondary)
        case .online: Label("Подключён", systemImage: "checkmark").foregroundStyle(.green)
        case .failed(let message):
            Label("Ошибка", systemImage: "exclamationmark.circle").foregroundStyle(.red).help(message)
        }
    }
}

struct Preferences: View {
    @Binding var config: Configuration
    @ObservedObject var mqtt: MQTT
    @State private var broker = Broker()
    @State private var password = ""
    @State private var error = ""

    var body: some View {
        TabView {
            Form {
                TextField("Адрес", text: $broker.host, prompt: Text("mqtt.example.com"))
                TextField("Порт", text: $broker.port)
                Toggle("Отложенная публикация EMQX", isOn: Binding(
                    get: { broker.delayedPublishEnabled ?? false },
                    set: { broker.delayedPublishEnabled = $0 }
                ))
                Toggle("TLS", isOn: $broker.tls)
                TextField("Пользователь", text: $broker.username)
                SecureField("Пароль", text: $password)
                HStack {
                    Button("Сохранить и подключить", action: connect).buttonStyle(.borderedProminent)
                    Button("Отключить") { mqtt.disconnect() }
                        .disabled(mqtt.status == .offline)
                }
                ConnectionStatus(mqtt: mqtt)
                if !error.isEmpty { Text(error).foregroundStyle(.red) }
                if case .failed(let message) = mqtt.status { Text(message).foregroundStyle(.red) }
            }
            .formStyle(.grouped)
            .tabItem { Label("MQTT", systemImage: "network") }

            Form {
                Section("Топики") {
                    ForEach($config.topics) { $topic in
                        HStack {
                            TextField("Топик", text: $topic.path, prompt: Text("home/led/brightness"))
                                .labelsHidden()
                            if !topic.isValid && !topic.path.isEmpty {
                                Image(systemName: "exclamationmark.circle")
                                    .foregroundStyle(.red).help("Укажите конкретный MQTT-топик без + и #.")
                            }
                            Button(role: .destructive) { removeTopic(topic.id) } label: {
                                Image(systemName: "trash")
                            }
                            .help("Удалить топик")
                        }
                    }
                    Button("Добавить топик", systemImage: "plus") { config.topics.append(Topic()) }
                }
                Section("Ленты") {
                    ForEach($config.strips) { $strip in
                        HStack {
                            TextField("Название ленты", text: $strip.name).labelsHidden()
                            topicPicker(selection: $strip.topic)
                        }
                    }
                }
            }
            .formStyle(.grouped)
            .tabItem { Label("Топики и ленты", systemImage: "lightbulb.led") }

            Form {
                ForEach($config.commands) { $command in
                    Section {
                        TextField("Название кнопки", text: $command.name)
                        ForEach(command.publications.indices, id: \.self) { index in
                            HStack(alignment: .top, spacing: 12) {
                                topicPicker(selection: $command.publications[index].topic)
                                    .labelsHidden()
                                    .frame(width: 190, alignment: .leading)
                                TextEditor(text: $command.publications[index].payload)
                                    .font(.system(.body, design: .monospaced))
                                    .frame(height: 44)
                                    .accessibilityLabel("Payload \(index + 1)")
                            }
                        }
                        Button("Удалить команду", role: .destructive) {
                            config.commands.removeAll { $0.id == command.id }
                        }
                    }
                }
                Button("Добавить команду", systemImage: "plus") { config.commands.append(Command()) }
            }
            .formStyle(.grouped)
            .tabItem { Label("Команды", systemImage: "bolt") }
        }
        .frame(width: 550, height: 440)
        .onAppear {
            broker = config.broker
            password = PasswordStore.read()
        }
    }

    private func topicPicker(selection: Binding<UUID?>) -> some View {
        Picker("Топик", selection: selection) {
            Text("Выбрать топик").tag(nil as UUID?)
            ForEach(config.topics) { topic in
                Text(topic.path.isEmpty ? "Пустой топик" : topic.path).tag(Optional(topic.id))
            }
        }
    }

    private func removeTopic(_ id: UUID) {
        config.topics.removeAll { $0.id == id }
        for index in config.strips.indices where config.strips[index].topic == id { config.strips[index].topic = nil }
        for index in config.commands.indices {
            for row in config.commands[index].publications.indices
                where config.commands[index].publications[row].topic == id {
                config.commands[index].publications[row].topic = nil
            }
        }
    }

    private func connect() {
        guard PasswordStore.write(password) else {
            error = "Не удалось сохранить пароль в Keychain."
            return
        }
        error = ""
        config.broker = broker
        config.save()
        mqtt.connect(broker, password: password)
    }
}
