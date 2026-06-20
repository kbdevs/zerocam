import AVFoundation
import SwiftUI
import UIKit

struct CameraPreview: UIViewRepresentable {
    let session: AVCaptureSession
    let interfaceOrientation: UIInterfaceOrientation
    let onTapToFocus: (CGPoint, CGPoint) -> Void

    func makeUIView(context: Context) -> PreviewView {
        let view = PreviewView()
        view.videoPreviewLayer.session = session
        view.videoPreviewLayer.videoGravity = .resizeAspectFill
        view.setInterfaceOrientation(interfaceOrientation)
        view.onTapToFocus = onTapToFocus
        return view
    }

    func updateUIView(_ uiView: PreviewView, context: Context) {
        uiView.videoPreviewLayer.session = session
        uiView.setInterfaceOrientation(interfaceOrientation)
        uiView.onTapToFocus = onTapToFocus
    }
}

final class PreviewView: UIView {
    var onTapToFocus: ((CGPoint, CGPoint) -> Void)?

    override init(frame: CGRect) {
        super.init(frame: frame)
        let tap = UITapGestureRecognizer(target: self, action: #selector(handleTap(_:)))
        addGestureRecognizer(tap)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override class var layerClass: AnyClass {
        AVCaptureVideoPreviewLayer.self
    }

    var videoPreviewLayer: AVCaptureVideoPreviewLayer {
        layer as! AVCaptureVideoPreviewLayer
    }

    func setInterfaceOrientation(_ orientation: UIInterfaceOrientation) {
        guard let connection = videoPreviewLayer.connection else { return }
        let angle = orientation.captureRotationAngle

        if connection.isVideoRotationAngleSupported(angle) {
            connection.videoRotationAngle = angle
        }
    }

    @objc private func handleTap(_ recognizer: UITapGestureRecognizer) {
        let viewPoint = recognizer.location(in: self)
        let devicePoint = videoPreviewLayer.captureDevicePointConverted(fromLayerPoint: viewPoint)
        onTapToFocus?(devicePoint, viewPoint)
    }
}

extension UIInterfaceOrientation {
    var captureRotationAngle: CGFloat {
        switch self {
        case .landscapeRight:
            0
        case .portrait:
            90
        case .landscapeLeft:
            180
        case .portraitUpsideDown:
            270
        default:
            90
        }
    }
}
