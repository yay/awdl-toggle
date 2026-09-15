import Foundation

final class FakeService: NSObject, AWDLHelperProtocol, NSXPCListenerDelegate {
    var enabled = true
    var replyEnabled = true
    var reject = false
    let queue = DispatchQueue(label: "fake-service")
    func listener(_ listener: NSXPCListener, shouldAcceptNewConnection connection: NSXPCConnection) -> Bool {
        if reject { return false }
        connection.exportedInterface = NSXPCInterface(with: AWDLHelperProtocol.self)
        connection.exportedObject = self
        connection.resume()
        return true
    }
    func getStatusWithReply(_ reply: @escaping ([String: Any]?, Error?) -> Void) {
        queue.async {
            guard self.replyEnabled else { return }
            reply(["enabled": self.enabled, "monitoring": true, "interfaceUp": self.enabled], nil)
        }
    }
    func setAWDLEnabled(_ enabled: Bool, withReply reply: @escaping ([String: Any]?, Error?) -> Void) {
        queue.async {
            guard self.replyEnabled else { return }
            self.enabled = enabled
            reply(["enabled": self.enabled, "monitoring": true, "interfaceUp": self.enabled], nil)
        }
    }
}

@main
enum ClientTests {
    static func main() async throws {
        let service = FakeService()
        let listener = NSXPCListener.anonymous()
        listener.delegate = service
        listener.resume()
        func request(_ enabled: Bool? = nil, timeout: TimeInterval = 1) async throws -> AWDLStatus {
            try await withCheckedThrowingContinuation { continuation in
                HelperRequest(continuation).start(enabled: enabled,
                    connection: NSXPCConnection(listenerEndpoint: listener.endpoint), timeout: timeout)
            }
        }
        let initial = try await request()
        precondition(initial.enabled)
        let changed = try await request(false)
        precondition(!changed.enabled && changed.interfaceUp == false)
        let afterDisconnect = try await request()
        precondition(!afterDisconnect.enabled, "Disconnect must not reset policy")
        for index in 0..<20 {
            let status = try await request(index.isMultiple(of: 2))
            precondition(status.enabled == index.isMultiple(of: 2))
        }
        let final = try await request()
        precondition(!final.enabled)
        service.queue.sync { service.replyEnabled = false }
        do {
            _ = try await request(timeout: 0.05)
            fatalError("Missing reply must time out")
        } catch {
            precondition(error.localizedDescription.contains("did not respond"))
        }
        listener.invalidate()
        do {
            _ = try await request(timeout: 0.1)
            fatalError("Invalid connection must fail")
        } catch { /* Invalidation and timeout may race; only one resumes the caller. */ }
        print("PASS: XPC round trips, 20 rapid requests, disconnect persistence, timeout, and invalidation")
    }
}
