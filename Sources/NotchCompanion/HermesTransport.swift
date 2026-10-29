import Foundation

/// Only an explicit native rejection or a failure before writing a prompt may
/// conform. Timeouts/disconnects must preserve uncertain send intents.
protocol RuntimeDefinitiveRejection: Error {}

@MainActor
protocol RuntimeTransport: AnyObject {
    var onEvent: ((String, [String: Any]) -> Void)? { get set }
    var onConnectionChange: ((Bool, String?) -> Void)? { get set }
    func connect() async throws
    func request(_ method: String, params: [String: Any]) async throws -> [String: Any]
    func disconnect()
}

// Source compatibility for legacy bridge fixtures. New adapters share this
// normalized conversation contract; their wire protocols remain independent.
typealias HermesTransport = RuntimeTransport
extension HermesClient: RuntimeTransport {}
