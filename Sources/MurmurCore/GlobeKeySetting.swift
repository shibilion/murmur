/// The "Press 🌐 key to" system setting (`AppleFnUsageType` in com.apple.HIToolbox).
public enum GlobeKeySetting {
    /// 0 is "Do Nothing". A missing value is treated as not set up.
    public static func isDoNothing(_ value: Int?) -> Bool { value == 0 }
}
