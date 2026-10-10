//
//  TemplateAppTests.swift
//  TemplateAppTests
//
//  Created by 上杉侑斗 on 2026/08/21.
//

import Foundation
import Testing
@testable import TemplateApp

struct TemplateAppTests {

    @Test("Welcome message is localized in English and Japanese")
    func welcomeMessageLocalizations() {
        #expect(localizedValue(for: "template.welcome", language: "en") == "Ready to build")
        #expect(localizedValue(for: "template.welcome", language: "ja") == "開発を始められます")
    }

    private func localizedValue(for key: String, language: String) -> String? {
        guard let localizationURL = Bundle.main.url(
            forResource: language,
            withExtension: "lproj"
        ), let localizationBundle = Bundle(url: localizationURL) else {
            return nil
        }

        return localizationBundle.localizedString(forKey: key, value: nil, table: nil)
    }
}

/// Answers every request from the test's closure and records what was sent.
nonisolated final class FeedbackURLProtocol: URLProtocol, @unchecked Sendable {
    nonisolated(unsafe) static var respond: ((URLRequest) throws -> Int)?
    nonisolated(unsafe) static var request: URLRequest?
    nonisolated(unsafe) static var body: Data?

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        Self.request = request
        Self.body = request.httpBodyStream.map(Self.read)
        do {
            let status = try Self.respond?(request) ?? 201
            let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: Data("{}".utf8))
            client?.urlProtocolDidFinishLoading(self)
        } catch {
            client?.urlProtocol(self, didFailWithError: error)
        }
    }

    override func stopLoading() {}

    private static func read(_ stream: InputStream) -> Data {
        stream.open()
        defer { stream.close() }
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 1024)
        while stream.hasBytesAvailable {
            let count = stream.read(&buffer, maxLength: buffer.count)
            if count <= 0 { break }
            data.append(buffer, count: count)
        }
        return data
    }
}

/// In-app feedback (D-076). The canonical run executes `payloadMatchesWorkerContract()`, so it covers the
/// whole client contract: the payload, the bundled host setting, the status mapping, and the privacy manifest.
@Suite(.serialized)
@MainActor
struct FeedbackTests {
    private let endpoint = URL(string: "https://feedback.example.dev/v1/feedback")!
    private let environment = FeedbackEnvironment(
        appVersion: "1.0", build: "1", osVersion: "27.0", deviceModel: "iPhone18,2", locale: "ja-JP"
    )

    private func stubbedClient() -> FeedbackClient {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [FeedbackURLProtocol.self]
        return FeedbackClient(endpoint: endpoint, session: URLSession(configuration: configuration))
    }

    @Test("Screenshots can open the feedback sheet at launch, and only when asked")
    func feedbackOpensOnLaunchOnlyWhenAsked() {
        #expect(FeedbackEntryButton.opensOnLaunch(arguments: ["App", "-FeedbackOpen"]))
        #expect(!FeedbackEntryButton.opensOnLaunch(arguments: ["App", "-FeedbackStub", "offline-then-success"]))
    }

    @Test("Feedback matches the Worker's contract, endpoint setting, status mapping and privacy manifest")
    func payloadMatchesWorkerContract() async throws {
        // The payload carries exactly the seven fields the Worker accepts, within its limits.
        var draft = FeedbackDraft()
        draft.body = "  \n "
        #expect(!draft.isValid)
        draft.body = "  Crash on launch \n"
        #expect(draft.validatedBody() == "Crash on launch")
        draft.body = String(repeating: "a", count: 2001)
        #expect(!draft.isValid)
        #expect(FeedbackCategory.allCases.map(\.rawValue) == ["bug", "request", "other"])
        let payload = FeedbackPayload(category: .request, body: "Crash on launch", environment: environment)
        let object = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(payload)) as? [String: String])
        #expect(Set(object.keys) == ["category", "body", "appVersion", "build", "osVersion", "deviceModel", "locale"])
        #expect(object["category"] == "request")
        // One family emoji is one character but 25 bytes, so 2000 of them pass the character limit
        // and still exceed the Worker's 8KB request cap.
        draft.body = String(repeating: "👨‍👩‍👧‍👦", count: 2000)
        #expect(draft.isValid)
        let emoji = FeedbackPayload(category: .bug, body: draft.body, environment: environment)
        #expect(!emoji.fitsRequestLimit, "2000 family emoji exceed the Worker's 8KB request cap")
        let current = FeedbackEnvironment.current(processEnvironment: ["SIMULATOR_MODEL_IDENTIFIER": "iPhone18,2"])
        for value in [current.appVersion, current.build, current.osVersion, current.deviceModel, current.locale] {
            #expect(value.wholeMatch(of: /[A-Za-z0-9 ._,()+-]{1,64}/) != nil, "\(value)")
        }
        #expect(FeedbackEnvironment.sanitized("<@mention>`x`") == "mentionx")
        #expect(FeedbackEnvironment.sanitized("!!!") == "unknown")
        #expect(FeedbackEnvironment.sanitized(String(repeating: "a", count: 80)).count == 64)

        // The host is a plain lower-case host name from the bundled setting; the template ships it empty,
        // so a fresh app hides the entry until the provisioning tool writes the host.
        for host in [nil, "", "https://feedback.example.dev", "feedback", "Feedback.Example.dev", "feedback.example.dev/v1"] {
            #expect(FeedbackConfiguration.endpoint(host: host) == nil, "\(String(describing: host))")
        }
        #expect(FeedbackConfiguration.endpoint(host: "garden-notes-feedback.example.workers.dev")
            == URL(string: "https://garden-notes-feedback.example.workers.dev/v1/feedback"))
        #expect(FeedbackConfiguration.host() == "")
        #expect(FeedbackConfiguration.endpoint() == nil)
        #expect(FeedbackSenderFactory.make(arguments: []) == nil)
        #expect(FeedbackSenderFactory.make(arguments: ["-FeedbackStub", "rate-limited"]) is ScriptedFeedbackSender)

        // Sending: no shared cookies, a JSON POST with a 15 second timeout, and the status mapping.
        let session = FeedbackClient(endpoint: endpoint).session
        #expect(session.configuration.httpCookieStorage !== HTTPCookieStorage.shared)
        #expect(session.configuration.httpShouldSetCookies == false)
        FeedbackURLProtocol.respond = { _ in 201 }
        try await stubbedClient().send(payload)
        let request = try #require(FeedbackURLProtocol.request)
        #expect(request.url == endpoint)
        #expect(request.httpMethod == "POST")
        #expect(request.value(forHTTPHeaderField: "Content-Type") == "application/json")
        #expect(request.value(forHTTPHeaderField: "Authorization") == nil)
        #expect(request.timeoutInterval == 15)
        let sent = try #require(FeedbackURLProtocol.body)
        #expect((try JSONSerialization.jsonObject(with: sent) as? [String: String])?.count == 7)
        FeedbackURLProtocol.respond = { _ in 429 }
        await #expect(throws: FeedbackSendError.rateLimited) { try await stubbedClient().send(payload) }
        for status in [400, 404, 500, 502, 503] {
            FeedbackURLProtocol.respond = { _ in status }
            await #expect(throws: FeedbackSendError.server) { try await stubbedClient().send(payload) }
        }
        for code in [URLError.Code.notConnectedToInternet, .timedOut, .networkConnectionLost, .cannotFindHost] {
            FeedbackURLProtocol.respond = { _ in throw URLError(code) }
            await #expect(throws: FeedbackSendError.offline) { try await stubbedClient().send(payload) }
        }
        FeedbackURLProtocol.respond = { _ in throw URLError(.badServerResponse) }
        await #expect(throws: FeedbackSendError.server) { try await stubbedClient().send(payload) }
        let scripted = ScriptedFeedbackSender(script: "offline-then-success")
        await #expect(throws: FeedbackSendError.offline) { try await scripted.send(payload) }
        try await scripted.send(payload)

        // The privacy manifest declares the message as Customer Support and the device details as
        // Other Diagnostic Data, unlinked, untracked, for app functionality.
        let manifestURL = try #require(Bundle.main.url(forResource: "PrivacyInfo", withExtension: "xcprivacy"))
        let manifest = try #require(
            PropertyListSerialization.propertyList(from: Data(contentsOf: manifestURL), format: nil) as? [String: Any]
        )
        #expect(manifest["NSPrivacyTracking"] as? Bool == false)
        let collected = try #require(manifest["NSPrivacyCollectedDataTypes"] as? [[String: Any]])
        #expect(Set(collected.compactMap { $0["NSPrivacyCollectedDataType"] as? String }) == [
            "NSPrivacyCollectedDataTypeCustomerSupport", "NSPrivacyCollectedDataTypeOtherDiagnosticData",
        ])
        for entry in collected {
            #expect(entry["NSPrivacyCollectedDataTypeLinked"] as? Bool == false)
            #expect(entry["NSPrivacyCollectedDataTypeTracking"] as? Bool == false)
            #expect(entry["NSPrivacyCollectedDataTypePurposes"] as? [String] == ["NSPrivacyCollectedDataTypePurposeAppFunctionality"])
        }
    }
}
