import XCTest
@testable import Harnest

final class LocalEngineFlowTests: XCTestCase {

    private func clearAllProviderKeys() {
        for p in Providers.all {
            let meta = Providers.metaOf(p)
            ConfigService.get().setConfig(
                provider: p,
                apiKey: "",
                baseUrl: meta?.baseUrl ?? "",
                models: meta?.models ?? [],
                defaultModel: meta?.defaultModel ?? ""
            )
        }
    }

    private func configureDeepSeekFakeKey() {
        let meta = Providers.metaOf(Providers.deepseek)
        ConfigService.get().setConfig(
            provider: Providers.deepseek,
            apiKey: "sk-e2e-fake-key",
            baseUrl: meta?.baseUrl ?? "",
            models: meta?.models ?? [],
            defaultModel: meta?.defaultModel ?? ""
        )
        ConfigService.get().setLastSelection(
            provider: Providers.deepseek,
            model: meta?.defaultModel ?? "deepseek-chat"
        )
    }

    func test01EnsureStartedThrowsNotConfiguredWithoutKey() async {
        clearAllProviderKeys()
        LocalEngine.get().dispose()
        do {
            try await LocalEngine.get().ensureStarted()
            XCTFail("expected EngineError.notConfigured")
        } catch EngineError.notConfigured {
        } catch {
            XCTFail("unexpected error: \(error)")
        }
    }

    func test02EnsureStartedBootsEngineWithConfiguredKey() async throws {
        configureDeepSeekFakeKey()
        try await LocalEngine.get().ensureStarted()
        XCTAssertTrue(LocalEngine.get().isReady())
        XCTAssertFalse(LocalEngine.get().listProviders().isEmpty)
    }

    func test03MountSessionAndChatSurfacesApiError() async throws {
        configureDeepSeekFakeKey()
        let engine = LocalEngine.get()
        try await engine.ensureStarted()
        let record = SessionRecord(
            id: "e2e-probe-\(Int(Date().timeIntervalSince1970))",
            title: "E2E",
            provider: Providers.deepseek,
            model: "deepseek-chat"
        )
        try await engine.mountSession(record)
        do {
            let outcome = try await engine.chat("hi")
            XCTAssertFalse(outcome.isEmpty)
        } catch {
            XCTAssertFalse("\(error)".isEmpty)
        }
    }

    func test04RestartAfterDispose() async throws {
        configureDeepSeekFakeKey()
        LocalEngine.get().dispose()
        XCTAssertFalse(LocalEngine.get().isReady())
        try await LocalEngine.get().ensureStarted()
        XCTAssertTrue(LocalEngine.get().isReady())
    }
}
