import Foundation

/// A Codable value persisted as a JSON file, safe to share between the app
/// and its extensions. Reads and writes are coordinated on Apple platforms so
/// the keyboard and the app never see half-written files.
public struct JSONFile<Value: Codable> {
    public let url: URL

    public init(name: String, directory: URL = AppGroup.containerURL) {
        self.url = directory.appendingPathComponent(name, isDirectory: false)
    }

    public init(url: URL) {
        self.url = url
    }

    public func load() -> Value? {
        var result: Value?
        coordinate(writing: false) { url in
            guard let data = try? Data(contentsOf: url) else { return }
            result = try? Self.decoder.decode(Value.self, from: data)
        }
        return result
    }

    public func save(_ value: Value) throws {
        let data = try Self.encoder.encode(value)
        var writeError: Error?
        coordinate(writing: true) { url in
            do { try data.write(to: url, options: .atomic) } catch { writeError = error }
        }
        if let writeError { throw writeError }
    }

    /// Load → mutate → save as one coordinated operation. Returns the new value.
    @discardableResult
    public func mutate(default defaultValue: @autoclosure () -> Value,
                       _ body: (inout Value) -> Void) -> Value {
        // Read and write inside a single coordinated write so another process
        // can't sneak a change in between.
        var value = defaultValue()
        coordinate(writing: true) { url in
            if let data = try? Data(contentsOf: url),
               let existing = try? Self.decoder.decode(Value.self, from: data) {
                value = existing
            }
            body(&value)
            if let data = try? Self.encoder.encode(value) {
                try? data.write(to: url, options: .atomic)
            }
        }
        return value
    }

    private func coordinate(writing: Bool, _ body: (URL) -> Void) {
        #if canImport(Darwin)
        let coordinator = NSFileCoordinator(filePresenter: nil)
        var error: NSError?
        if writing {
            coordinator.coordinate(writingItemAt: url, options: .forReplacing, error: &error, byAccessor: body)
        } else {
            coordinator.coordinate(readingItemAt: url, options: [], error: &error, byAccessor: body)
        }
        if error != nil { body(url) }
        #else
        body(url)
        #endif
    }

    static var encoder: JSONEncoder {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .iso8601
        return e
    }

    static var decoder: JSONDecoder {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }
}
