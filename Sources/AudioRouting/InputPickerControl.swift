import SwiftUI

#if os(iOS)
import AVFAudio
import AVKit
import UIKit

public struct SystemInputPickerButton: UIViewRepresentable {
    @Bindable private var routeManager: AudioRouteManager
    private let releaseAudioSessionWhenDismissed: Bool
    private let showsCurrentInputName: Bool
    private let onInputSelectionChanged: @MainActor @Sendable () -> Void

    /// - Parameter showsCurrentInputName: Title the button with the current input's name
    ///   as a capsule chip, so the input stays visible by name, rather than "Input".
    public init(
        routeManager: AudioRouteManager,
        releaseAudioSessionWhenDismissed: Bool = false,
        showsCurrentInputName: Bool = false,
        onInputSelectionChanged: @escaping @MainActor @Sendable () -> Void = {}
    ) {
        self.routeManager = routeManager
        self.releaseAudioSessionWhenDismissed = releaseAudioSessionWhenDismissed
        self.showsCurrentInputName = showsCurrentInputName
        self.onInputSelectionChanged = onInputSelectionChanged
    }

    public func makeCoordinator() -> Coordinator {
        Coordinator(
            routeManager: routeManager,
            releaseAudioSessionWhenDismissed: releaseAudioSessionWhenDismissed,
            onInputSelectionChanged: onInputSelectionChanged
        )
    }

    public func makeUIView(context: Context) -> UIButton {
        let button = UIButton(type: .system)
        button.configuration = buttonConfiguration()
        button.setContentHuggingPriority(.required, for: .horizontal)
        button.setContentHuggingPriority(.required, for: .vertical)
        button.setContentCompressionResistancePriority(.required, for: .horizontal)
        button.setContentCompressionResistancePriority(.required, for: .vertical)

        if #available(iOS 26.0, *) {
            let interaction = AVInputPickerInteraction(audioSession: AVAudioSession.sharedInstance())
            interaction.delegate = context.coordinator
            context.coordinator.inputPickerInteraction = interaction
            button.addInteraction(interaction)
            button.addTarget(
                context.coordinator,
                action: #selector(Coordinator.presentInputPicker(_:)),
                for: .touchUpInside
            )
        }

        return button
    }

    public func updateUIView(_ uiView: UIButton, context: Context) {
        context.coordinator.routeManager = routeManager
        context.coordinator.releaseAudioSessionWhenDismissed = releaseAudioSessionWhenDismissed
        context.coordinator.onInputSelectionChanged = onInputSelectionChanged
        uiView.configuration = buttonConfiguration()
    }

    public func sizeThatFits(
        _ proposal: ProposedViewSize,
        uiView: UIButton,
        context: Context
    ) -> CGSize? {
        let natural = uiView.systemLayoutSizeFitting(UIView.layoutFittingCompressedSize)
        // A long input name truncates instead of pushing the chip past its slot.
        guard let width = proposal.width, width.isFinite, width < natural.width else { return natural }
        return CGSize(width: width, height: natural.height)
    }

    private func buttonConfiguration() -> UIButton.Configuration {
        if showsCurrentInputName {
            var configuration = UIButton.Configuration.gray()
            configuration.title = routeManager.currentInputName
            configuration.titleLineBreakMode = .byTruncatingTail
            configuration.titleTextAttributesTransformer = UIConfigurationTextAttributesTransformer { attributes in
                var attributes = attributes
                attributes.font = UIFont.preferredFont(forTextStyle: .subheadline)
                return attributes
            }
            configuration.image = UIImage(
                systemName: "chevron.down",
                withConfiguration: UIImage.SymbolConfiguration(textStyle: .caption1, scale: .small)
            )
            configuration.imagePlacement = .trailing
            configuration.imagePadding = 6
            configuration.cornerStyle = .capsule
            configuration.baseForegroundColor = .label
            configuration.contentInsets = NSDirectionalEdgeInsets(
                top: 8,
                leading: 14,
                bottom: 8,
                trailing: 12
            )
            return configuration
        }

        var configuration = UIButton.Configuration.bordered()
        configuration.title = "Input"
        configuration.image = UIImage(systemName: "mic.badge.plus")
        configuration.imagePadding = 6
        configuration.contentInsets = NSDirectionalEdgeInsets(
            top: 11,
            leading: 12,
            bottom: 11,
            trailing: 14
        )
        return configuration
    }

    @MainActor
    public final class Coordinator: NSObject, @preconcurrency AVInputPickerInteraction.Delegate {
        var routeManager: AudioRouteManager
        var inputPickerInteraction: AVInputPickerInteraction?
        var releaseAudioSessionWhenDismissed: Bool
        var onInputSelectionChanged: @MainActor @Sendable () -> Void

        init(
            routeManager: AudioRouteManager,
            releaseAudioSessionWhenDismissed: Bool,
            onInputSelectionChanged: @escaping @MainActor @Sendable () -> Void
        ) {
            self.routeManager = routeManager
            self.releaseAudioSessionWhenDismissed = releaseAudioSessionWhenDismissed
            self.onInputSelectionChanged = onInputSelectionChanged
        }

        @objc func presentInputPicker(_ sender: UIButton) {
            sender.isEnabled = false

            Task { @MainActor in
                defer {
                    sender.isEnabled = true
                }

                do {
                    try await routeManager.configureForInputSelection()
                    inputPickerInteraction?.present()
                } catch {
                    print("Failed to present input picker: \(error.localizedDescription)")
                }
            }
        }

        public func inputPickerInteractionDidEndDismissing(_ inputPickerInteraction: AVInputPickerInteraction) {
            let shouldReleaseAudioSession = releaseAudioSessionWhenDismissed
            let selectionChanged = onInputSelectionChanged
            Task { @MainActor [routeManager] in
                routeManager.refresh()
                selectionChanged()
                if shouldReleaseAudioSession {
                    routeManager.releaseAudioSession()
                }
            }
        }

        public func inputPickerInteractionDidEndPresenting(_ inputPickerInteraction: AVInputPickerInteraction) {
            Task { @MainActor [routeManager] in
                routeManager.refresh()
            }
        }
    }
}
#endif

public struct InputSelectionMenu: View {
    @Bindable private var routeManager: AudioRouteManager
    private let labelTitle: String
    private let systemImage: String
    private let showsCurrentInputName: Bool
    private let onInputSelectionChanged: @MainActor @Sendable () -> Void

    /// - Parameter showsCurrentInputName: Title the menu with the current input's name, so
    ///   the input stays visible by name, instead of `labelTitle`.
    public init(
        routeManager: AudioRouteManager,
        labelTitle: String = "Input",
        systemImage: String = "mic.badge.plus",
        showsCurrentInputName: Bool = false,
        onInputSelectionChanged: @escaping @MainActor @Sendable () -> Void = {}
    ) {
        self.routeManager = routeManager
        self.labelTitle = labelTitle
        self.systemImage = systemImage
        self.showsCurrentInputName = showsCurrentInputName
        self.onInputSelectionChanged = onInputSelectionChanged
    }

    public var body: some View {
        Menu {
            Button {
                routeManager.refresh()
            } label: {
                Label("Refresh Inputs", systemImage: "arrow.clockwise")
            }

            Divider()

            if routeManager.availableInputs.isEmpty {
                Text("No selectable inputs")
            } else {
                ForEach(routeManager.availableInputs) { input in
                    Button {
                        guard routeManager.preferredInputID != input.id else {
                            return
                        }
                        routeManager.setPreferredInput(id: input.id)
                        onInputSelectionChanged()
                    } label: {
                        if input.name == routeManager.currentInputName {
                            Label(input.name, systemImage: "checkmark")
                        } else {
                            Text(input.name)
                        }
                    }
                }
            }
        } label: {
            if showsCurrentInputName {
                Label(routeManager.currentInputName, systemImage: "mic")
                    .labelStyle(.titleAndIcon)
            } else {
                Label(labelTitle, systemImage: systemImage)
            }
        }
        .accessibilityLabel(showsCurrentInputName ? "Input: \(routeManager.currentInputName)" : labelTitle)
    }
}

#Preview {
    InputSelectionMenu(routeManager: AudioRouteManager())
        .padding()
}
