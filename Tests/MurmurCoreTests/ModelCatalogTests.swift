import Foundation
import Testing
@testable import MurmurCore

@Suite
struct ModelCatalogTests {
    @Test
    func idsUnique() {
        let ids = ModelCatalog.all.map(\.id)
        #expect(Set(ids).count == ids.count)
        #expect(Set(ids) == ["parakeet-v2", "whisper-large-v3-turbo", "qwen3-4b-instruct-gguf"])
    }

    @Test
    func allFilesHaveHexSha256() {
        let hex = Set("0123456789abcdef")
        for model in ModelCatalog.all {
            #expect(!model.files.isEmpty, "\(model.id)")
            for file in model.files {
                #expect(file.sha256.count == 64, "\(model.id)/\(file.relativePath)")
                #expect(file.sha256.allSatisfy { hex.contains($0) }, "\(model.id)/\(file.relativePath)")
            }
        }
    }

    @Test
    func sizesMatchSpecRoughly() throws {
        let gb = 1_000_000_000.0
        let ranges: [String: ClosedRange<Double>] = [
            "parakeet-v2": 0.3...0.7, "whisper-large-v3-turbo": 1.2...1.8, "qwen3-4b-instruct-gguf": 2.0...2.8,
        ]
        for (id, range) in ranges {
            let model = try #require(ModelCatalog.model(id))
            #expect(range.contains(Double(model.sizeBytes) / gb), "\(id) \(model.sizeBytes)")
        }
    }

    @Test
    func exactlyOneRecommendedPerKind() {
        for kind in [ModelKind.speech, .cleanup] {
            #expect(ModelCatalog.all.filter { $0.kind == kind && $0.recommended }.count == 1)
        }
    }

    @Test
    func relativePathsAreSafe() {
        for model in ModelCatalog.all {
            for file in model.files {
                #expect(!file.relativePath.hasPrefix("/"), "\(file.relativePath)")
                #expect(!file.relativePath.split(separator: "/").contains(".."), "\(file.relativePath)")
            }
        }
    }

    @Test
    func whisperIncludesTokenizer() throws {
        let whisper = try #require(ModelCatalog.model("whisper-large-v3-turbo"))
        #expect(whisper.files.contains { $0.relativePath.hasPrefix("tokenizer/") })
    }
}
