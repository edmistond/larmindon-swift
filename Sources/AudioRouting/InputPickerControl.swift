import SwiftUI

#if os(iOS)
import AVKit
import UIKit

public struct SystemInputPickerView: UIViewRepresentable {
    public init() {}

    public func makeUIView(context: Context) -> UIView {
        let view = UIView(frame: .zero)
        view.backgroundColor = .clear
        view.isUserInteractionEnabled = true

        if #available(iOS 26.0, *) {
            let interaction = AVInputPickerInteraction()
            view.addInteraction(interaction)
        }

        return view
    }

    public func updateUIView(_ uiView: UIView, context: Context) {}
}
#endif

public struct InputSelectionMenu: View {
    @Bindable private var routeManager: AudioRouteManager

    public init(routeManager: AudioRouteManager) {
        self.routeManager = routeManager
    }

    public var body: some View {
        Menu {
            if routeManager.availableInputs.isEmpty {
                Text("No selectable inputs")
            } else {
                ForEach(routeManager.availableInputs) { input in
                    Button(input.name) {
                        routeManager.setPreferredInput(id: input.id)
                    }
                }
            }
        } label: {
            Label("Input", systemImage: "mic.badge.plus")
        }
    }
}
