import AppCore
import SwiftUI

private struct GalleryView: View {
    var body: some View {
        VStack(alignment: .leading, spacing: DSSpacing.lg) {
            SheetCard {
                VStack(alignment: .leading, spacing: DSSpacing.sm) {
                    HStack {
                        StatusPill(state: .running)
                        StatusPill(state: .completed)
                        StatusPill(state: .failed)
                        RecordingIndicator()
                    }
                    HStack {
                        LanguageBadge("si")
                        LanguageBadge("en-US")
                        SpeakerChip(name: "Nimal", slot: 0)
                        SpeakerChip(name: "සුනිල්", slot: 1)
                    }
                    ProgressRow(title: "interview.m4a", detail: "Transcribing", fraction: 0.4)
                    Text("ශ්‍රී ලංකාව සහ English mixed — පරීක්ෂණය").font(SinhalaFont.font(size: 17))
                }
            }
            DSGlassGroup {
                HStack {
                    GlassToolbarButton("Record", systemImage: "record.circle") {}
                    GlassToolbarButton("Add", systemImage: "plus", prominent: true) {}
                }
            }
            HStack {
                Skeleton(width: 120)
                Skeleton(width: 80)
            }
        }
        .padding(DSSpacing.xl)
        .frame(width: 460)
        .background(DSColor.contentBackground)
    }
}

#Preview("Gallery") { GalleryView() }
#Preview("Gallery - solid fallback") {
    GalleryView().environment(\.accessibilityPolicyOverride, AccessibilityPolicy(reduceTransparency: true, reduceMotion: true))
}
#Preview("Empty") { EmptyState(systemImage: "tray", title: "No transcripts", message: "Drop audio files to begin.") }
#Preview("Error") { ErrorState(message: "The model failed to load.") {} }
