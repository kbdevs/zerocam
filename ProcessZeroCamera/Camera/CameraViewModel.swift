import AVFoundation
import SwiftUI
import UIKit

@MainActor
final class CameraViewModel: ObservableObject {
    enum AuthorizationState {
        case notDetermined
        case authorized
        case denied
    }

    @Published private(set) var authorizationState: AuthorizationState = .notDetermined
    @Published private(set) var isCapturing = false
    @Published private(set) var interfaceOrientation: UIInterfaceOrientation = .portrait
    @Published private(set) var zoomState = CameraService.ZoomState(
        factor: 1,
        displayFactor: 1,
        minFactor: 1,
        maxFactor: 15,
        lensDisplayFactors: [1]
    )
    @Published private(set) var exposureState = CameraService.ExposureState(
        bias: 0,
        minBias: -2,
        maxBias: 2
    )
    @Published private(set) var lastCapturedImage: UIImage?
    @Published var showingLastCapture = false
    @Published var focusPoint: CGPoint?
    @Published var message: String?

    let session: AVCaptureSession

    private let camera: CameraService
    private var messageTask: Task<Void, Never>?

    init(camera: CameraService) {
        self.camera = camera
        self.session = camera.session
        self.camera.onZoomStateChange = { [weak self] state in
            self?.zoomState = state
        }
        self.camera.onExposureStateChange = { [weak self] state in
            self?.exposureState = state
        }
    }

    func start() async {
        refreshInterfaceOrientation()
        let status = AVCaptureDevice.authorizationStatus(for: .video)

        switch status {
        case .authorized:
            authorizationState = .authorized
            await camera.start()
        case .notDetermined:
            let granted = await AVCaptureDevice.requestAccess(for: .video)
            authorizationState = granted ? .authorized : .denied
            if granted {
                await camera.start()
            }
        default:
            authorizationState = .denied
        }
    }

    func stop() {
        camera.stop()
    }

    func capture() {
        guard authorizationState == .authorized, !isCapturing else { return }
        refreshInterfaceOrientation()
        isCapturing = true
        show("Capturing")

        Task {
            do {
                let result = try await camera.captureProcessZeroPhoto()
                lastCapturedImage = UIImage(data: result.processedJPEGData)

                switch result.rawKind {
                case .bayer:
                    show("Saved Bayer RAW + Zero JPEG")
                case .appleProRAW:
                    show("Saved ProRAW + Zero JPEG")
                }
            } catch {
                show(error.localizedDescription)
            }

            isCapturing = false
        }
    }

    func focus(at devicePoint: CGPoint, viewPoint: CGPoint) {
        focusPoint = viewPoint
        camera.focus(at: devicePoint)

        Task { [weak self] in
            try? await Task.sleep(for: .seconds(1))
            await MainActor.run {
                guard self?.focusPoint == viewPoint else { return }
                self?.focusPoint = nil
            }
        }
    }

    func setZoom(displayFactor: CGFloat) {
        camera.setZoom(displayFactor: displayFactor)
    }

    func setExposureBias(_ bias: CGFloat) {
        camera.setExposureBias(bias)
    }

    func showLastCapture() {
        guard lastCapturedImage != nil else { return }
        showingLastCapture = true
    }

    func refreshInterfaceOrientation() {
        guard let scene = UIApplication.shared.connectedScenes
            .compactMap({ $0 as? UIWindowScene })
            .first(where: { $0.activationState == .foregroundActive || $0.activationState == .foregroundInactive })
        else {
            camera.setInterfaceOrientation(interfaceOrientation)
            return
        }

        let nextOrientation = scene.interfaceOrientation
        guard nextOrientation != .unknown else { return }
        interfaceOrientation = nextOrientation
        camera.setInterfaceOrientation(nextOrientation)
    }

    private func show(_ text: String) {
        messageTask?.cancel()
        message = text

        messageTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(2))
            guard !Task.isCancelled else { return }
            await MainActor.run {
                self?.message = nil
            }
        }
    }
}
