import Foundation

enum FeedbackSendError: Error, Equatable {
    case offline
    case rateLimited
    case server
}

protocol FeedbackSending: Sendable {
    func send(_ payload: FeedbackPayload) async throws
}

/// Where feedback goes. The host comes from `FeedbackEndpoint.json`, which the app bundles and the
/// feedback provisioning tool fills in (D-076). It is not in Info.plist, so enabling another
/// integration that replaces Info.plist cannot drop it. An empty or malformed host means the build
/// has no feedback endpoint, and the entry stays hidden.
enum FeedbackConfiguration {
    static let resourceName = "FeedbackEndpoint"

    private struct Settings: Decodable {
        let host: String
    }

    static func endpoint(host: String?) -> URL? {
        guard let host, host.wholeMatch(of: /[a-z0-9-]+(\.[a-z0-9-]+)+/) != nil else { return nil }
        return URL(string: "https://\(host)/v1/feedback")
    }

    static func host(bundle: Bundle = .main) -> String? {
        guard let url = bundle.url(forResource: resourceName, withExtension: "json"),
              let data = try? Data(contentsOf: url),
              let settings = try? JSONDecoder().decode(Settings.self, from: data) else { return nil }
        return settings.host
    }

    static func endpoint(bundle: Bundle = .main) -> URL? {
        endpoint(host: host(bundle: bundle))
    }
}

/// Sends feedback to the app's feedback Worker. No credentials: the Worker holds them.
struct FeedbackClient: FeedbackSending {
    let endpoint: URL
    var session: URLSession = Self.unlinkedSession

    /// No shared cookies or cache, so one submission cannot be linked to another.
    private static let unlinkedSession: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpShouldSetCookies = false
        configuration.httpCookieAcceptPolicy = .never
        return URLSession(configuration: configuration)
    }()

    private static let offlineCodes: Set<URLError.Code> = [
        .notConnectedToInternet, .networkConnectionLost, .timedOut, .cannotFindHost,
        .cannotConnectToHost, .dataNotAllowed, .internationalRoamingOff,
    ]

    func send(_ payload: FeedbackPayload) async throws {
        var request = URLRequest(url: endpoint, timeoutInterval: 15)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONEncoder().encode(payload)
        let response: URLResponse
        do {
            (_, response) = try await session.data(for: request)
        } catch let error as URLError where Self.offlineCodes.contains(error.code) {
            throw FeedbackSendError.offline
        } catch {
            throw FeedbackSendError.server
        }
        switch (response as? HTTPURLResponse)?.statusCode {
        case 201: return
        case 429: throw FeedbackSendError.rateLimited
        default: throw FeedbackSendError.server
        }
    }
}

/// UI tests only (`-FeedbackStub <script>` in a Debug build): answers without the network.
final class ScriptedFeedbackSender: FeedbackSending {
    private var results: [FeedbackSendError?]

    init(script: String) {
        switch script {
        case "offline-then-success": results = [.offline, nil]
        case "rate-limited": results = [.rateLimited]
        default: results = [nil]
        }
    }

    func send(_ payload: FeedbackPayload) async throws {
        try await Task.sleep(for: .milliseconds(300))
        let next = results.count > 1 ? results.removeFirst() : results[0]
        if let next { throw next }
    }
}

enum FeedbackSenderFactory {
    /// The scripted sender in Debug UI tests; otherwise the bundled endpoint, or nil when unset.
    static func make(arguments: [String] = ProcessInfo.processInfo.arguments, bundle: Bundle = .main) -> (any FeedbackSending)? {
        #if DEBUG
        if let index = arguments.firstIndex(of: "-FeedbackStub"), arguments.indices.contains(index + 1) {
            return ScriptedFeedbackSender(script: arguments[index + 1])
        }
        #endif
        return FeedbackConfiguration.endpoint(bundle: bundle).map { FeedbackClient(endpoint: $0) }
    }
}
