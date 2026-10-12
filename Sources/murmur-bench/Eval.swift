import Foundation
import MurmurCore
import MurmurEngines

func runEval(_ o: Options) async -> Int32 {
    guard let root = packageRoot() else { return fail("Package.swift not found above the current directory", code: 2) }
    let formatter: any MurmurCore.Formatter
    let model = Settings().ollamaModel
    let formatterName = o["formatter"] ?? ""
    switch o["formatter"] {
    case "ollama":
        guard await ollamaHasModel(model) else {
            return fail("Ollama is not reachable at 127.0.0.1:11434 or \(model) is not pulled (ollama pull \(model)).", code: 2)
        }
        formatter = OllamaFormatter(model: { model })
    case "builtin":
        let llama = builtinFormatter(o)
        do { try await llama.prepare() } catch { return fail("cannot load the built-in model (\(error)); pass --gguf <path>", code: 2) }
        formatter = llama
    case "apple":
        guard let f = appleBenchFormatter() else { return 2 }
        formatter = f
    case "claude":
        let secrets = KeychainStore()
        guard secrets.get("anthropic") != nil else {
            return fail("No Anthropic key saved; add one in Murmur Settings → Cloud", code: 2)
        }
        formatter = ClaudeFormatter(secrets: secrets)
    default:
        return fail("--formatter must be ollama, builtin or claude", code: 2)
    }
    let url = root.appendingPathComponent("Tests/Fixtures/cleanup-eval.json")
    guard let data = try? Data(contentsOf: url), let cases = try? JSONDecoder().decode([EvalCase].self, from: data) else {
        return fail("cannot load \(url.path)", code: 2)
    }

    var tally: [String: (pass: Int, near: Int, fail: Int)] = [:]
    var failures: [String] = []
    for c in cases {
        let snapshot = c.context.map {
            ContextSnapshot(app: AppIdentity(name: "Eval", bundleId: "eval"), beforeText: $0.beforeText,
                            selectedText: "", afterText: "", screenWords: $0.screenWords, isSecureField: false)
        }
        let mode: DictationMode = c.mode == "indian" ? .indian : .english
        let req = FormatRequest(raw: RawTranscript(text: c.raw), context: snapshot, tone: .neutral,
                                mode: mode, strength: .normal)
        var got: String
        do { got = try await formatter.format(req) } catch { got = "<error: \(error)>" }
        let modelOutput = got
        let allowedExtra: [String]
        if formatterName == "ollama" || formatterName == "builtin" {
            allowedExtra = req.context == nil ? [] : PromptBuilder.hints(for: req)
        } else {
            allowedExtra = (c.context?.screenWords ?? []) + (c.context.map { [$0.beforeText] } ?? [])
        }
        let replaced = PostProcessor.shouldUseRaw(raw: c.raw, formatted: got, allowedExtra: allowedExtra, mode: mode)
        if replaced { got = c.raw }
        let verdict = EvalScorer.score(got: got, expected: c.expected, mustNotContain: c.mustNotContain ?? [])
        var t = tally[c.category] ?? (0, 0, 0)
        switch verdict {
        case .pass: t.pass += 1
        case .near: t.near += 1
        case .fail: t.fail += 1
        }
        tally[c.category] = t
        if verdict != .pass {
            failures.append("[\(verdict)] \(c.id)\n  raw:      \(c.raw)\n  model:    \(modelOutput)\(replaced ? "  [safety→raw]" : "")\n  final:    \(got)\n  expected: \(c.expected)")
        }
    }
    print(pad("category", 16) + "pass near fail")
    for (cat, t) in tally.sorted(by: { $0.key < $1.key }) {
        print(pad(cat, 16) + "\(t.pass)    \(t.near)    \(t.fail)")
    }
    let passes = tally.values.reduce(0) { $0 + $1.pass }
    let nears = tally.values.reduce(0) { $0 + $1.near }
    print("\nscore: \(passes)/\(cases.count) pass, \(nears) near, \(cases.count - passes - nears) fail (target >= 24)")
    if !failures.isEmpty { print("\nnon-passing cases:\n" + failures.joined(separator: "\n")) }
    return passes >= 24 ? 0 : 1
}
