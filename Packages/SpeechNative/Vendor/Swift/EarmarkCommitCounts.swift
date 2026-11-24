// Earmark integration extension; all other files in this directory are verbatim pinned upstream.
import CTranscribe

extension Session {
    /// Read while the worker owns the single-threaded session, copying counts before the next mutation.
    public func earmarkCommittedCounts() -> (segments: Int, words: Int) {
        model.withCompute {
            (Int(transcribe_stream_n_committed_segments(ptr)), Int(transcribe_stream_n_committed_words(ptr)))
        }
    }
}
