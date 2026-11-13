import XCTest
@testable import SentinelCore

final class MockHTTPTransport: HTTPTransport {
    final class Handle: HTTPCancellable {
        var cancelled = false
        func cancel() { cancelled = true }
    }

    var sent: [PreparedRequest] = []
    var handles: [Handle] = []
    var completions: [(Result<HTTPResponseRecord, RequestExecutionError>) -> Void] = []
    var immediateResult: Result<HTTPResponseRecord, RequestExecutionError>?

    func send(_ request: PreparedRequest, timeout: TimeInterval,
              completion: @escaping (Result<HTTPResponseRecord, RequestExecutionError>) -> Void) -> HTTPCancellable {
        sent.append(request)
        let handle = Handle()
        handles.append(handle)
        if let result = immediateResult { completion(result) } else { completions.append(completion) }
        return handle
    }

    static func response(_ status: Int, body: String = "ok") -> HTTPResponseRecord {
        HTTPResponseRecord(statusCode: status, headers: [PreparedRequest.Header(name: "Content-Type", value: "text/plain")],
                           body: Data(body.utf8), bodyTruncated: false, totalBodyBytes: body.utf8.count,
                           startedAt: Date(), duration: 0.042)
    }
}

final class RequestBuilderTests: XCTestCase {
    private func endpoint(_ string: String = "http://127.0.0.1:8080") throws -> TestEndpoint {
        try TestEndpoint(string: string)
    }

    func testEndpointValidation() throws {
        XCTAssertEqual(try endpoint(" https://Test.HCG.example ").host, "test.hcg.example")
        XCTAssertEqual(try endpoint("https://test.hcg.example").port, 443)
        XCTAssertEqual(try endpoint().port, 8080)
        XCTAssertThrowsError(try endpoint("")) { XCTAssertEqual($0 as? RequestValidationError, .noEndpoint) }
        for bad in ["ftp://host", "host:80", "http://", "http://user:pw@host", "http://host/api", "http://host?x=1", "http://host#frag"] {
            XCTAssertThrowsError(try endpoint(bad), bad) { error in
                guard case .invalidEndpoint? = error as? RequestValidationError else { return XCTFail("\(bad): \(error)") }
            }
        }
    }

    func testPreparesRequestWithinEndpoint() throws {
        var draft = RequestDraft.template
        draft.method = .POST
        draft.url = "/echo?mode=test"
        draft.headers.append(HeaderField(name: "Content-Type", value: "application/json"))
        draft.headers.append(HeaderField(name: "X-Disabled", value: "1", isEnabled: false))
        draft.headers.append(HeaderField(name: "", value: ""))
        draft.body = #"{"a":1}"#
        let prepared = try RequestBuilder.prepare(draft, endpoint: endpoint())
        XCTAssertEqual(prepared.url.absoluteString, "http://127.0.0.1:8080/echo?mode=test")
        XCTAssertEqual(prepared.headers.map { $0.name }, ["Accept", "User-Agent", "Content-Type"])
        XCTAssertEqual(prepared.body, Data(#"{"a":1}"#.utf8))
    }

    func testRejectsRequestsThatWouldLeaveTheEndpoint() throws {
        let target = try endpoint()
        XCTAssertThrowsError(try RequestBuilder.prepare(RequestDraft(), endpoint: nil)) {
            XCTAssertEqual($0 as? RequestValidationError, .noEndpoint)
        }
        for path in ["//evil.example/x", "http://evil.example/", "relative", "/a b", "/x\\y", "@evil.example/", ":9/x", "/a\nb"] {
            XCTAssertThrowsError(try RequestBuilder.prepare(RequestDraft(url: path), endpoint: target), path)
        }
        let prepared = try RequestBuilder.prepare(RequestDraft(url: "/@evil.example/x"), endpoint: target)
        XCTAssertEqual(prepared.url.host, "127.0.0.1")
        XCTAssertFalse(target.contains(URL(string: "http://127.0.0.1:8081/")!))
        XCTAssertFalse(target.contains(URL(string: "https://127.0.0.1:8080/")!))
        XCTAssertFalse(target.contains(URL(string: "http://127.0.0.1.evil.example:8080/")!))
        XCTAssertTrue(target.contains(URL(string: "http://127.0.0.1:8080/any/path?q=1")!))
    }

    func testFullURLsMustMatchAnAllowedEndpoint() throws {
        let endpoints = TestEndpoint.parseList(["http://127.0.0.1:8080", "https://test.hcg.example", "nonsense", " ", "http://127.0.0.1:8080"])
        XCTAssertEqual(endpoints.endpoints.map { $0.displayString }, ["http://127.0.0.1:8080", "https://test.hcg.example"])
        XCTAssertEqual(endpoints.problems.count, 1, "invalid entries are reported, blanks and duplicates skipped")
        let allowed = endpoints.endpoints

        var prepared = try RequestBuilder.prepare(RequestDraft(url: "https://test.hcg.example/api/v1?x=1"), endpoints: allowed)
        XCTAssertEqual(prepared.url.absoluteString, "https://test.hcg.example/api/v1?x=1")
        XCTAssertEqual(prepared.endpoint, "https://test.hcg.example")
        prepared = try RequestBuilder.prepare(RequestDraft(url: "/health"), endpoints: allowed)
        XCTAssertEqual(prepared.url.absoluteString, "http://127.0.0.1:8080/health", "paths use the primary endpoint")
        XCTAssertNoThrow(try RequestBuilder.prepare(RequestDraft(url: "HTTPS://TEST.HCG.EXAMPLE:443/"), endpoints: allowed))

        func error(_ url: String) -> RequestValidationError? {
            do { _ = try RequestBuilder.prepare(RequestDraft(url: url), endpoints: allowed); return nil }
            catch { return error as? RequestValidationError }
        }
        XCTAssertEqual(error("https://evil.example/"), .offEndpoint)
        XCTAssertEqual(error("http://test.hcg.example/"), .offEndpoint, "scheme must match")
        XCTAssertEqual(error("https://test.hcg.example:8443/"), .offEndpoint, "port must match")
        XCTAssertEqual(error("http://127.0.0.1:8081/"), .offEndpoint)
        XCTAssertEqual(error("https://test.hcg.example.evil.example/"), .offEndpoint)
        XCTAssertEqual(error("https://user:pw@test.hcg.example/"), .invalidURL)
        XCTAssertEqual(error("ftp://test.hcg.example/"), .invalidURL)
        XCTAssertEqual(error("https://test.hcg.example/a b"), .invalidURL)
        XCTAssertEqual(error("test.hcg.example/x"), .invalidURL)
        XCTAssertThrowsError(try RequestBuilder.prepare(RequestDraft(url: "/"), endpoints: [])) {
            XCTAssertEqual($0 as? RequestValidationError, .noEndpoint)
        }
    }

    func testResponseFormatting() throws {
        let json = Data(#"{"b":[1,2],"a":"x"}"#.utf8)
        XCTAssertEqual(ResponseFormatter.suggestedFormat(for: json), .json)
        let pretty = ResponseFormatter.render(json, as: .json)
        let a = try XCTUnwrap(pretty.range(of: "\"a\""))
        let b = try XCTUnwrap(pretty.range(of: "\"b\""))
        XCTAssertTrue(a.lowerBound < b.lowerBound, "keys are sorted")
        XCTAssertTrue(pretty.contains("\n"), "pretty-printed over several lines")
        XCTAssertEqual(ResponseFormatter.render(Data("plain".utf8), as: .json), "The body is not valid JSON.")
        XCTAssertEqual(ResponseFormatter.suggestedFormat(for: Data("hello".utf8)), .text)
        let binary = Data([0xff, 0xfe, 0x00, 0x41])
        XCTAssertEqual(ResponseFormatter.suggestedFormat(for: binary), .hex)
        XCTAssertTrue(ResponseFormatter.render(binary, as: .hex).hasPrefix("0000  ff fe 00 41"))
        XCTAssertTrue(ResponseFormatter.render(binary, as: .text).contains("not valid UTF-8"))
        let long = ResponseFormatter.render(Data(String(repeating: "a", count: 50).utf8), as: .text, limit: 10)
        XCTAssertTrue(long.hasSuffix("40 more characters not shown"))
        XCTAssertEqual(ResponseFormatter.render(Data(), as: .json), "")
    }

    func testHeaderAndBodyValidation() throws {
        let target = try endpoint()
        func error(_ draft: RequestDraft) -> RequestValidationError? {
            do { _ = try RequestBuilder.prepare(draft, endpoint: target); return nil } catch { return error as? RequestValidationError }
        }
        XCTAssertEqual(error(RequestDraft(headers: [HeaderField(name: "Bad Name", value: "x")])), .invalidHeaderName("Bad Name"))
        XCTAssertEqual(error(RequestDraft(headers: [HeaderField(name: "X-A", value: "a\r\nInjected: 1")])), .invalidHeaderValue("X-A"))
        XCTAssertEqual(error(RequestDraft(headers: [HeaderField(name: "Host", value: "evil.example")])), .managedHeader("Host"))
        XCTAssertEqual(error(RequestDraft(headers: [HeaderField(name: "content-length", value: "5")])), .managedHeader("content-length"))
        XCTAssertEqual(error(RequestDraft(method: .GET, body: "data")), .bodyNotAllowed("GET"))
        let huge = String(repeating: "a", count: RequestBuilder.maxBodyBytes + 1)
        XCTAssertEqual(error(RequestDraft(method: .POST, body: huge)), .bodyTooLarge(RequestBuilder.maxBodyBytes))
        XCTAssertNil(error(RequestDraft(method: .DELETE, url: "/items/1")))
    }

    func testPreviewListsEveryChange() {
        let baseline = RequestDraft.template
        var draft = baseline
        XCTAssertTrue(RequestPreview.changes(from: baseline, to: draft).isEmpty)
        draft.method = .PUT
        draft.url = "/v2"
        draft.headers[0].value = "application/json"
        draft.headers[1].isEnabled = false
        draft.headers.append(HeaderField(name: "X-Test", value: "1"))
        draft.body = "hello"
        let changes = RequestPreview.changes(from: baseline, to: draft)
        XCTAssertEqual(changes.map { $0.kind }, [.method, .url, .headerChanged, .headerRemoved, .headerAdded, .body])
        XCTAssertEqual(changes[0].before, "GET")
        XCTAssertEqual(changes[0].after, "PUT")
        XCTAssertEqual(changes[2].subject, "Accept")
        XCTAssertEqual(changes[3].subject, "User-Agent")
        XCTAssertEqual(changes[4].title, "Header added: X-Test")
        XCTAssertEqual(changes[5].after, "5 bytes")
    }

    func testRawTextCanBeRedacted() throws {
        let draft = RequestDraft(method: .POST, url: "/login?session=abc",
                                 headers: [HeaderField(name: "Authorization", value: "Bearer supersecret"),
                                           HeaderField(name: "Accept", value: "*/*")],
                                 body: #"{"password":"hunter2","user":"ana"}"#)
        let prepared = try RequestBuilder.prepare(draft, endpoint: endpoint())
        let plain = RequestPreview.rawText(prepared)
        XCTAssertTrue(plain.hasPrefix("POST /login?session=abc HTTP/1.1\nHost: 127.0.0.1:8080\nAuthorization: Bearer supersecret\n"))
        XCTAssertTrue(plain.hasSuffix(#"{"password":"hunter2","user":"ana"}"#))
        let redacted = RequestPreview.rawText(prepared, redactor: .standard)
        for secret in ["supersecret", "hunter2", "session=abc"] { XCTAssertFalse(redacted.contains(secret), secret) }
        XCTAssertTrue(redacted.contains("Accept: */*"))
        XCTAssertTrue(redacted.contains(#""user":"ana""#))
    }
}

final class RequestComposerTests: XCTestCase {
    private var transport: MockHTTPTransport!
    private var log: ActivityLog!
    private var composer: RequestComposer!
    private var endpoint: TestEndpoint!

    override func setUpWithError() throws {
        transport = MockHTTPTransport()
        log = ActivityLog()
        composer = RequestComposer(transport: transport, log: log)
        endpoint = try TestEndpoint(string: "http://127.0.0.1:8080")
    }

    func testNothingIsSentWithoutExplicitSendOrEndpoint() {
        XCTAssertEqual(composer.state, .idle)
        XCTAssertTrue(transport.sent.isEmpty)
        XCTAssertEqual(composer.send(.template, endpoint: nil), .validation(.noEndpoint))
        XCTAssertEqual(composer.state, .failed(.validation(.noEndpoint)))
        XCTAssertTrue(transport.sent.isEmpty)
        XCTAssertTrue(log.entries.isEmpty)
    }

    func testSuccessfulSendTransitionsAndLogsRedacted() {
        var responses = 0
        composer.onResponse = { _ in responses += 1 }
        var draft = RequestDraft(method: .POST, url: "/echo?api_key=SECRETKEY",
                                 headers: [HeaderField(name: "Authorization", value: "Bearer TOPSECRET")], body: "password=hunter2")
        draft.headers.append(HeaderField(name: "X-Trace", value: "1"))
        XCTAssertNil(composer.send(draft, endpoint: endpoint))
        XCTAssertTrue(composer.isSending)
        XCTAssertEqual(transport.sent.count, 1)
        XCTAssertEqual(composer.send(draft, endpoint: endpoint), .busy)
        XCTAssertEqual(transport.sent.count, 1)

        transport.completions[0](.success(MockHTTPTransport.response(201)))
        guard case .completed(let response) = composer.state else { return XCTFail("expected completed") }
        XCTAssertEqual(response.statusCode, 201)
        XCTAssertEqual(responses, 1)
        let text = log.entries.map { $0.message }.joined(separator: "\n")
        XCTAssertTrue(text.contains("Sent POST"))
        XCTAssertTrue(text.contains("Response 201"))
        for secret in ["SECRETKEY", "TOPSECRET", "hunter2"] { XCTAssertFalse(text.contains(secret), secret) }
    }

    func testTransportFailureIsReported() {
        composer.send(.template, endpoint: endpoint)
        transport.completions[0](.failure(.timedOut))
        XCTAssertEqual(composer.state, .failed(.execution(.timedOut)))
        XCTAssertEqual(log.entries.first?.severity, .warning)
    }

    func testCancelStopsRequestAndIgnoresLateCompletion() {
        XCTAssertFalse(composer.cancel())
        composer.send(.template, endpoint: endpoint)
        XCTAssertTrue(composer.cancel())
        XCTAssertTrue(transport.handles[0].cancelled)
        XCTAssertEqual(composer.state, .failed(.execution(.cancelled)))
        transport.completions[0](.success(MockHTTPTransport.response(200)))
        XCTAssertEqual(composer.state, .failed(.execution(.cancelled)), "a late completion must not resurrect a cancelled request")
        XCTAssertNil(composer.send(.template, endpoint: endpoint), "a new request can be sent after cancelling")
    }

    func testSynchronousTransportCompletion() {
        transport.immediateResult = .success(MockHTTPTransport.response(204, body: ""))
        XCTAssertNil(composer.send(.template, endpoint: endpoint))
        guard case .completed(let response) = composer.state else { return XCTFail("expected completed") }
        XCTAssertEqual(response.statusCode, 204)
        XCTAssertFalse(composer.isSending)
    }
}

/// Runs only when SENTINEL_TEST_SERVICE_URL points at Tools/local_test_service.py.
final class LocalServiceIntegrationTests: XCTestCase {
    private func serviceEndpoint() throws -> TestEndpoint {
        guard let value = ProcessInfo.processInfo.environment["SENTINEL_TEST_SERVICE_URL"], !value.isEmpty else {
            throw XCTSkip("Set SENTINEL_TEST_SERVICE_URL to run against the local test service.")
        }
        return try TestEndpoint(string: value)
    }

    private func run(_ draft: RequestDraft, endpoint: TestEndpoint) -> RequestComposer.State {
        let composer = RequestComposer(transport: URLSessionHTTPTransport())
        let done = expectation(description: "response")
        composer.onChange = { if !composer.isSending { done.fulfill() } }
        composer.send(draft, endpoint: endpoint, timeout: 10)
        wait(for: [done], timeout: 15)
        composer.onChange = nil
        return composer.state
    }

    func testEchoReflectsEditedMethodHeadersAndBody() throws {
        let endpoint = try serviceEndpoint()
        let draft = RequestDraft(method: .PUT, url: "/echo?case=1",
                                 headers: [HeaderField(name: "X-Sentinel-Test", value: "edited"),
                                           HeaderField(name: "Content-Type", value: "text/plain")],
                                 body: "sentinel-body")
        guard case .completed(let response) = run(draft, endpoint: endpoint) else { return XCTFail("no response") }
        XCTAssertEqual(response.statusCode, 200)
        XCTAssertGreaterThan(response.duration, 0)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: response.body) as? [String: Any])
        XCTAssertEqual(object["method"] as? String, "PUT")
        XCTAssertEqual(object["path"] as? String, "/echo?case=1")
        XCTAssertEqual(object["body"] as? String, "sentinel-body")
        let headers = try XCTUnwrap(object["headers"] as? [String: String])
        XCTAssertEqual(headers["x-sentinel-test"], "edited")
    }

    func testStatusAndRedirectAreSurfacedNotFollowed() throws {
        let endpoint = try serviceEndpoint()
        guard case .completed(let teapot) = run(RequestDraft(url: "/status/418"), endpoint: endpoint) else { return XCTFail("no response") }
        XCTAssertEqual(teapot.statusCode, 418)
        guard case .completed(let redirect) = run(RequestDraft(url: "/redirect"), endpoint: endpoint) else { return XCTFail("no response") }
        XCTAssertEqual(redirect.statusCode, 302, "redirects must be shown, never followed off the endpoint")
        XCTAssertTrue(redirect.headers.contains { $0.name.lowercased() == "location" })
    }
}
