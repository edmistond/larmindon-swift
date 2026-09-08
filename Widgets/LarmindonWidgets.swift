import SwiftUI
import WidgetKit

private struct CaptionLauncherEntry: TimelineEntry {
    let date: Date
}

private struct CaptionLauncherProvider: TimelineProvider {
    func placeholder(in context: Context) -> CaptionLauncherEntry {
        CaptionLauncherEntry(date: .now)
    }

    func getSnapshot(in context: Context, completion: @escaping (CaptionLauncherEntry) -> Void) {
        completion(CaptionLauncherEntry(date: .now))
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<CaptionLauncherEntry>) -> Void) {
        completion(Timeline(entries: [CaptionLauncherEntry(date: .now)], policy: .never))
    }
}

@main
struct LarmindonWidgets: Widget {
    let kind = "LarmindonCaptionLauncher"

    var body: some WidgetConfiguration {
        StaticConfiguration(kind: kind, provider: CaptionLauncherProvider()) { _ in
            Image("LarmindonWidgetGlyph")
                .renderingMode(.template)
                .resizable()
                .scaledToFit()
                .padding(4)
                .accessibilityLabel("Start captions")
                .widgetURL(CaptionLaunchLink.url)
                .containerBackground(for: .widget) { AccessoryWidgetBackground() }
        }
        .configurationDisplayName("Start Captions")
        .description("Open Larmindon and start your selected provider if captions are idle.")
        .supportedFamilies([.accessoryCircular])
    }
}
