import Foundation
import Network

// The wrapper reads this one policy constant from the pinned package.
enum ContinuityLibraryServer { static let approvalTimeout: TimeInterval = 120 }

final class DelayedHTTPServer {
    let listener: NWListener
    let queue = DispatchQueue(label: "icube.approval-timeout-probe")
    init() throws {
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = .hostPort(host: .ipv4(.loopback), port: .any)
        listener = try NWListener(using: parameters)
        listener.newConnectionHandler = { [queue] connection in
            connection.start(queue: queue)
            connection.receive(minimumIncompleteLength: 1, maximumLength: 65536) { data, _, _, _ in
                guard data != nil else { connection.cancel(); return }
                queue.asyncAfter(deadline: .now() + 65) {
                    let body = Data("HTTP/1.1 200 OK\r\nContent-Length: 3\r\nConnection: close\r\n\r\nabc".utf8)
                    connection.send(content: body, completion: .contentProcessed { _ in connection.cancel() })
                }
            }
        }
    }
    func start() async throws -> URL {
        try await withCheckedThrowingContinuation { continuation in
            listener.stateUpdateHandler = { [listener] state in
                switch state {
                case .ready:
                    listener.stateUpdateHandler = nil
                    continuation.resume(returning: URL(string: "http://127.0.0.1:\(listener.port!.rawValue)")!)
                case .failed(let error):
                    listener.stateUpdateHandler = nil
                    continuation.resume(throwing: error)
                default: break
                }
            }
            listener.start(queue: queue)
        }
    }
}

@main struct Probe {
    static func main() async throws {
        let server = try DelayedHTTPServer()
        let base = try await server.start()
        let transport = ICubeContinuityTransport()
        let start = Date()
        let normal = Task { () -> Bool in
            do {
                _ = try await transport.request(.init(url: base.appendingPathComponent(ContinuityRoutes.libraryCatalog)))
                print("FAIL ordinary browse unexpectedly waited for approval")
                return false
            } catch {
                let elapsed = Date().timeIntervalSince(start)
                print("Ordinary browse timed out after \(elapsed)s: \(error)")
                return elapsed < 30
            }
        }
        let file = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".part")
        defer { try? FileManager.default.removeItem(at: file); server.listener.cancel() }
        var approvalPassed = false
        do {
            let bytes = try await transport.download(
                .init(url: base.appendingPathComponent(ContinuityRoutes.libraryFile)),
                to: file, resumeOffset: 0, progress: nil
            )
            let elapsed = Date().timeIntervalSince(start)
            let received = try Data(contentsOf: file)
            approvalPassed = bytes == 3 && elapsed > 60 && received == Data("abc".utf8)
            print("Approval route returned \(bytes) verified fixture bytes after \(elapsed)s")
        } catch {
            print("FAIL approval route: \(Date().timeIntervalSince(start))s \(error)")
        }
        let normalPassed = await normal.value
        print(normalPassed && approvalPassed ? "PASS actual app wrapper preserves fast browse and waits beyond60s for owner approval" : "FAIL route timeout policy")
        exit(normalPassed && approvalPassed ? 0 : 1)
    }
}
