import Foundation
import MLXLLM
import MLXLMCommon
import MLXHuggingFace
import MLX

import HuggingFace
import Tokenizers

/// Errors surfaced by ``ModelRuntime``.
enum RuntimeError: Error, Equatable {
    /// `generate` was called before `load(modelID:)` succeeded.
    case noModelLoaded
    /// Loading the model container (weights, config, or tokenizer) failed.
    case loadFailed(String)
}

/// The real, on-device text generation backend: loads a quantized MLX model
/// from `modelsRoot/<modelID>` (see ``ModelDownloader``/``ModelScout``) and
/// streams chat completions from it via mlx-swift-lm's `ChatSession`.
///
/// An actor so model load/unload and generation are serialized against each
/// other without extra locking.
actor ModelRuntime: TextGenerating {
    /// Upper bound applied to `MLX.Memory.cacheLimit` on every load: caps
    /// the Metal buffer cache MLX is allowed to hold onto between
    /// generations, so an idle-but-loaded model doesn't quietly grow its
    /// footprint over a long Compose session.
    private static let gpuCacheLimitBytes = 512 * 1024 * 1024

    private let modelsRoot: URL
    private var container: ModelContainer?
    private(set) var loadedModelID: String?
    private(set) var loadedAdapterDirectory: URL?
    /// Fires on system memory pressure (warning or critical) and unloads the
    /// current model so its weights/cache can be reclaimed. The handler hops
    /// back into the actor since `DispatchSourceMemoryPressure`'s handler
    /// runs on its target queue, not actor-isolated.
    private var memoryPressureSource: (any DispatchSourceMemoryPressure)?

    init(modelsRoot: URL) {
        self.modelsRoot = modelsRoot
        let source = DispatchSource.makeMemoryPressureSource(
            eventMask: [.warning, .critical], queue: .global(qos: .utility))
        // Every stored property must be set before `self` can be captured by
        // the event handler closure below — assign the source first.
        self.memoryPressureSource = source
        source.setEventHandler { [weak self] in
            Task { await self?.unload() }
        }
        source.resume()
    }

    /// Loads the MLX model container for `modelID` from
    /// `modelsRoot/<modelID>`, replacing any previously loaded model.
    /// When `adapterDirectory` is given (a dir containing
    /// adapter_config.json + adapters.safetensors), applies the LoRA adapter
    /// on top of the freshly loaded base via
    /// `LoRAContainer.from(directory:).load(into:)` (spec §7). Unload —
    /// which discards the whole container — reverts it.
    func load(modelID: String, adapterDirectory: URL? = nil) async throws {
        unloadInternal()

        let directory = modelsRoot.appendingPathComponent(modelID)
        let loaded: ModelContainer
        do {
            loaded = try await LLMModelFactory.shared.loadContainer(
                from: directory, using: #huggingFaceTokenizerLoader())
        } catch {
            // Base model load failures must propagate — there's nothing
            // usable to fall back to.
            throw RuntimeError.loadFailed(String(describing: error))
        }

        var adapterApplyFailed = false
        if let adapterDirectory {
            do {
                let adapter = try LoRAContainer.from(directory: adapterDirectory)
                try await loaded.perform { context in
                    try adapter.load(into: context.model)
                }
            } catch {
                // The adapter directory can go missing (deleted on disk)
                // independently of the base model — don't wedge every
                // future load on it. Log/record and continue with the base
                // model loaded; `loadedAdapterDirectory` stays nil so the UI
                // shows no Fine-tuned badge and model_ref stays plain.
                adapterApplyFailed = true
                print("ModelRuntime: failed to apply adapter at \(adapterDirectory.path): \(error)")
            }
        }

        container = loaded
        loadedModelID = modelID
        loadedAdapterDirectory = Self.loadedAdapterDirectory(
            requested: adapterDirectory, adapterApplyFailed: adapterApplyFailed)
        MLX.Memory.cacheLimit = Self.gpuCacheLimitBytes
    }

    /// Pure decision extracted from `load`'s adapter-fallback branch so it's
    /// unit-testable without a real MLX model on disk: an adapter-apply
    /// failure always degrades to no adapter (nil), regardless of what was
    /// requested; success keeps the requested directory.
    static func loadedAdapterDirectory(requested: URL?, adapterApplyFailed: Bool) -> URL? {
        adapterApplyFailed ? nil : requested
    }

    func unload() {
        unloadInternal()
    }

    private func unloadInternal() {
        container = nil
        loadedModelID = nil
        loadedAdapterDirectory = nil
        // Dropping the container alone leaves its GPU buffers in MLX's
        // cache pool; callers unload precisely to make room for another
        // model (training, pair generation), so actually return the memory.
        MLX.Memory.clearCache()
    }

    func generate(
        prompt: ComposedPrompt, maxTokens: Int, temperature: Double,
        onToken: @escaping @Sendable (String) -> Void
    ) async throws -> String {
        guard let container else { throw RuntimeError.noModelLoaded }

        var messages: [Chat.Message] = []
        if !prompt.system.isEmpty {
            messages.append(.system(prompt.system))
        }
        for message in prompt.messages {
            switch message.role {
            case "assistant":
                messages.append(.assistant(message.text))
            case "system":
                messages.append(.system(message.text))
            default:
                messages.append(.user(message.text))
            }
        }

        let session = ChatSession(
            container,
            generateParameters: {
                var params = GenerateParameters(
                    maxTokens: maxTokens, temperature: Float(temperature))
                // Small models loop phrasings badly without this ("I also
                // did X. I also did Y." forever). 1.1 discourages reusing
                // recent tokens without mangling normal prose; 64 tokens of
                // lookback covers a few sentences.
                params.repetitionPenalty = 1.1
                params.repetitionContextSize = 64
                return params
            }(),
            // Qwen3-generation models reason in <think> blocks by default;
            // a draft/label/pair target must never contain reasoning. The
            // template kwarg turns it off at the source (Qwen2.5 templates
            // ignore the unknown variable), and ThinkTags.strip below
            // catches anything that slips through anyway.
            additionalContext: ["enable_thinking": false])

        var output = ""
        for try await chunk in session.streamResponse(to: messages) {
            output += chunk
            onToken(chunk)
        }
        return ThinkTags.strip(output)
    }
}
