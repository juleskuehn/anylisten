import SwiftUI
import AVKit
import UIKit

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
        
        // AVRoutePickerView's tappable button can otherwise remain only as wide as
        // the AirPlay icon. Stretch its internal control so the full SwiftUI
        // pill is tappable while still using Apple's system route picker.
        for subview in subviews {
            subview.frame = bounds
            if let button = subview as? UIButton {
                button.setTitle("Select", for: .normal)
                button.setTitleColor(.white, for: .normal)
                button.titleLabel?.font = .systemFont(ofSize: 15, weight: .semibold)
                button.setImage(nil, for: .normal)
                button.tintColor = .white
                button.contentHorizontalAlignment = .center
            }
        }
    }
}
