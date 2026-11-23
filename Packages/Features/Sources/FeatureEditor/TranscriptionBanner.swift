import AppCore
import DesignSystem
import SwiftUI

/// The slim banner of the transcribing mode (SCR-015): progress, ETA and Pause/Resume/Cancel while the job runs; a clear
/// failure or cancellation message with Retry and Remove once it has stopped.
struct TranscriptionBanner: View {
    let model: TranscriptEditorModel

    var body: some View {
        if model.isTranscribing {
            running
        } else if model.transcriptionInterrupted {
            stopped
        }
    }

    private var running: some View {
        let paused = model.transcriptionJob?.state == .paused
        return HStack(spacing: DSSpacing.sm) {
            if model.transcriptionJob?.state == .pending {
                ProgressView().controlSize(.small)
            } else {
                ProgressView(value: model.transcriptionProgress).progressViewStyle(.linear).frame(width: 120)
                    .tint(paused ? DSColor.secondaryText : DSColor.accent)
            }
            Text(statusLine)
                .font(DSTypography.caption).foregroundStyle(DSColor.secondaryText).lineLimit(1)
            Spacer(minLength: DSSpacing.sm)
            if paused {
                Button("Resume") { Task { await model.resumeTranscription() } }
                    .help("Continue transcribing from where it stopped")
                    .accessibilityIdentifier("editor.transcribing.resume")
            } else {
                Button("Pause") { Task { await model.pauseTranscription() } }
                    .help("Pause transcribing; it resumes from the last finished part")
                    .accessibilityIdentifier("editor.transcribing.pause")
            }
            Button("Cancel") { Task { await model.cancelTranscription() } }
                .help("Stop transcribing. What was transcribed so far is kept.")
                .accessibilityIdentifier("editor.transcribing.cancel")
        }
        .buttonStyle(.link).font(DSTypography.caption)
        .padding(.horizontal, DSSpacing.md).padding(.vertical, DSSpacing.xs).background(DSColor.solidChrome)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Transcription progress")
        .accessibilityValue(statusLine)
        .accessibilityIdentifier("editor.transcribing.banner")
    }

    private var statusLine: String {
        var parts = [model.transcriptionStatusText]
        if model.transcriptionJob?.state != .pending {
            parts.append(model.transcriptionProgress.formatted(.percent.precision(.fractionLength(0))))
        }
        if let eta = model.transcriptionETAText { parts.append(eta) }
        parts.append("Read-only until it finishes")
        return parts.joined(separator: " · ")
    }

    private var stopped: some View {
        let failed = model.transcriptionJob?.state == .failed
        let detail = failed ? (model.transcriptionJob?.failureReason ?? "The file could not be transcribed.") : "You stopped it."
        return VStack(alignment: .leading, spacing: DSSpacing.xs) {
            HStack(spacing: DSSpacing.sm) {
                Image(systemName: failed ? "exclamationmark.triangle.fill" : "stop.circle")
                    .foregroundStyle(failed ? DSColor.danger : DSColor.secondaryText).accessibilityHidden(true)
                Text("\(model.transcriptionStatusText). \(detail) \(model.isEmpty ? "" : "What was saved is shown read-only.")")
                    .font(DSTypography.caption).foregroundStyle(failed ? DSColor.danger : DSColor.secondaryText).lineLimit(2)
                Spacer(minLength: DSSpacing.sm)
                Button("Retry") { Task { await model.retryTranscription() } }
                    .help("Transcribe the file again")
                    .accessibilityIdentifier("editor.transcribing.retry")
                Button("Remove") { Task { await model.removeTranscriptionJob() } }
                    .help("Remove the job from the queue and keep the partial transcript, which becomes editable")
                    .accessibilityIdentifier("editor.transcribing.remove")
            }
            if let error = model.transcriptionError {
                Text(error).font(DSTypography.caption).foregroundStyle(DSColor.danger)
            }
        }
        .buttonStyle(.link).font(DSTypography.caption)
        .padding(.horizontal, DSSpacing.md).padding(.vertical, DSSpacing.xs).background(DSColor.solidChrome)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("editor.transcribing.stopped")
    }
}
