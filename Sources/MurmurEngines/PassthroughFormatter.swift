import MurmurCore

/// Returns the raw transcript unchanged.
public struct PassthroughFormatter: MurmurCore.Formatter {
    public let id = "passthrough"
    public init() {}
    public func format(_ req: FormatRequest) async throws -> String { req.raw.text }
}
