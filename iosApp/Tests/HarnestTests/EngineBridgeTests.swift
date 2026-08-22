import XCTest
@testable import Harnest

final class EngineBridgeTests: XCTestCase {

    private final class Collector: HostListener {
        func onLog(stream: String, chunk: String) {}
        func onEvent(eventJson: String) {}
        func onFetch(fetchId: Int, requestJson: String) {}
        func onDevice(deviceId: Int, requestJson: String) {}
        func onCallSettled(callId: Int, ok: Bool, json: String) {}
    }

    private func tempCwd() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("harnest-tests-\(UUID().uuidString)", isDirectory: true)
    }

    private func bootedEngine() throws -> HarnessEngine {
        let engine = HarnessEngine(listener: Collector())
        try engine.boot(cwd: tempCwd())
        return engine
    }

    func test01BootMakesEngineReady() throws {
        let engine = try bootedEngine()
        XCTAssertTrue(engine.isReady())
        engine.dispose()
        XCTAssertFalse(engine.isReady())
    }

    func test02ListProvidersSyncCall() async throws {
        let engine = try bootedEngine()
        defer { engine.dispose() }

        // 裸 boot（未 init）：内核尚未注入 provider 档案 → 合法 JSON 空数组
        let bare = engine.callFunc("listProviders", nil)
        XCTAssertNil(bare.error)
        XCTAssertFalse(bare.isAsync)
        let bareData = try XCTUnwrap(try XCTUnwrap(bare.resultJson).data(using: .utf8))
        _ = try XCTUnwrap(try JSONSerialization.jsonObject(with: bareData) as? [[String: Any]])

        // init 注入一个 provider 档案后 → listProviders 非空（配置注入链路）
        let cwd = tempCwd()
        let config = """
        {"cwd":\(HarnessEngine.jsStringLiteral(cwd.path)),"providers":[{"provider":"deepseek","baseUrl":"https://api.deepseek.com","apiKey":"sk-test","models":[{"id":"deepseek-chat"}]}],"defaultProvider":"deepseek","defaultModel":"deepseek-chat"}
        """
        _ = try await engine.callAwait("init", config)
        let inited = engine.callFunc("listProviders", nil)
        XCTAssertNil(inited.error)
        let data = try XCTUnwrap(try XCTUnwrap(inited.resultJson).data(using: .utf8))
        let arr = try XCTUnwrap(try JSONSerialization.jsonObject(with: data) as? [[String: Any]])
        XCTAssertFalse(arr.isEmpty)
        XCTAssertEqual(arr.first?["provider"] as? String, "deepseek")
    }

    func test03CallBeforeBootErrors() {
        let engine = HarnessEngine(listener: Collector())
        let envelope = engine.callFunc("listProviders", nil)
        XCTAssertNotNil(envelope.error)
    }

    func test04UnknownFunctionEnvelope() throws {
        let engine = try bootedEngine()
        defer { engine.dispose() }
        let envelope = engine.callFunc("noSuchFunctionForTest", nil)
        XCTAssertNil(envelope.error)
        let json = try XCTUnwrap(envelope.resultJson)
        XCTAssertTrue(json.contains("function not found"))
    }

    func test05AsyncCallSettles() async throws {
        let engine = try bootedEngine()
        defer { engine.dispose() }
        let args = LocalEngine.jsonEncode(["sessionId": "probe-1"])
        let settled = expectation(description: "call settled")
        Task {
            _ = try? await engine.callAwait("createSession", args)
            settled.fulfill()
        }
        await fulfillment(of: [settled], timeout: 30)
    }

    func test06JsStringLiteralRoundTrip() throws {
        let samples = ["plain", "a\"b", "back\\slash", "line\nbreak\r\ttab", "emoji 🚀 ok", "sep sep "]
        for s in samples {
            let literal = HarnessEngine.jsStringLiteral(s)
            let data = try XCTUnwrap(literal.data(using: .utf8))
            let parsed = try XCTUnwrap(JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed]) as? String)
            XCTAssertEqual(parsed, s)
        }
    }
}
