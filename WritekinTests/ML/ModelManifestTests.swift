import Testing
import Foundation
@testable import Writekin

struct ModelManifestTests {
    let json = """
    [{"id":"compose-7b","displayName":"Qwen 7B","hfRepo":"mlx-community/Q7",
      "files":[{"path":"model.safetensors","bytes":100,"sha256":"aa"}],
      "license":"Apache-2.0","ramTierGB":32,"kind":"compose","contextLength":32768},
     {"id":"compose-3b","displayName":"Qwen 3B","hfRepo":"mlx-community/Q3",
      "files":[{"path":"model.safetensors","bytes":50,"sha256":"bb"}],
      "license":"Apache-2.0","ramTierGB":16,"kind":"compose","contextLength":32768},
     {"id":"labeler-1.5b","displayName":"Qwen 1.5B","hfRepo":"mlx-community/Q15",
      "files":[{"path":"model.safetensors","bytes":25,"sha256":"cc"}],
      "license":"MIT","ramTierGB":8,"kind":"labeler","contextLength":32768}]
    """.data(using: .utf8)!

    @Test func parsesManifest() throws {
        let models = try ModelManifest.load(from: json)
        #expect(models.count == 3)
        #expect(models[0].totalBytes == 100)
    }

    @Test func bundleManifestLoadsAndIsLicenseClean() {
        let models = ModelManifest.load()
        #expect(!models.isEmpty)
        #expect(models.allSatisfy { ["Apache-2.0", "MIT"].contains($0.license) })
        #expect(models.contains { $0.kind == "labeler" })
        #expect(models.contains { $0.kind == "compose" })
    }
}
