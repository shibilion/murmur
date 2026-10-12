import Foundation
import MurmurCore
import MurmurEngines

/// The Apple Intelligence formatter for `--formatter apple`, or nil (after printing why) when it is unavailable.
func appleBenchFormatter() -> (any MurmurCore.Formatter)? {
    let a = AppleIntelligenceFormatter.availability()
    print("apple availability: \(a)" + (a.message.map { " - \($0)" } ?? ""))
    guard a == .available else { return nil }
    return AppleIntelligenceFormatter()
}
