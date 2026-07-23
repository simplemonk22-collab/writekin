import Testing
@testable import Writekin

struct MachineSpecsTests {
    private func model(_ id: String, tier: Int, kind: String = "compose") -> ManifestModel {
        ManifestModel(id: id, displayName: id, hfRepo: "test/\(id)", files: [],
                      license: "test", ramTierGB: tier, kind: kind, contextLength: 4096)
    }

    // MARK: - detect (sanity only — real sysctl values vary by machine)

    @Test func detectReportsPlausibleHardware() {
        let specs = MachineSpecs.detect()
        #expect(specs.ramGB >= 1)
        #expect(specs.totalCores >= 1)
        #expect(!specs.chipName.isEmpty)
    }

    // MARK: - ModelFit.rate

    @Test func rateBoundaries() {
        #expect(ModelFit.rate(ramTierGB: 32, machineRamGB: 64) == .great)
        #expect(ModelFit.rate(ramTierGB: 32, machineRamGB: 63) == .ok)
        #expect(ModelFit.rate(ramTierGB: 32, machineRamGB: 32) == .ok)
        #expect(ModelFit.rate(ramTierGB: 32, machineRamGB: 31) == .tooBig)
        #expect(ModelFit.rate(ramTierGB: 8, machineRamGB: 16) == .great)
    }

    // MARK: - bestMatch

    @Test func bestMatchPicksLargestGreatFitComposeModel() {
        let manifest = [model("small", tier: 8), model("medium", tier: 16), model("large", tier: 32)]
        #expect(ModelFit.bestMatch(manifest: manifest, machineRamGB: 64) == "large")
        #expect(ModelFit.bestMatch(manifest: manifest, machineRamGB: 32) == "medium")
    }

    @Test func bestMatchFallsBackToBareFitWhenNothingIsGreat() {
        // 16 GB machine: tier 16 merely fits (needs 32 for great), tier 8 is
        // great. The great 8 GB model wins over the barely-fitting 16 GB one
        // — recommend what runs comfortably, not what squeaks by.
        let manifest = [model("medium", tier: 16), model("small", tier: 8)]
        #expect(ModelFit.bestMatch(manifest: manifest, machineRamGB: 16) == "small")
        // But when NOTHING is great, take the largest that at least fits.
        let bigOnly = [model("large", tier: 32), model("medium", tier: 16)]
        #expect(ModelFit.bestMatch(manifest: bigOnly, machineRamGB: 16) == "medium")
    }

    /// The bundled manifest soft-fails to [] on any decode problem, which
    /// would silently blank the Models tab — so pin its decodability and
    /// the current catalog here.
    @Test func bundledManifestDecodesAndRatesOnBigMachine() {
        let manifest = ModelManifest.load()
        let ids = manifest.map(\.id)
        #expect(ids.contains("qwen3-14b-4bit"))
        #expect(ids.contains("qwen3-8b-4bit"))
        #expect(ids.contains("qwen2.5-7b-instruct-4bit"))
        // 14B and 8B share the 32 GB tier; the size tiebreak picks the 14B.
        #expect(ModelFit.bestMatch(manifest: manifest, machineRamGB: 128) == "qwen3-14b-4bit")
        #expect(ModelFit.bestMatch(manifest: manifest, machineRamGB: 64) == "qwen3-14b-4bit")
        #expect(ModelFit.bestMatch(manifest: manifest, machineRamGB: 64, kind: "labeler")
                == "qwen2.5-1.5b-instruct-4bit")
        // Every file entry must carry a real size — the downloader's
        // progress bar and resume logic key off these bytes.
        #expect(manifest.allSatisfy { $0.files.allSatisfy { $0.bytes > 0 } })
    }

    @Test func bestMatchIsPerKindAndReturnsNilWhenNothingFits() {
        let mixed = [model("labeler", tier: 8, kind: "labeler"), model("writer", tier: 16)]
        #expect(ModelFit.bestMatch(manifest: mixed, machineRamGB: 64) == "writer")
        #expect(ModelFit.bestMatch(manifest: mixed, machineRamGB: 64, kind: "labeler") == "labeler")
        let tooBig = [model("large", tier: 32)]
        #expect(ModelFit.bestMatch(manifest: tooBig, machineRamGB: 16) == nil)
    }
}
