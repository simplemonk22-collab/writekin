import Foundation

/// The hardware facts that decide which local models run well here: chip
/// name, unified memory, and core counts. Read once via sysctl (cheap,
/// no privileges) — everything else about model fit derives from these.
struct MachineSpecs: Equatable, Sendable {
    var chipName: String
    var ramGB: Int
    var performanceCores: Int?
    var efficiencyCores: Int?
    var totalCores: Int

    static func detect() -> MachineSpecs {
        MachineSpecs(
            chipName: sysctlString("machdep.cpu.brand_string") ?? "Unknown chip",
            ramGB: Int(sysctlUInt64("hw.memsize") ?? 0) / (1024 * 1024 * 1024),
            performanceCores: sysctlInt("hw.perflevel0.physicalcpu"),
            efficiencyCores: sysctlInt("hw.perflevel1.physicalcpu"),
            totalCores: sysctlInt("hw.physicalcpu") ?? ProcessInfo.processInfo.processorCount)
    }

    /// "12 cores (8 performance + 4 efficiency)", or just "12 cores" when
    /// the perf-level split isn't available (e.g. Intel).

    private static func sysctlString(_ name: String) -> String? {
        var size = 0
        guard sysctlbyname(name, nil, &size, nil, 0) == 0, size > 0 else { return nil }
        var buffer = [CChar](repeating: 0, count: size)
        guard sysctlbyname(name, &buffer, &size, nil, 0) == 0 else { return nil }
        return String(cString: buffer)
    }

    private static func sysctlUInt64(_ name: String) -> UInt64? {
        var value: UInt64 = 0
        var size = MemoryLayout<UInt64>.size
        guard sysctlbyname(name, &value, &size, nil, 0) == 0 else { return nil }
        return value
    }

    private static func sysctlInt(_ name: String) -> Int? {
        var value: Int32 = 0
        var size = MemoryLayout<Int32>.size
        guard sysctlbyname(name, &value, &size, nil, 0) == 0 else { return nil }
        return Int(value)
    }
}

/// How well a manifest model suits a machine, judged from the model's
/// declared RAM tier (the minimum machine memory it's meant for) against
/// the machine's actual memory. Doubling the tier leaves room for the
/// model, its KV cache, training gradients/optimizer state, and the rest
/// of the OS all at once — that's the "great" bar; merely meeting the tier
/// runs inference fine but trains under memory pressure.
enum ModelFit: Equatable, Sendable {
    case great
    case ok
    case tooBig

    static func rate(ramTierGB: Int, machineRamGB: Int) -> ModelFit {
        if machineRamGB >= ramTierGB * 2 { return .great }
        if machineRamGB >= ramTierGB { return .ok }
        return .tooBig
    }

    /// Localization keys, not text — this type is nonisolated model code
    /// (no `Localization` access); the badge translates at render time.
    var labelKey: L10nKey {
        switch self {
        case .great: .fitGreat
        case .ok: .fitOk
        case .tooBig: .fitTooBig
        }
    }

    var detailKey: L10nKey {
        switch self {
        case .great: .fitGreatDetail
        case .ok: .fitOkDetail
        case .tooBig: .fitTooBigDetail
        }
    }

    /// The single manifest model of `kind` to highlight as "best match":
    /// the largest-tier candidate that isn't too big, preferring a great
    /// fit over a bare fit. Nil when nothing fits (or the manifest has no
    /// model of that kind). Computed per role — the app needs one compose
    /// model AND one labeler, so each gets its own recommendation.
    static func bestMatch(manifest: [ManifestModel], machineRamGB: Int,
                          kind: String = "compose") -> String? {
        let candidates = manifest
            .filter { $0.kind == kind }
            .filter { rate(ramTierGB: $0.ramTierGB, machineRamGB: machineRamGB) != .tooBig }
        // Same tier ⇒ break the tie by actual size — more parameters at
        // equal comfort is strictly the better recommendation.
        let byCapability: (ManifestModel, ManifestModel) -> Bool = {
            ($0.ramTierGB, $0.totalBytes) < ($1.ramTierGB, $1.totalBytes)
        }
        let great = candidates
            .filter { rate(ramTierGB: $0.ramTierGB, machineRamGB: machineRamGB) == .great }
            .max(by: byCapability)
        return (great ?? candidates.max(by: byCapability))?.id
    }
}
