import Foundation
import GRDB
import MLX
import MLXNN
import MLXOptimizers
import MLXLLM
import MLXLMCommon
import MLXHuggingFace
// Required by the #huggingFaceTokenizerLoader() macro expansion, which
// references Tokenizers.AutoTokenizer in this file's scope.
import Tokenizers

enum TrainerError: Error, Equatable {
    case emptyDataset
    case incompatibleModel
}

/// One pair as the trainer consumes it — Sendable so it can cross into the
/// model container's isolation.
struct PairSample: Equatable, Sendable {
    var systemTags: String
    var inputText: String
    var targetText: String
}

/// Adapts the model context's tokenizer to the pure core's `ChatTokenizing`.
/// Only ever constructed and used inside `ModelContainer.perform`'s isolation.
///
/// `ModelContext.tokenizer` is `MLXLMCommon.Tokenizer` (the macro-generated
/// `TokenizerBridge` over swift-transformers), whose only chat entry point is
/// `applyChatTemplate(messages:tools:additionalContext:)` — it hardcodes
/// `addGenerationPrompt: true` upstream. swift-transformers merges
/// `additionalContext` into the Jinja context AFTER setting
/// `add_generation_prompt` (Tokenizer.swift:793-807 in the pinned 1.x
/// checkout), so passing it there overrides the hardcoded value.
struct TransformersChatTokenizer: ChatTokenizing {
    let tokenizer: any MLXLMCommon.Tokenizer

    func encodeChat(_ messages: [TrainChatMessage], addGenerationPrompt: Bool) throws -> [Int] {
        try tokenizer.applyChatTemplate(
            messages: messages.map { ["role": $0.role, "content": $0.content] },
            tools: nil,
            // enable_thinking mirrors ModelRuntime.generate: Qwen3-family
            // templates change the prompt shape around it, and training
            // must tokenize the SAME shape Compose will generate with —
            // an adapter trained against thinking-mode prompts would be
            // subtly off-distribution at inference. Qwen2.5 templates
            // ignore the unknown variable.
            additionalContext: ["add_generation_prompt": addGenerationPrompt,
                                "enable_thinking": false])
    }
}

/// On-device QLoRA training (spec §5): loads the base container through the
/// same `LLMModelFactory.loadContainer` path `ModelRuntime` uses, injects
/// adapters via `LoRAContainer.from(model:configuration:)` (quantized layers
/// become `QLoRALinear` automatically), and runs a custom prompt-masked loss
/// loop — NOT `LoRATrain.train`, whose loss covers prompt tokens. Saves
/// `adapters.safetensors` + `adapter_config.json` under
/// `Application Support/Writekin/Adapters/run-<id>/`.
struct LocalTrainer: Trainer {
    let db: AppDatabase
    let modelsRoot: URL
    var adaptersRoot: URL = LocalTrainer.defaultAdaptersRoot

    /// GPU buffer-cache bound while training (see runLoop) — larger than
    /// inference's 512 MB (training holds gradients/optimizer state), small
    /// enough that cache growth can't squeeze unified memory into Metal
    /// faults.
    static let trainingCacheLimitBytes = 4 * 1024 * 1024 * 1024

    static var defaultAdaptersRoot: URL {
        AppIdentity.storageRoot.appendingPathComponent("Adapters")
    }

    /// `Adapters/run-<id>/` — exposed so resume flows (RunCard, TrainModel)
    /// can find a crashed run's checkpoint without a stored adapter path
    /// (only SUCCEEDED runs record one).
    static func adapterDirectory(adaptersRoot: URL = defaultAdaptersRoot,
                                 runID: Int64) -> URL {
        adaptersRoot.appendingPathComponent("run-\(runID)")
    }

    /// Checkpoint cadence, in iterations: at ~10 s/it this bounds the loss
    /// from a crash to ~half an hour of work, while the save itself (a few
    /// MB of LoRA weights) costs well under a second.
    static let checkpointInterval = 200

    func train(request: TrainingRequest,
               progress: @Sendable (TrainingProgress) -> Void,
               isCancelled: @Sendable () -> Bool) async throws -> TrainedAdapter {
        let (trainPairs, valPairs) = try await fetchPairs(datasetID: request.datasetID)
        guard !trainPairs.isEmpty else { throw TrainerError.emptyDataset }

        // Training runs for ~90 minutes with the app usually backgrounded.
        // Without this assertion App Nap demotes the process, its GPU work
        // gets watchdog-limited, and long command buffers are aborted
        // ("Impacting Interactivity") — fatal, since MLX's Metal errors are
        // uncatchable. Holds until train() returns on any path.
        let activity = ProcessInfo.processInfo.beginActivity(
            options: [.userInitiated, .idleSystemSleepDisabled],
            reason: "Training voice model")
        defer { ProcessInfo.processInfo.endActivity(activity) }

        let container = try await LLMModelFactory.shared.loadContainer(
            from: modelsRoot.appendingPathComponent(request.baseModelID),
            using: #huggingFaceTokenizerLoader())

        let adapterDir = Self.adapterDirectory(adaptersRoot: adaptersRoot,
                                               runID: request.runID)
        let config = request.config

        defer {
            // The container reference dies here, but MLX retains its GPU
            // buffers in an internal cache. Without an explicit clear, the
            // next model load (the regurgitation sampler, or Compose)
            // stacks a second full footprint on top of the cached one —
            // Metal errors, and MLX's C++ exception on the completion
            // thread is uncatchable from Swift (observed as a hard abort at
            // the end of a real run). Runs in defer so failed/cancelled
            // runs release memory too.
            MLX.Memory.clearCache()
        }
        let resumeFrom = request.resumeFromIteration
        return try await container.perform { context in
            try Self.runLoop(context: context, trainPairs: trainPairs, valPairs: valPairs,
                             config: config, adapterDir: adapterDir,
                             resumeFrom: resumeFrom,
                             progress: progress, isCancelled: isCancelled)
        }
    }

    /// Train/heldout pairs for the dataset, in stable id order.
    func fetchPairs(datasetID: Int64) async throws -> (train: [PairSample], val: [PairSample]) {
        let pairs = try await db.writer.read { dbc in
            try Pair.filter(Column("dataset_id") == datasetID)
                .order(Column("id"))
                .fetchAll(dbc)
        }
        func samples(_ split: String) -> [PairSample] {
            pairs.filter { $0.split == split }.map {
                PairSample(systemTags: $0.systemTags, inputText: $0.inputText,
                           targetText: $0.targetText)
            }
        }
        return (samples("train"), samples("heldout"))
    }

    // MARK: - The loop (runs inside the container's isolation, synchronously)

    private static func runLoop(context: ModelContext,
                                trainPairs: [PairSample], valPairs: [PairSample],
                                config: TrainingConfig, adapterDir: URL,
                                resumeFrom: Int? = nil,
                                progress: @Sendable (TrainingProgress) -> Void,
                                isCancelled: @Sendable () -> Bool) throws -> TrainedAdapter {
        // Bound MLX's GPU buffer cache for the whole run: the trainer loads
        // its own container (not through ModelRuntime, whose load() sets a
        // cache limit), so training previously ran with an UNBOUNDED cache.
        // Across hundreds of iterations of varying batch shapes the cache
        // balloons until a Metal command buffer fails — and MLX surfaces
        // that as a C++ exception on the completion thread, which no Swift
        // catch can reach (observed: hard abort ~20 minutes into a real
        // run). 4 GB is roomy for rank-8 QLoRA intermediates at seq 1024.
        MLX.Memory.cacheLimit = Self.trainingCacheLimitBytes
        let tokenizer = TransformersChatTokenizer(tokenizer: context.tokenizer)
        var dropped = 0
        func render(_ pairs: [PairSample]) -> [RenderedPair] {
            pairs.compactMap { pair in
                let rendered = try? TrainingSupport.render(
                    systemTags: pair.systemTags, inputText: pair.inputText,
                    targetText: pair.targetText, tokenizer: tokenizer,
                    maxSeqLen: config.maxSeqLen)
                if rendered == nil { dropped += 1 }
                return rendered
            }
        }
        var renderedTrain = render(trainPairs)
        let renderedVal = render(valPairs)
        // The periodic val curve runs on a fixed SUBSAMPLE: the full heldout
        // set every 100 iterations was ~half the wall clock of a real run
        // (dataset 5: 24 val passes × 820 forward evals for 2,400 train
        // steps). Pairs arrive in stable id order, so this prefix is the
        // same subset for every run on a dataset — curve SHAPES stay
        // comparable. The FINAL val (below, after the loop) still covers
        // the whole heldout set, so finalValLoss remains exactly comparable
        // with pre-subsample runs and feeds the insight rules unchanged.
        let renderedValCurve = Array(renderedVal.prefix(Self.valCurveSubsample))
        guard !renderedTrain.isEmpty else { throw TrainerError.emptyDataset }

        // context.model is `any LanguageModel`; the loop needs the concrete
        // Module (a class) for valueAndGrad/optimizer.update, and an LLMModel
        // for the forward pass in `maskedLoss`. Both are checked up front so
        // an incompatible model (e.g. a future VLM manifest entry) fails the
        // run row cleanly instead of crashing inside the gradient closure.
        guard let model = context.model as? Module else { throw TrainerError.incompatibleModel }
        let llm = try Self.requireLLM(model)

        // QLoRA injection: freezes the base, swaps Linear/QuantizedLinear →
        // (Q)LoRALinear on the LAST config.numLayers layers.
        _ = try LoRAContainer.from(
            model: context.model,
            configuration: LoRAConfiguration(
                numLayers: config.numLayers,
                fineTuneType: .lora,
                loraParameters: .init(rank: config.rank, scale: config.scale)))

        // The closure's `model` parameter is the very instance `valueAndGrad`
        // was built with — i.e. the same object as `llm` — so using the
        // pre-checked `llm` here is equivalent and avoids any force-cast.
        // Resuming: load the checkpointed adapter weights onto the freshly
        // injected LoRA layers (same mechanism ModelRuntime uses to apply
        // a finished adapter). Data order is reproduced by replaying the
        // seeded shuffle below; optimizer momentum restarts fresh.
        let startIteration: Int
        if let resumeFrom, resumeFrom > 0 {
            let adapter = try LoRAContainer.from(directory: adapterDir)
            try adapter.load(into: context.model)
            startIteration = resumeFrom
        } else {
            startIteration = 0
        }

        let lossValueGrad = valueAndGrad(model: model) { _, arrays in
            [Self.maskedLoss(llm: llm, inputs: arrays[0], targets: arrays[1],
                             mask: arrays[2])]
        }
        let optimizer = AdamW(learningRate: config.learningRate)
        let padToken = context.tokenizer.eosTokenId ?? 0

        var rng = SeededRNG(seed: config.seed)
        var iteration = 0
        var windowLosses: [Float] = []
        var windowTokens = 0
        var windowStart = Date.timeIntervalSinceReferenceDate
        var lastTrainLoss: Double?
        var lastValLoss: Double?
        var maskedTokens = 0

        training: while iteration < config.iterations {
            renderedTrain.shuffle(using: &rng)   // fresh epoch order, seeded
            var cursor = 0
            while cursor < renderedTrain.count {
                if isCancelled() { throw CancellationError() }
                if iteration >= config.iterations { break training }

                let slice = Array(renderedTrain[cursor ..< min(cursor + config.batchSize,
                                                               renderedTrain.count)])
                cursor += config.batchSize
                // Shuffle replay (resume): advance through the seeded data
                // order without computing, so iteration N sees exactly the
                // batch it would have in the original run.
                if iteration < startIteration {
                    iteration += 1
                    continue
                }
                let batch = TrainingSupport.makeBatch(slice, padToken: padToken)
                let (inputs, targets, mask) = Self.mlxArrays(from: batch)

                let (values, gradients) = lossValueGrad(model, [inputs, targets, mask])
                optimizer.update(model: model, gradients: gradients)
                eval(model, optimizer, values[0])

                let lossValue = values[0].item(Float.self)
                windowLosses.append(lossValue)

                // Periodic cache trim: distinct batch shapes accumulate
                // distinct cached buffers; trimming every 25 steps keeps the
                // high-water mark flat with negligible cost (the next step
                // re-allocates only what it actually needs).
                if iteration % 25 == 24 {
                    MLX.Memory.clearCache()
                }
                let realTokens = batch.mask.reduce(0) { $0 + $1.count(where: { $0 > 0 }) }
                windowTokens += realTokens
                maskedTokens += realTokens
                iteration += 1

                if iteration % 10 == 0 {
                    let now = Date.timeIntervalSinceReferenceDate
                    let mean = windowLosses.reduce(0, +) / Float(windowLosses.count)
                    lastTrainLoss = Double(mean)
                    progress(TrainingProgress(
                        iteration: iteration, totalIterations: config.iterations,
                        trainLoss: Double(mean), valLoss: nil,
                        tokensPerSecond: Double(windowTokens) / max(now - windowStart, 0.001)))
                    windowLosses.removeAll()
                    windowTokens = 0
                    windowStart = now
                }
                if iteration % 100 == 0, !renderedValCurve.isEmpty {
                    let val = Self.evaluate(llm: llm, rendered: renderedValCurve,
                                            batchSize: config.batchSize, padToken: padToken)
                    lastValLoss = Double(val)
                    progress(TrainingProgress(
                        iteration: iteration, totalIterations: config.iterations,
                        trainLoss: lastTrainLoss, valLoss: Double(val), tokensPerSecond: nil))
                }
                // Periodic checkpoint: current LoRA weights + how far we
                // got, so an uncatchable Metal abort (GPU watchdog) or a
                // force quit costs at most `checkpointInterval` iterations
                // instead of the whole run.
                if iteration % Self.checkpointInterval == 0 {
                    try FileManager.default.createDirectory(
                        at: adapterDir, withIntermediateDirectories: true)
                    try LoRATrain.saveLoRAWeights(
                        model: model,
                        url: adapterDir.appendingPathComponent("adapters.safetensors"))
                    try TrainingSupport.writeAdapterConfig(config, to: adapterDir)
                    try TrainingCheckpoint(iteration: iteration).write(to: adapterDir)
                }
            }
        }

        // One full-heldout val pass at the end: the number every insight
        // rule compares across runs must not depend on the curve subsample.
        if !renderedVal.isEmpty {
            lastValLoss = Double(Self.evaluate(llm: llm, rendered: renderedVal,
                                               batchSize: config.batchSize,
                                               padToken: padToken))
        }

        try FileManager.default.createDirectory(at: adapterDir,
                                                withIntermediateDirectories: true)
        try LoRATrain.saveLoRAWeights(
            model: model, url: adapterDir.appendingPathComponent("adapters.safetensors"))
        try TrainingSupport.writeAdapterConfig(config, to: adapterDir)

        // Surface loop metrics through the adapter (TrainModel folds dropped
        // + maskedTokens into TrainingMetrics via these two statics).
        Self.lastRunDroppedPairs = dropped
        Self.lastRunMaskedTokens = maskedTokens

        return TrainedAdapter(adapterDirectory: adapterDir,
                              finalTrainLoss: lastTrainLoss, finalValLoss: lastValLoss)
    }

    /// Metrics side-channel for the most recent run on this process — read by
    /// TrainModel right after `train` returns. nonisolated(unsafe) is safe
    /// here because only one local training run ever executes at a time
    /// (TrainModel serializes runs).
    nonisolated(unsafe) static var lastRunDroppedPairs = 0
    nonisolated(unsafe) static var lastRunMaskedTokens = 0

    /// Heldout pairs evaluated for each PERIODIC val point (the curve).
    /// Shape is what the curve is for — 128 pairs tracks knee/still-falling
    /// fine — while the final val still covers the full heldout set.
    static let valCurveSubsample = 128

    /// Checked upgrade from the loop's Module to the LLMModel the forward
    /// pass needs. Replaces a former `as!` inside `maskedLoss` that would
    /// have hard-crashed the process (mid-gradient-closure, leaving the run
    /// row stuck at 'running') on any non-LLM module; now the run fails
    /// cleanly with `TrainerError.incompatibleModel` before training starts.
    static func requireLLM(_ model: Module) throws -> any LLMModel {
        guard let llm = model as? any LLMModel else { throw TrainerError.incompatibleModel }
        return llm
    }

    /// Prompt-masked cross entropy (spec §5): loss covers positions
    /// >= promptLen and < length only — the model never learns to produce the
    /// inbound context or the instruction, only the user's text. The forward
    /// pass mirrors LoRATrain.loss exactly. `llm` comes from `requireLLM`.
    static func maskedLoss(llm: any LLMModel, inputs: MLXArray, targets: MLXArray,
                           mask: MLXArray) -> MLXArray {
        let logits = llm(inputs, cache: nil).asType(.float32)
        let ntoks = maximum(mask.sum(), MLXArray(1))
        return (crossEntropy(logits: logits, targets: targets) * mask).sum() / ntoks
    }

    /// Mean masked loss over the heldout pairs (no gradients).
    static func evaluate(llm: any LLMModel, rendered: [RenderedPair],
                         batchSize: Int, padToken: Int) -> Float {
        var losses: [Float] = []
        var cursor = 0
        while cursor < rendered.count {
            let slice = Array(rendered[cursor ..< min(cursor + batchSize, rendered.count)])
            cursor += batchSize
            let batch = TrainingSupport.makeBatch(slice, padToken: padToken)
            let (inputs, targets, mask) = mlxArrays(from: batch)
            let loss = maskedLoss(llm: llm, inputs: inputs, targets: targets, mask: mask)
            eval(loss)
            losses.append(loss.item(Float.self))
        }
        guard !losses.isEmpty else { return 0 }
        return losses.reduce(0, +) / Float(losses.count)
    }

    static func mlxArrays(from batch: TokenBatch) -> (MLXArray, MLXArray, MLXArray) {
        let rows = batch.inputs.count
        let cols = batch.inputs.first?.count ?? 0
        let inputs = MLXArray(batch.inputs.flatMap { $0.map(Int32.init) }, [rows, cols])
        let targets = MLXArray(batch.targets.flatMap { $0.map(Int32.init) }, [rows, cols])
        let mask = MLXArray(batch.mask.flatMap { $0 }, [rows, cols])
        return (inputs, targets, mask)
    }
}
