import AppCore
import Foundation

/// The standard post-processing chain: ignore filter, then replacements (when enabled), then optional formatting.
///
/// Deterministic and side-effect free. The same chain serves file jobs, live captions and dictation (IGN-AC-12, FR-AC-12).
public struct PostProcessingChain: TranscriptPostProcessor {
    public var formatting: FormattingOptions?
    public var ignoreMode: IgnoreFilter.FlagMode

    /// - Parameters:
    ///   - formatting: Formatting clean-ups to run last, or nil (default) to skip formatting.
    ///   - ignoreMode: ``IgnoreFilter/FlagMode/additive`` (default) keeps existing flags; use `.rederive` to recompute them.
    public init(formatting: FormattingOptions? = nil, ignoreMode: IgnoreFilter.FlagMode = .additive) {
        self.formatting = formatting
        self.ignoreMode = ignoreMode
    }

    public func process(_ segments: [Segment], context: PostProcessingContext) async -> [Segment] {
        run(segments, context: context)
    }

    /// Synchronous variant of ``process(_:context:)``.
    public func run(_ segments: [Segment], context: PostProcessingContext) -> [Segment] {
        var result = IgnoreFilter(context: context, mode: ignoreMode).apply(to: segments)
        if context.applyReplacements {
            result = ReplacementProcessor(rules: context.replacementRules).apply(to: result)
        }
        if let formatting { result = FormattingProcessor(options: formatting).apply(to: result) }
        return result
    }
}
