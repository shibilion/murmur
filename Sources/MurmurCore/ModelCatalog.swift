import Foundation

public enum ModelKind: Sendable { case speech, cleanup }

public struct ModelFile: Sendable, Equatable {
    /// Path relative to the model's install folder.
    public let relativePath: String
    public let url: URL
    public let sha256: String
    public let bytes: Int64

    public init(relativePath: String, url: URL, sha256: String, bytes: Int64) {
        self.relativePath = relativePath
        self.url = url
        self.sha256 = sha256
        self.bytes = bytes
    }
}

public struct CatalogModel: Sendable, Identifiable, Equatable {
    public let id: String
    public let kind: ModelKind
    public let name: String
    public let blurb: String
    public let languages: String
    public let accuracy: Double
    public let speed: Double
    public let recommended: Bool
    public let files: [ModelFile]

    public var sizeBytes: Int64 { files.reduce(0) { $0 + $1.bytes } }
}

public enum ModelCatalog {
    public static let all: [CatalogModel] = [
        CatalogModel(
            id: "parakeet-v2", kind: .speech, name: "Parakeet TDT 0.6B v2",
            blurb: "Fast, accurate English", languages: "English",
            accuracy: 0.9, speed: 0.95, recommended: true, files: parakeetFiles),
        CatalogModel(
            id: "whisper-large-v3-turbo", kind: .speech, name: "Whisper Large v3 Turbo",
            blurb: "Hindi, Hinglish and 98 more languages", languages: "99 languages",
            accuracy: 0.8, speed: 0.55, recommended: false, files: whisperFiles),
        CatalogModel(
            id: "qwen3-4b-instruct-gguf", kind: .cleanup, name: "Qwen3 4B Instruct",
            blurb: "Removes fillers, fixes punctuation, applies corrections",
            languages: "English, Hindi, Hinglish",
            accuracy: 0.65, speed: 0.8, recommended: true, files: qwenFiles),
    ]

    public static func model(_ id: String) -> CatalogModel? { all.first { $0.id == id } }
}
