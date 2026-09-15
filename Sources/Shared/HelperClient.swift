import Foundation

struct AWDLStatus: Sendable {
    let enabled: Bool
    let interfaceUp: Bool?
    let monitoring: Bool
    let issue: String?

    init(_ dictionary: [String: Any]) throws {
        guard let enabled = dictionary["enabled"] as? Bool,
              let monitoring = dictionary["monitoring"] as? Bool else {
            throw HelperFailure.message("The helper returned an invalid status. Reinstall AWDL Toggle.")
        }
        self.enabled = enabled
        self.monitoring = monitoring
        self.interfaceUp = dictionary["interfaceUp"] as? Bool
        self.issue = dictionary["issue"] as? String
    }

    var summary: String {
        if let issue { return issue }
        if !monitoring { return "The interface monitor is unavailable." }
        if interfaceUp == nil { return "Waiting for the AWDL interface to become available." }
        return enabled ? "AWDL is allowed. AirDrop and Continuity can use it."
                       : "AWDL is held down, even if macOS tries to enable it."
    }
}

enum HelperFailure: LocalizedError {
    case message(String)
    var errorDescription: String? {
        switch self { case .message(let text): return text }
    }
}

// One connection per request: a WidgetKit extension may be suspended at any time.
// The helper owns the persistent state and never uses client lifetime as a signal.
final class HelperRequest: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<AWDLStatus, Error>?
    private var connection: NSXPCConnection?

    init(_ continuation: CheckedContinuation<AWDLStatus, Error>) {
        self.continuation = continuation
    }

    func finish(_ result: Result<AWDLStatus, Error>) {
        lock.lock()
        let pending = continuation
        continuation = nil
        let active = connection
        connection = nil
        lock.unlock()
        guard let pending else { return }
        active?.invalidate()
        pending.resume(with: result)
    }

    func start(enabled: Bool?, connection supplied: NSXPCConnection? = nil, timeout: TimeInterval = 5) {
        let active = supplied ?? NSXPCConnection(machServiceName: "local.vitaly.AWDLToggle.Helper", options: .privileged)
        active.remoteObjectInterface = NSXPCInterface(with: AWDLHelperProtocol.self)
        connection = active
        active.interruptionHandler = { [weak self] in
            self?.finish(.failure(HelperFailure.message("The connection to the AWDL helper was interrupted. Open AWDL Toggle to check the installation.")))
        }
        active.invalidationHandler = { [weak self] in
            self?.finish(.failure(HelperFailure.message("The AWDL helper is unavailable. Open AWDL Toggle for setup instructions.")))
        }
        active.resume()
        let remote = active.remoteObjectProxyWithErrorHandler { error in
            self.finish(.failure(HelperFailure.message("Cannot contact the AWDL helper. Open AWDL Toggle to repair the installation. (\(error.localizedDescription))")))
        } as? AWDLHelperProtocol
        guard let remote else {
            finish(.failure(HelperFailure.message("Cannot create a connection to the AWDL helper.")))
            return
        }
        let reply: ([String: Any]?, Error?) -> Void = { dictionary, error in
            if let error { self.finish(.failure(error)); return }
            do {
                guard let dictionary else { throw HelperFailure.message("The AWDL helper returned no status.") }
                self.finish(.success(try AWDLStatus(dictionary)))
            } catch { self.finish(.failure(error)) }
        }
        if let enabled { remote.setAWDLEnabled(enabled, withReply: reply) }
        else { remote.getStatusWithReply(reply) }
        DispatchQueue.global().asyncAfter(deadline: .now() + timeout) {
            self.finish(.failure(HelperFailure.message("The AWDL helper did not respond. Please try again.")))
        }
    }
}

enum HelperClient {
    static func status() async throws -> AWDLStatus { try await request(enabled: nil) }
    static func setEnabled(_ enabled: Bool) async throws -> AWDLStatus { try await request(enabled: enabled) }
    private static func request(enabled: Bool?) async throws -> AWDLStatus {
        try await withCheckedThrowingContinuation { continuation in
            HelperRequest(continuation).start(enabled: enabled)
        }
    }
}

// The setup window keeps one authenticated connection open. Widgets and CLI
// requests remain short-lived; disconnecting never changes the saved policy.
final class HelperObservation: NSObject, AWDLStatusObserver, @unchecked Sendable {
    private let lock = NSLock()
    private var connection: NSXPCConnection?
    private var continuation: AsyncThrowingStream<AWDLStatus, Error>.Continuation?
    private var receivedInitial = false

    static func stream(connection supplied: NSXPCConnection? = nil,
                       timeout: TimeInterval = 5) -> AsyncThrowingStream<AWDLStatus, Error> {
        AsyncThrowingStream { continuation in
            let observer = HelperObservation()
            observer.continuation = continuation
            continuation.onTermination = { [observer] _ in observer.finish(nil) }
            observer.start(connection: supplied, timeout: timeout)
        }
    }

    private func start(connection supplied: NSXPCConnection?, timeout: TimeInterval) {
        let active = supplied ?? NSXPCConnection(machServiceName: "local.vitaly.AWDLToggle.Helper", options: .privileged)
        connection = active
        active.remoteObjectInterface = NSXPCInterface(with: AWDLHelperProtocol.self)
        active.exportedInterface = NSXPCInterface(with: AWDLStatusObserver.self)
        active.exportedObject = self
        active.invalidationHandler = { [weak self] in self?.disconnected() }
        active.interruptionHandler = { [weak self] in self?.disconnected() }
        active.resume()
        let proxy = active.remoteObjectProxyWithErrorHandler { [weak self] error in
            self?.finish(error)
        } as? AWDLHelperProtocol
        proxy?.observeStatus()
        DispatchQueue.global().asyncAfter(deadline: .now() + timeout) { [weak self] in
            guard let self else { return }
            self.lock.lock()
            let missing = !self.receivedInitial
            self.lock.unlock()
            if missing { self.finish(HelperFailure.message("The AWDL helper did not respond.")) }
        }
    }

    func statusDidChange(_ dictionary: [String: Any]) {
        do {
            let status = try AWDLStatus(dictionary)
            lock.lock()
            receivedInitial = true
            let pending = continuation
            lock.unlock()
            pending?.yield(status)
        } catch { finish(error) }
    }

    private func disconnected() {
        finish(HelperFailure.message("The AWDL helper is unavailable. Reconnecting…"))
    }

    private func finish(_ error: Error?) {
        lock.lock()
        let active = connection
        let pending = continuation
        connection = nil
        continuation = nil
        lock.unlock()
        active?.invalidate()
        if let error { pending?.finish(throwing: error) }
        else { pending?.finish() }
    }
}
