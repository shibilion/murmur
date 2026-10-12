import Foundation
import MurmurCore
import llama

/// Built-in cleanup: Qwen3-4B-Instruct (GGUF) running in-process on llama.cpp with Metal.
///
/// The model, context and sampler pointers never leave this actor, and every call is serialised by it
/// (a llama context is not thread-safe). `warm` evaluates the system prompt plus the context part of the user message
/// while the user is still speaking and remembers those tokens; `format` then evaluates only the tail that differs.
public actor LlamaFormatter: MurmurCore.Formatter {
    public nonisolated let id = "llama"
    public static let defaultModelFile = "Qwen3-4B-Instruct-2507-Q4_K_M.gguf"

    private let folder: URL
    private let modelFile: String
    private let downloads: DownloadManager?
    private let catalogID: String

    private var model: OpaquePointer?
    private var ctx: OpaquePointer?
    private var vocab: OpaquePointer?
    /// The tokens whose key/value pairs are currently in the context's KV cache, in order.
    private var cachedTokens: [Int32] = []

    static let contextLength: UInt32 = 4096
    private static let batchSize = 512
    private static let splitMarker = "\u{1}MURMUR_SPLIT\u{1}"

    public init(folder: URL, modelFile: String = LlamaFormatter.defaultModelFile,
                downloads: DownloadManager? = nil, catalogID: String = "qwen3-4b-instruct-gguf",
                beforeLoad: (@Sendable () async -> Void)? = nil) {
        self.beforeLoad = beforeLoad
        self.folder = folder
        self.modelFile = modelFile
        self.downloads = downloads
        self.catalogID = catalogID
    }

    /// Frees the native objects when the formatter goes away. Only ever touched from the actor.
    private final class Owner: @unchecked Sendable {
        let model: OpaquePointer, ctx: OpaquePointer
        init(model: OpaquePointer, ctx: OpaquePointer) { self.model = model; self.ctx = ctx }
        deinit { llama_free(ctx); llama_model_free(model) }
    }
    private var owner: Owner?
    private var inFlight: Task<Void, Error>?
    /// Test seam: runs once per actual load, after the file check.
    private let beforeLoad: (@Sendable () async -> Void)?

    public func isReady() async -> Bool { model != nil && ctx != nil }

    /// Frees the model and context (generation is synchronous inside the actor, so nothing is mid-use). A later
    /// `prepare()` reloads it. No-op while a load is in flight.
    public func unload() {
        guard inFlight == nil else { return }
        owner = nil
        model = nil; ctx = nil; vocab = nil
        cachedTokens = []
    }

    /// Loads the model onto the GPU once; idempotent. Concurrent callers share one load.
    /// Throws when the file is missing or cannot be loaded.
    public func prepare() async throws {
        if isLoaded { return }
        if let inFlight {
            try await inFlight.value
            return
        }
        let task = Task { try await self.load() }
        inFlight = task
        do {
            try await task.value
            inFlight = nil
        } catch {
            inFlight = nil
            throw error
        }
    }

    private func load() async throws {
        let path = folder.appendingPathComponent(modelFile).path
        guard FileManager.default.fileExists(atPath: path) else { throw EngineError.modelMissing(catalogID) }
        await downloads?.markPreparing(catalogID)
        await beforeLoad?()
        Self.initBackend()
        var mp = llama_model_default_params()
        mp.n_gpu_layers = 999
        guard let m = llama_model_load_from_file(path, mp) else {
            await downloads?.markFailed(catalogID, "Couldn't load the model. Delete it in Settings → Models and download it again.")
            throw EngineError.modelMissing(catalogID)
        }
        var cp = llama_context_default_params()
        cp.n_ctx = Self.contextLength
        cp.n_batch = UInt32(Self.batchSize)
        cp.n_ubatch = UInt32(Self.batchSize)
        guard let c = llama_init_from_model(m, cp) else {
            llama_model_free(m)
            await downloads?.markFailed(catalogID, "Couldn't load the model. Delete it in Settings → Models and download it again.")
            throw EngineError.modelMissing(catalogID)
        }
        owner = Owner(model: m, ctx: c)
        model = m
        ctx = c
        vocab = llama_model_get_vocab(m)
        cachedTokens = []
        await downloads?.markReady(catalogID)
    }

    private var isLoaded: Bool { model != nil && ctx != nil && vocab != nil }

    // MARK: - Prompt (pure, testable)

    /// The three pieces of the prompt `format` sends, in the same hints style as the Ollama formatter.
    static func promptParts(for req: FormatRequest) -> (system: String, userPrefix: String, transcript: String) {
        let system = PromptBuilder.system(mode: req.mode, strength: req.strength, tone: req.tone, contextStyle: .hints)
        let parts = PromptBuilder.userParts(req, includeContext: req.context != nil, style: .hints)
        return (system, parts.prefix, parts.transcriptSection)
    }

    /// ChatML, used when the GGUF has no usable built-in template.
    static func chatML(system: String, user: String, addAssistant: Bool = true) -> String {
        var s = "<|im_start|>system\n\(system)<|im_end|>\n<|im_start|>user\n\(user)<|im_end|>\n"
        if addAssistant { s += "<|im_start|>assistant\n" }
        return s
    }

    /// Length of the longest shared leading run of two token sequences.
    static func commonPrefixLength(_ a: [Int32], _ b: [Int32]) -> Int {
        var i = 0
        let n = min(a.count, b.count)
        while i < n, a[i] == b[i] { i += 1 }
        return i
    }

    /// Generation cap: the same one the Ollama formatter uses.
    static func maxTokens(forRaw text: String) -> Int {
        OllamaFormatter.tokenCap(forRawWordCount: text.split(whereSeparator: \.isWhitespace).count)
    }

    // MARK: - Warm and format

    /// Evaluates the system prompt plus the context part of the user message and keeps the KV cache.
    /// Swallows all errors (warming is best effort).
    public func warm(system: String, userPrefix: String) async {
        do {
            try await prepare()
            let head = renderChat(system: system, user: userPrefix + Self.splitMarker, addAssistant: false)
            guard let cut = head.range(of: Self.splitMarker) else { return }
            let tokens = try tokenize(String(head[..<cut.lowerBound]))
            guard !tokens.isEmpty, tokens.count < Int(Self.contextLength) else { return }
            try sync(to: tokens)
        } catch {
            resetCache()
        }
    }

    public func format(_ req: FormatRequest) async throws -> String {
        try await prepare()
        let p = Self.promptParts(for: req)
        let prompt = renderChat(system: p.system, user: p.userPrefix + p.transcript, addAssistant: true)
        let promptTokens = try tokenize(prompt)
        let cap = Self.maxTokens(forRaw: req.raw.text)
        guard !promptTokens.isEmpty, promptTokens.count + cap < Int(Self.contextLength) else { throw EngineError.malformed }
        do {
            try sync(to: promptTokens, leavingLast: true)
            let out = try generate(maxTokens: cap)
            // Drop the generated tokens; the prompt stays cached for the next common prefix.
            if let ctx { _ = llama_memory_seq_rm(llama_get_memory(ctx), 0, Int32(promptTokens.count), -1) }
            cachedTokens = promptTokens
            return OllamaFormatter.stripThink(Self.cutAtEnd(out))
        } catch {
            resetCache()
            throw error
        }
    }

    // MARK: - llama.cpp plumbing (actor-confined)

    private func resetCache() {
        if let ctx { llama_memory_clear(llama_get_memory(ctx), true) }
        cachedTokens = []
    }

    /// Makes the KV cache hold exactly `tokens` (or all but the last when `leavingLast`, whose evaluation yields the
    /// logits): keeps the common prefix with what is cached, drops the rest, evaluates the remainder.
    private func sync(to tokens: [Int32], leavingLast: Bool = false) throws {
        guard let ctx else { throw EngineError.modelMissing(catalogID) }
        let mem = llama_get_memory(ctx)
        var keep = Self.commonPrefixLength(cachedTokens, tokens)
        if leavingLast, keep >= tokens.count { keep = tokens.count - 1 }
        if keep == 0 {
            llama_memory_clear(mem, true)
        } else if keep < cachedTokens.count {
            guard llama_memory_seq_rm(mem, 0, Int32(keep), -1) else {
                llama_memory_clear(mem, true)
                cachedTokens = []
                return try sync(to: tokens, leavingLast: leavingLast)
            }
        }
        cachedTokens = Array(tokens[..<keep])
        var i = keep
        while i < tokens.count {
            try Task.checkCancellation()
            let end = min(i + Self.batchSize, tokens.count)
            var chunk = Array(tokens[i..<end])
            let rc = chunk.withUnsafeMutableBufferPointer { llama_decode(ctx, llama_batch_get_one($0.baseAddress, Int32($0.count))) }
            guard rc == 0 else { throw EngineError.malformed }
            i = end
            cachedTokens = Array(tokens[..<end])
        }
        llama_synchronize(ctx)
    }

    /// Greedy decoding until end of generation or `maxTokens`.
    private func generate(maxTokens: Int) throws -> String {
        guard let ctx, let vocab else { throw EngineError.modelMissing(catalogID) }
        guard let sampler = llama_sampler_chain_init(llama_sampler_chain_default_params()) else { throw EngineError.malformed }
        llama_sampler_chain_add(sampler, llama_sampler_init_greedy())
        defer { llama_sampler_free(sampler) }
        var bytes: [UInt8] = []
        var n = 0
        while n < maxTokens {
            try Task.checkCancellation()
            var tok = llama_sampler_sample(sampler, ctx, -1)
            if llama_vocab_is_eog(vocab, tok) { break }
            bytes += piece(tok, vocab)
            n += 1
            let rc = llama_decode(ctx, llama_batch_get_one(&tok, 1))
            guard rc == 0 else { throw EngineError.malformed }
        }
        return String(decoding: bytes, as: UTF8.self)
    }

    private func piece(_ token: Int32, _ vocab: OpaquePointer) -> [UInt8] {
        var buf = [CChar](repeating: 0, count: 64)
        let n = llama_token_to_piece(vocab, token, &buf, 64, 0, false)
        return n > 0 ? buf[0..<Int(n)].map { UInt8(bitPattern: $0) } : []
    }

    private func tokenize(_ text: String) throws -> [Int32] {
        guard let vocab else { throw EngineError.modelMissing(catalogID) }
        let bytes = text.utf8.count
        var buf = [Int32](repeating: 0, count: bytes + 16)
        var n = llama_tokenize(vocab, text, Int32(bytes), &buf, Int32(buf.count), false, true)
        if n < 0 {
            buf = [Int32](repeating: 0, count: Int(-n))
            n = llama_tokenize(vocab, text, Int32(bytes), &buf, Int32(buf.count), false, true)
        }
        guard n >= 0 else { throw EngineError.malformed }
        return Array(buf[0..<Int(n)])
    }

    /// Applies the GGUF's built-in chat template; ChatML when it is missing or unsupported.
    private func renderChat(system: String, user: String, addAssistant: Bool) -> String {
        guard let model, let tmpl = llama_model_chat_template(model, nil) else {
            return Self.chatML(system: system, user: user, addAssistant: addAssistant)
        }
        var out: String?
        system.withCString { sys in
            user.withCString { usr in
                "system".withCString { rs in
                    "user".withCString { ru in
                        var msgs = [llama_chat_message(role: rs, content: sys), llama_chat_message(role: ru, content: usr)]
                        var buf = [CChar](repeating: 0, count: (system.utf8.count + user.utf8.count) * 2 + 256)
                        var n = llama_chat_apply_template(tmpl, &msgs, msgs.count, addAssistant, &buf, Int32(buf.count))
                        if n > Int32(buf.count) {
                            buf = [CChar](repeating: 0, count: Int(n) + 1)
                            n = llama_chat_apply_template(tmpl, &msgs, msgs.count, addAssistant, &buf, Int32(buf.count))
                        }
                        if n > 0 { out = String(decoding: buf[0..<Int(n)].map { UInt8(bitPattern: $0) }, as: UTF8.self) }
                    }
                }
            }
        }
        return out ?? Self.chatML(system: system, user: user, addAssistant: addAssistant)
    }

    static func cutAtEnd(_ s: String) -> String {
        if let r = s.range(of: "<|im_end|>") { return String(s[..<r.lowerBound]) }
        return s
    }

    private static let backendOnce: Void = {
        llama_log_set({ _, _, _ in }, nil)
        llama_backend_init()
    }()
    private static func initBackend() { _ = backendOnce }
}
