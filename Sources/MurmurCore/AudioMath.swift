import Foundation

public enum AudioMath {
    /// Largest absolute sample value.
    public static func peak(_ samples: [Float]) -> Float {
        samples.reduce(0) { max($0, abs($1)) }
    }

    /// RMS converted to dBFS (20·log10(rms)), mapped linearly from [-60, 0] dB to [0, 1] and clamped.
    /// Empty array or zero RMS returns 0.
    public static func level(_ samples: [Float]) -> Float {
        guard !samples.isEmpty else { return 0 }

        // Calculate RMS (Root Mean Square)
        let sumOfSquares = samples.reduce(0) { $0 + $1 * $1 }
        let rms = sqrt(sumOfSquares / Float(samples.count))

        // Return 0 for zero RMS
        guard rms > 0 else { return 0 }

        // Convert to dBFS: 20 * log10(rms)
        let dbFS = 20 * log10(rms)

        // Map linearly from [-60, 0] dB to [0, 1]
        let normalized = (dbFS + 60) / 60

        // Clamp to [0, 1]
        return max(0, min(1, normalized))
    }

    /// A clip is worth transcribing when it is at least 0.3 s long and not silent.
    public static func isUsable(_ c: AudioClip) -> Bool {
        c.duration >= 0.3 && peak(c.samples) >= 0.01
    }
}
