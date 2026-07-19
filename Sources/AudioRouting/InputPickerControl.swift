import SwiftUI

#if os(iOS)
import AVFAudio
import AVKit
import UIKit

public struct SystemInputPickerButton: UIViewRepresentable {
    @Bindable private var routeManager: AudioRouteManager

    public init(routeManager: AudioRouteManager) {
        self.routeManager = routeManager
    }

    public func makeCoordinator() -> Coordinator {
        Coordinator(routeManager: routeManager)
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
        uiView.configuration = buttonConfiguration()
    }

    public func sizeThatFits(
        _ proposal: ProposedViewSize,
        uiView: UIButton,
        context: Context
    ) -> CGSize? {
        uiView.systemLayoutSizeFitting(UIView.layoutFittingCompressedSize)
    }

    private func buttonConfiguration() -> UIButton.Configuration {
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

        init(routeManager: AudioRouteManager) {
            self.routeManager = routeManager
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
            Task { @MainActor [routeManager] in
                routeManager.refresh()
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

    public init(
        routeManager: AudioRouteManager,
        labelTitle: String = "Input",
        systemImage: String = "mic.badge.plus"
    ) {
        self.routeManager = routeManager
        self.labelTitle = labelTitle
        self.systemImage = systemImage
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
                        routeManager.setPreferredInput(id: input.id)
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
            Label(labelTitle, systemImage: systemImage)
        }
    }
}

#Preview {
    InputSelectionMenu(routeManager: AudioRouteManager())
        .padding()
}
