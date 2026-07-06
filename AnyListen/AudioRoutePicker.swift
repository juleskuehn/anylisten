import SwiftUI
import AVKit

struct AudioRoutePicker: UIViewRepresentable {
    func makeUIView(context: Context) -> FullFrameAudioRoutePickerView {
        let picker = FullFrameAudioRoutePickerView()
        picker.activeTintColor = .systemCyan
        picker.tintColor = .white
        picker.prioritizesVideoDevices = false
        picker.backgroundColor = .clear
        return picker
    }
    
    func updateUIView(_ uiView: FullFrameAudioRoutePickerView, context: Context) {}
}

final class FullFrameAudioRoutePickerView: AVRoutePickerView {
    override func layoutSubviews() {
        super.layoutSubviews()
        
        // Keep Apple's native route picker visible and directly tappable.
        // The internal control can otherwise be smaller than this SwiftUI frame,
        // so stretch it to fill our rounded icon button.
        for subview in subviews {
            subview.frame = bounds
        }
    }
}
