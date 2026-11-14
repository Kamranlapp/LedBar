import Foundation
import Combine

@MainActor
final class ConfigurationSync: ObservableObject {
    @Published private(set) var config = Configuration.load()
    @Published private(set) var folder: URL?
    @Published private(set) var status = ""
    var onChange: ((Configuration, Bool) -> Void)?

    private var timer: AnyCancellable?
    private var lastData: Data?
    private var pending = false

    func start() {
        if let url = UserDefaults.standard.url(forKey: "syncFolder") { select(url) }
        timer = Timer.publish(every: 3, on: .main, in: .common).autoconnect().sink { [weak self] _ in
            self?.sync()
        }
    }

    func select(_ url: URL) {
        folder = url
        UserDefaults.standard.set(url, forKey: "syncFolder")
        lastData = nil
        pending = false
        sync()
    }

    func stop() {
        folder = nil
        UserDefaults.standard.removeObject(forKey: "syncFolder")
        status = ""
    }

    func update(_ updated: Configuration) {
        apply(updated, remote: false)
        pending = true
    }

    private func apply(_ updated: Configuration, remote: Bool) {
        config = updated
        updated.save()
        onChange?(updated, remote)
    }

    private func sync() {
        guard let folder else { return }
        let file = folder.appendingPathComponent("LedBar-settings.json")
        do {
            if let values = try? file.resourceValues(forKeys: [.ubiquitousItemDownloadingStatusKey]),
               let state = values.ubiquitousItemDownloadingStatus, state != .current {
                try FileManager.default.startDownloadingUbiquitousItem(at: file)
                status = "Ожидание загрузки из iCloud…"
                return
            }

            var coordinationError: NSError?
            var result: Result<Data, Error>?
            NSFileCoordinator().coordinate(readingItemAt: file, options: [], error: &coordinationError) { url in
                result = Result { try Data(contentsOf: url) }
            }
            let data: Data?
            do {
                if let coordinationError { throw coordinationError }
                data = try result?.get()
            } catch let error as NSError where error.domain == NSCocoaErrorDomain && error.code == NSFileReadNoSuchFileError {
                data = nil
            }

            if let data, data != lastData {
                apply(try JSONDecoder().decode(Configuration.self, from: data), remote: true)
                lastData = data
                pending = false
            } else if pending || lastData == nil {
                let encoded = try JSONEncoder().encode(config)
                var writeError: NSError?
                var writeResult: Result<Void, Error>?
                NSFileCoordinator().coordinate(writingItemAt: file, options: .forReplacing, error: &writeError) { url in
                    writeResult = Result { try encoded.write(to: url, options: .atomic) }
                }
                if let writeError { throw writeError }
                try writeResult?.get()
                lastData = encoded
                pending = false
            }
            status = "Синхронизация включена"
        } catch {
            status = "Ошибка синхронизации: \(error.localizedDescription)"
        }
    }
}
