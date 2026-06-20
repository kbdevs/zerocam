import CoreImage
import ImageIO
import UIKit

final class PhotoProcessor {
    private let context = CIContext(options: [
        .workingColorSpace: CGColorSpace(name: CGColorSpace.displayP3) as Any,
        .outputColorSpace: CGColorSpace(name: CGColorSpace.sRGB) as Any
    ])

    func renderZeroJPEG(from rawData: Data) throws -> Data {
        guard let filter = CIRAWFilter(imageData: rawData, identifierHint: nil) else {
            throw CameraService.CameraError.processingFailed
        }

        filter.isDraftModeEnabled = false
        filter.scaleFactor = 1
        filter.boostAmount = 0.22
        filter.boostShadowAmount = 1
        filter.exposure = 0
        filter.extendedDynamicRangeAmount = 0
        filter.isGamutMappingEnabled = true

        if #available(iOS 26.0, *), filter.isHighlightRecoverySupported {
            filter.isHighlightRecoveryEnabled = false
        }

        if filter.isLensCorrectionSupported {
            filter.isLensCorrectionEnabled = true
        }

        if filter.isLuminanceNoiseReductionSupported {
            filter.luminanceNoiseReductionAmount = 0
        }

        if filter.isColorNoiseReductionSupported {
            filter.colorNoiseReductionAmount = 0
        }

        if filter.isSharpnessSupported {
            filter.sharpnessAmount = 0
        }

        if filter.isContrastSupported {
            filter.contrastAmount = 0
        }

        if filter.isDetailSupported {
            filter.detailAmount = 0
        }

        if filter.isLocalToneMapSupported {
            filter.localToneMapAmount = 0
        }

        guard let output = filter.outputImage else {
            throw CameraService.CameraError.processingFailed
        }

        let colorSpace = CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB()
        guard let jpeg = context.jpegRepresentation(
            of: output,
            colorSpace: colorSpace,
            options: [
                kCGImageDestinationLossyCompressionQuality as CIImageRepresentationOption: 0.96
            ]
        ) else {
            throw CameraService.CameraError.processingFailed
        }

        return jpeg
    }
}
