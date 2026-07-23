import Testing
import Foundation
@testable import Writekin

struct TextGeneratingTests {
    @Test func fakeStreamsAndRecords() async throws {
        let fake = FakeGenerator(script: ["hello world output"])
        nonisolated(unsafe) var streamed = ""
        let prompt = ComposedPrompt(system: "sys",
                                    messages: [PromptMessage(role: "user", text: "hi")])
        let result = try await fake.generate(prompt: prompt, maxTokens: 64,
                                             temperature: 0.7) { streamed += $0 }
        #expect(result == "hello world output")
        #expect(streamed == result)
        #expect(fake.receivedPrompts.first?.system == "sys")
    }

    @Test func runtimeWithoutModelThrows() async throws {
        let runtime = ModelRuntime(modelsRoot: FileManager.default.temporaryDirectory)
        await #expect(throws: RuntimeError.self) {
            _ = try await runtime.generate(
                prompt: ComposedPrompt(system: "", messages: []),
                maxTokens: 8, temperature: 0.1) { _ in }
        }
    }
}
