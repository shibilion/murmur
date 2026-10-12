import Foundation

let usage = """
usage: murmur-bench latency [--formatter ollama|builtin|passthrough] [--runs 5] [--context] [--gguf <path>]
       murmur-bench eval --formatter ollama|builtin|claude [--gguf <path>]
"""

let args = Array(CommandLine.arguments.dropFirst())
guard let command = args.first else {
    FileHandle.standardError.write(Data((usage + "\n").utf8))
    exit(2)
}
let options = Options(Array(args.dropFirst()))

switch command {
case "latency": exit(await runLatency(options))
case "eval": exit(await runEval(options))
default:
    FileHandle.standardError.write(Data((usage + "\n").utf8))
    exit(2)
}
