import AVFoundation
import CoreImage
import Photos
import UIKit

final class CameraService: NSObject, @unchecked Sendable {
    enum RawKind {
        case bayer
        case appleProRAW
    }

    struct CaptureResult {
        let rawKind: RawKind
        let processedJPEGData: Data

        var usedRAW: Bool { true }
    }

    struct ZoomState: Equatable {
        var factor: CGFloat
        var displayFactor: CGFloat
        var minFactor: CGFloat
        var maxFactor: CGFloat
        var lensDisplayFactors: [CGFloat]
    }

    struct ExposureState: Equatable {
        var bias: CGFloat
        var minBias: CGFloat
        var maxBias: CGFloat
    }

    enum CameraError: LocalizedError {
        case missingCamera
        case configurationFailed
        case captureUnavailable
        case bayerRAWUnavailable
        case captureFailed
        case processingFailed
        case photoLibraryRejected
        case saveFailed

        var errorDescription: String? {
            switch self {
            case .missingCamera:
                "No back camera was found."
            case .configurationFailed:
                "Could not configure the camera."
            case .captureUnavailable:
                "Photo capture is not available yet."
            case .bayerRAWUnavailable:
                "Bayer RAW is not available on this device."
            case .captureFailed:
                "Photo capture failed."
            case .processingFailed:
                "Could not process the RAW photo."
            case .photoLibraryRejected:
                "Photos rejected the RAW + JPEG pair."
            case .saveFailed:
                "Could not save the photo."
            }
        }
    }

    let session = AVCaptureSession()

    private let sessionQueue = DispatchQueue(label: "com.kb.processzerocamera.session")
    private let photoOutput = AVCapturePhotoOutput()
    private let photoProcessor = PhotoProcessor()
    private var isConfigured = false
    private var videoInput: AVCaptureDeviceInput?
    private var captureDelegate: PhotoCaptureDelegate?
    private var rotationAngle: CGFloat = 90
    private var videoDevice: AVCaptureDevice?
    private var displayZoomMultiplier: CGFloat = 1
    private var exposureBias: CGFloat = 0
    var onZoomStateChange: (@MainActor (ZoomState) -> Void)?
    var onExposureStateChange: (@MainActor (ExposureState) -> Void)?

    func start() async {
        await withCheckedContinuation { continuation in
            sessionQueue.async {
                if !self.isConfigured {
                    do {
                        try self.configureSession()
                    } catch {
                        continuation.resume()
                        return
                    }
                }

                if !self.session.isRunning {
                    self.session.startRunning()
                }

                continuation.resume()
            }
        }
    }

    func stop() {
        sessionQueue.async {
            if self.session.isRunning {
                self.session.stopRunning()
            }
        }
    }

    func setInterfaceOrientation(_ orientation: UIInterfaceOrientation) {
        let angle = orientation.captureRotationAngle

        sessionQueue.async {
            self.rotationAngle = angle
            self.applyRotationAngleIfSupported(to: self.photoOutput.connection(with: .video))
        }
    }

    func focus(at devicePoint: CGPoint) {
        sessionQueue.async {
            guard let device = self.videoDevice else { return }

            do {
                try device.lockForConfiguration()

                if device.isFocusPointOfInterestSupported {
                    device.focusPointOfInterest = devicePoint
                }

                if device.isFocusModeSupported(.autoFocus) {
                    device.focusMode = .autoFocus
                }

                if device.isExposurePointOfInterestSupported {
                    device.exposurePointOfInterest = devicePoint
                }

                if device.isExposureModeSupported(.continuousAutoExposure) {
                    device.exposureMode = .continuousAutoExposure
                }

                self.applyExposureBias(self.exposureBias, to: device)

                device.unlockForConfiguration()
            } catch {
                return
            }
        }
    }

    func setExposureBias(_ bias: CGFloat) {
        sessionQueue.async {
            guard let device = self.videoDevice else { return }

            do {
                try device.lockForConfiguration()
                self.exposureBias = self.clampedExposureBias(bias, for: device)
                self.applyExposureBias(self.exposureBias, to: device)
                device.unlockForConfiguration()
                self.publishExposureState(for: device)
            } catch {
                return
            }
        }
    }

    func setZoom(displayFactor: CGFloat) {
        sessionQueue.async {
            guard let device = self.videoDevice else { return }

            do {
                let targetDevice = self.previewDevice(for: displayFactor) ?? device
                try self.replaceVideoDevice(with: targetDevice, displayZoomFactor: displayFactor, publish: true)
            } catch {
                return
            }
        }
    }

    func captureProcessZeroPhoto() async throws -> CaptureResult {
        let capture = try await capturePhotoPayload()

        guard let rawData = capture.payload.rawData else {
            throw CameraError.captureFailed
        }

        let zeroJPEG = try photoProcessor.renderZeroJPEG(from: rawData)
        try await save(processedJPEG: zeroJPEG, rawDNG: rawData)
        return CaptureResult(rawKind: capture.rawKind, processedJPEGData: zeroJPEG)
    }

    private func configureSession() throws {
        session.beginConfiguration()
        defer { session.commitConfiguration() }

        session.sessionPreset = .photo

        guard let device = preferredBackCamera() else {
            throw CameraError.missingCamera
        }

        let input = try AVCaptureDeviceInput(device: device)
        guard session.canAddInput(input), session.canAddOutput(photoOutput) else {
            throw CameraError.configurationFailed
        }

        session.addInput(input)
        session.addOutput(photoOutput)

        videoInput = input
        videoDevice = device
        displayZoomMultiplier = zoomDisplayMultiplier(for: device)
        photoOutput.maxPhotoQualityPrioritization = .speed
        setInitialZoom(on: device)
        publishExposureState(for: device)
        publishZoomState(for: device)

        isConfigured = true
    }

    private func preferredBackCamera() -> AVCaptureDevice? {
        backCamera(.builtInWideAngleCamera)
            ?? backCamera(.builtInTripleCamera)
            ?? backCamera(.builtInDualWideCamera)
            ?? backCamera(.builtInDualCamera)
    }

    private func backCamera(_ deviceType: AVCaptureDevice.DeviceType) -> AVCaptureDevice? {
        let discovery = AVCaptureDevice.DiscoverySession(
            deviceTypes: [deviceType],
            mediaType: .video,
            position: .back
        )

        return discovery.devices.first
    }

    private func capturePhotoPayload() async throws -> (payload: PhotoCaptureDelegate.Payload, rawKind: RawKind) {
        try await withCheckedThrowingContinuation { continuation in
            sessionQueue.async {
                guard self.isConfigured else {
                    continuation.resume(throwing: CameraError.captureUnavailable)
                    return
                }

                let settings: AVCapturePhotoSettings
                let rawKind: RawKind
                let shouldRestoreVirtualCamera: Bool
                let displayZoomFactor = self.currentDisplayZoomFactor()

                do {
                    let plan = try self.prepareRawCapture(for: displayZoomFactor)
                    settings = self.makePhotoSettings(rawMode: plan.rawMode)
                    rawKind = plan.rawKind
                    shouldRestoreVirtualCamera = plan.shouldRestoreVirtualCamera
                } catch {
                    continuation.resume(throwing: error)
                    return
                }

                self.applyRotationAngleIfSupported(to: self.photoOutput.connection(with: .video))

                let delegate = PhotoCaptureDelegate { [weak self] result in
                    self?.sessionQueue.async {
                        if shouldRestoreVirtualCamera {
                            self?.restoreVirtualCamera(displayZoomFactor: displayZoomFactor)
                        }

                        self?.captureDelegate = nil
                    }

                    switch result {
                    case .success(let payload):
                        continuation.resume(returning: (payload, rawKind))
                    case .failure(let error):
                        continuation.resume(throwing: error)
                    }
                }

                self.captureDelegate = delegate
                self.photoOutput.capturePhoto(with: settings, delegate: delegate)
            }
        }
    }

    private func makePhotoSettings(rawMode: RawCaptureMode) -> AVCapturePhotoSettings {
        let settings = AVCapturePhotoSettings(
            rawPixelFormatType: rawMode.pixelFormat,
            rawFileType: .dng,
            processedFormat: nil,
            processedFileType: nil
        )
        settings.photoQualityPrioritization = .speed
        return settings
    }

    private func prepareRawCapture(for displayZoomFactor: CGFloat) throws -> RawCapturePlan {
        if let bayerRawFormat = preferredBayerRawFormat() {
            return RawCapturePlan(rawMode: .bayer(bayerRawFormat), rawKind: .bayer, shouldRestoreVirtualCamera: false)
        }

        let shouldRestoreVirtualCamera = videoDevice.map(isVirtualBackCamera) ?? false
        let candidates = physicalBackCamerasSorted(for: displayZoomFactor)

        for candidate in candidates {
            do {
                try replaceVideoDevice(with: candidate, displayZoomFactor: displayZoomFactor, publish: false)

                if let bayerRawFormat = preferredBayerRawFormat() {
                    return RawCapturePlan(rawMode: .bayer(bayerRawFormat), rawKind: .bayer, shouldRestoreVirtualCamera: shouldRestoreVirtualCamera)
                }

                if let appleProRawFormat = preferredAppleProRAWFormat() {
                    return RawCapturePlan(rawMode: .appleProRAW(appleProRawFormat), rawKind: .appleProRAW, shouldRestoreVirtualCamera: shouldRestoreVirtualCamera)
                }
            } catch {
                continue
            }
        }

        if shouldRestoreVirtualCamera {
            restoreVirtualCamera(displayZoomFactor: displayZoomFactor)
        }

        throw CameraError.bayerRAWUnavailable
    }

    private func preferredBayerRawFormat() -> OSType? {
        photoOutput.availableRawPhotoPixelFormatTypes.first {
            AVCapturePhotoOutput.isBayerRAWPixelFormat($0)
        }
    }

    private func preferredAppleProRAWFormat() -> OSType? {
        guard photoOutput.isAppleProRAWSupported else { return nil }
        photoOutput.isAppleProRAWEnabled = true

        return photoOutput.availableRawPhotoPixelFormatTypes.first {
            AVCapturePhotoOutput.isAppleProRAWPixelFormat($0)
        }
    }

    private func applyRotationAngleIfSupported(to connection: AVCaptureConnection?) {
        guard let connection, connection.isVideoRotationAngleSupported(rotationAngle) else { return }
        connection.videoRotationAngle = rotationAngle
    }

    private func publishZoomState(for device: AVCaptureDevice) {
        let multiplier = max(zoomDisplayMultiplier(for: device), 0.001)
        let fallbackMinDisplayFactor = device.minAvailableVideoZoomFactor * multiplier
        let fallbackMaxDisplayFactor = device.maxAvailableVideoZoomFactor * multiplier
        let minDisplayFactor = availableLensDisplayFactors().min() ?? fallbackMinDisplayFactor
        let maxDisplayFactor = min(maxAvailableDisplayZoomFactor(fallback: fallbackMaxDisplayFactor), 15)
        let lensFactors = availableLensDisplayFactors()
            .filter { factor in factor >= minDisplayFactor && factor <= maxDisplayFactor }
            .sorted()
            .reduce(into: [CGFloat]()) { result, factor in
                guard !result.contains(where: { abs($0 - factor) < 0.03 }) else { return }
                result.append(factor)
            }

        let state = ZoomState(
            factor: device.videoZoomFactor,
            displayFactor: device.videoZoomFactor * multiplier,
            minFactor: minDisplayFactor,
            maxFactor: maxDisplayFactor,
            lensDisplayFactors: lensFactors
        )

        Task { @MainActor [onZoomStateChange] in
            onZoomStateChange?(state)
        }
    }

    private func zoomDisplayMultiplier(for device: AVCaptureDevice) -> CGFloat {
        switch device.deviceType {
        case .builtInUltraWideCamera:
            return 0.5
        case .builtInWideAngleCamera:
            return 1
        case .builtInTelephotoCamera:
            return 3
        case .builtInTripleCamera, .builtInDualWideCamera:
            let wideSwitchOver = device.virtualDeviceSwitchOverVideoZoomFactors
                .map { CGFloat(truncating: $0) }
                .filter { $0 > device.minAvailableVideoZoomFactor }
                .min()

            return wideSwitchOver.map { 1 / $0 } ?? 1
        default:
            return 1
        }
    }

    private func currentDisplayZoomFactor() -> CGFloat {
        guard let device = videoDevice else { return 1 }
        return device.videoZoomFactor * max(displayZoomMultiplier, 0.001)
    }

    private func setInitialZoom(on device: AVCaptureDevice) {
        try? applyDisplayZoomFactor(1, to: device)
    }

    private func applyDisplayZoomFactor(_ displayFactor: CGFloat, to device: AVCaptureDevice) throws {
        let multiplier = max(zoomDisplayMultiplier(for: device), 0.001)
        let requestedZoom = displayFactor / multiplier
        let clampedZoom = min(max(requestedZoom, device.minAvailableVideoZoomFactor), min(device.maxAvailableVideoZoomFactor, 15 / multiplier))

        try device.lockForConfiguration()
        device.videoZoomFactor = clampedZoom
        device.unlockForConfiguration()
    }

    private func replaceVideoDevice(with device: AVCaptureDevice, displayZoomFactor: CGFloat, publish: Bool) throws {
        if videoDevice?.uniqueID == device.uniqueID {
            try applyCurrentExposureBias(to: device)
            try applyDisplayZoomFactor(displayZoomFactor, to: device)
            if publish {
                publishExposureState(for: device)
                publishZoomState(for: device)
            }
            return
        }

        let newInput = try AVCaptureDeviceInput(device: device)
        let oldInput = videoInput

        session.beginConfiguration()

        if let oldInput {
            session.removeInput(oldInput)
        }

        guard session.canAddInput(newInput) else {
            if let oldInput, session.canAddInput(oldInput) {
                session.addInput(oldInput)
            }
            session.commitConfiguration()
            throw CameraError.configurationFailed
        }

        session.addInput(newInput)
        session.commitConfiguration()

        videoInput = newInput
        videoDevice = device
        displayZoomMultiplier = zoomDisplayMultiplier(for: device)
        try applyCurrentExposureBias(to: device)
        try applyDisplayZoomFactor(displayZoomFactor, to: device)
        applyRotationAngleIfSupported(to: photoOutput.connection(with: .video))

        if publish {
            publishExposureState(for: device)
            publishZoomState(for: device)
        }
    }

    private func restoreVirtualCamera(displayZoomFactor: CGFloat) {
        guard let device = preferredBackCamera() else { return }
        try? replaceVideoDevice(with: device, displayZoomFactor: displayZoomFactor, publish: true)
    }

    private func physicalBackCamerasSorted(for displayZoomFactor: CGFloat) -> [AVCaptureDevice] {
        physicalBackCameras().sorted {
            abs(baseDisplayZoomFactor(for: $0) - displayZoomFactor) < abs(baseDisplayZoomFactor(for: $1) - displayZoomFactor)
        }
    }

    private func physicalBackCameras() -> [AVCaptureDevice] {
        AVCaptureDevice.DiscoverySession(
            deviceTypes: [
                .builtInUltraWideCamera,
                .builtInWideAngleCamera,
                .builtInTelephotoCamera
            ],
            mediaType: .video,
            position: .back
        ).devices
    }

    private func previewDevice(for displayZoomFactor: CGFloat) -> AVCaptureDevice? {
        if displayZoomFactor < 1, let ultraWide = backCamera(.builtInUltraWideCamera) {
            return ultraWide
        }

        if displayZoomFactor >= 3, let telephoto = backCamera(.builtInTelephotoCamera) {
            return telephoto
        }

        return backCamera(.builtInWideAngleCamera) ?? physicalBackCamerasSorted(for: displayZoomFactor).first
    }

    private func availableLensDisplayFactors() -> [CGFloat] {
        physicalBackCameras()
            .map(baseDisplayZoomFactor(for:))
            .sorted()
            .reduce(into: [CGFloat]()) { result, factor in
                guard !result.contains(where: { abs($0 - factor) < 0.03 }) else { return }
                result.append(factor)
            }
    }

    private func maxAvailableDisplayZoomFactor(fallback: CGFloat) -> CGFloat {
        physicalBackCameras()
            .map { $0.maxAvailableVideoZoomFactor * zoomDisplayMultiplier(for: $0) }
            .max() ?? fallback
    }

    private func baseDisplayZoomFactor(for device: AVCaptureDevice) -> CGFloat {
        switch device.deviceType {
        case .builtInUltraWideCamera:
            return 0.5
        case .builtInTelephotoCamera:
            return 3
        default:
            return 1
        }
    }

    private func isVirtualBackCamera(_ device: AVCaptureDevice) -> Bool {
        switch device.deviceType {
        case .builtInTripleCamera, .builtInDualWideCamera, .builtInDualCamera:
            return true
        default:
            return false
        }
    }

    private func applyCurrentExposureBias(to device: AVCaptureDevice) throws {
        try device.lockForConfiguration()
        exposureBias = clampedExposureBias(exposureBias, for: device)
        applyExposureBias(exposureBias, to: device)
        device.unlockForConfiguration()
    }

    private func applyExposureBias(_ bias: CGFloat, to device: AVCaptureDevice) {
        let clampedBias = clampedExposureBias(bias, for: device)
        device.setExposureTargetBias(Float(clampedBias), completionHandler: nil)
    }

    private func clampedExposureBias(_ bias: CGFloat, for device: AVCaptureDevice) -> CGFloat {
        let appMin = max(CGFloat(device.minExposureTargetBias), -2)
        let appMax = min(CGFloat(device.maxExposureTargetBias), 2)
        return min(max(bias, appMin), appMax)
    }

    private func publishExposureState(for device: AVCaptureDevice) {
        let state = ExposureState(
            bias: clampedExposureBias(exposureBias, for: device),
            minBias: max(CGFloat(device.minExposureTargetBias), -2),
            maxBias: min(CGFloat(device.maxExposureTargetBias), 2)
        )

        Task { @MainActor [onExposureStateChange] in
            onExposureStateChange?(state)
        }
    }

    private func save(processedJPEG: Data, rawDNG: Data) async throws {
        let status = PHPhotoLibrary.authorizationStatus(for: .addOnly)
        let allowed: Bool

        switch status {
        case .authorized, .limited:
            allowed = true
        case .notDetermined:
            let requested = await PHPhotoLibrary.requestAuthorization(for: .addOnly)
            allowed = requested == .authorized || requested == .limited
        default:
            allowed = false
        }

        guard allowed else { throw CameraError.saveFailed }

        let resources = try writeTemporaryPhotoResources(processedJPEG: processedJPEG, rawDNG: rawDNG)

        do {
            try await PHPhotoLibrary.shared().performChanges {
                let request = PHAssetCreationRequest.forAsset()

                let jpegOptions = PHAssetResourceCreationOptions()
                jpegOptions.originalFilename = resources.jpegURL.lastPathComponent
                jpegOptions.uniformTypeIdentifier = "public.jpeg"
                jpegOptions.shouldMoveFile = true
                request.addResource(with: .photo, fileURL: resources.jpegURL, options: jpegOptions)

                let rawOptions = PHAssetResourceCreationOptions()
                rawOptions.originalFilename = resources.rawURL.lastPathComponent
                rawOptions.uniformTypeIdentifier = "com.adobe.raw-image"
                rawOptions.shouldMoveFile = true
                request.addResource(with: .alternatePhoto, fileURL: resources.rawURL, options: rawOptions)
            }
        } catch {
            try? FileManager.default.removeItem(at: resources.directoryURL)
            throw CameraError.photoLibraryRejected
        }

        try? FileManager.default.removeItem(at: resources.directoryURL)
    }

    private func writeTemporaryPhotoResources(processedJPEG: Data, rawDNG: Data) throws -> PhotoResourceURLs {
        let directoryURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("ZeroCam-\(UUID().uuidString)", isDirectory: true)
        let timestamp = Int(Date().timeIntervalSince1970)
        let jpegURL = directoryURL.appendingPathComponent("ZeroCam-\(timestamp).jpg")
        let rawURL = directoryURL.appendingPathComponent("ZeroCam-\(timestamp).dng")

        do {
            try FileManager.default.createDirectory(at: directoryURL, withIntermediateDirectories: true)
            try processedJPEG.write(to: jpegURL, options: .atomic)
            try rawDNG.write(to: rawURL, options: .atomic)
        } catch {
            try? FileManager.default.removeItem(at: directoryURL)
            throw CameraError.saveFailed
        }

        return PhotoResourceURLs(directoryURL: directoryURL, jpegURL: jpegURL, rawURL: rawURL)
    }
}

private struct PhotoResourceURLs {
    let directoryURL: URL
    let jpegURL: URL
    let rawURL: URL
}

private enum RawCaptureMode {
    case bayer(OSType)
    case appleProRAW(OSType)

    var pixelFormat: OSType {
        switch self {
        case .bayer(let pixelFormat), .appleProRAW(let pixelFormat):
            return pixelFormat
        }
    }
}

private struct RawCapturePlan {
    let rawMode: RawCaptureMode
    let rawKind: CameraService.RawKind
    let shouldRestoreVirtualCamera: Bool
}

private final class PhotoCaptureDelegate: NSObject, AVCapturePhotoCaptureDelegate {
    struct Payload {
        var rawData: Data?
    }

    private var payload = Payload()
    private var completion: (Result<Payload, Error>) -> Void
    private var didFinish = false

    init(completion: @escaping (Result<Payload, Error>) -> Void) {
        self.completion = completion
    }

    func photoOutput(
        _ output: AVCapturePhotoOutput,
        didFinishProcessingPhoto photo: AVCapturePhoto,
        error: Error?
    ) {
        if let error {
            finish(.failure(error))
            return
        }

        guard let data = photo.fileDataRepresentation() else {
            finish(.failure(CameraService.CameraError.captureFailed))
            return
        }

        if photo.isRawPhoto {
            payload.rawData = data
        }
    }

    func photoOutput(
        _ output: AVCapturePhotoOutput,
        didFinishCaptureFor resolvedSettings: AVCaptureResolvedPhotoSettings,
        error: Error?
    ) {
        if let error {
            finish(.failure(error))
            return
        }

        finish(.success(payload))
    }

    private func finish(_ result: Result<Payload, Error>) {
        guard !didFinish else { return }
        didFinish = true
        completion(result)
    }
}
