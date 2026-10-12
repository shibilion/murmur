/// Decides when the periodic Ollama probe may overwrite the displayed state.
public enum OllamaStateRule {
    /// A pull error stays visible until the user pulls again; a running pull is never interrupted.
    public static func probeMayReplace(pulling: Bool, failed: Bool) -> Bool { !pulling && !failed }
}
