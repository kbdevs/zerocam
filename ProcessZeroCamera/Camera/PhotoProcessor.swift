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

        let correctedOutput = applyAdaptiveEdgeChromaCorrection(to: output)
        let colorSpace = CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB()
        guard let jpeg = context.jpegRepresentation(
            of: correctedOutput,
            colorSpace: colorSpace,
            options: [
                kCGImageDestinationLossyCompressionQuality as CIImageRepresentationOption: 0.96
            ]
        ) else {
            throw CameraService.CameraError.processingFailed
        }

        return jpeg
    }

    private func applyAdaptiveEdgeChromaCorrection(to image: CIImage) -> CIImage {
        guard let scale = edgeChromaCorrectionScale(for: image) else { return image }

        let colorBalanced = image.applyingFilter("CIColorMatrix", parameters: [
            "inputRVector": CIVector(x: scale.x, y: 0, z: 0, w: 0),
            "inputGVector": CIVector(x: 0, y: scale.y, z: 0, w: 0),
            "inputBVector": CIVector(x: 0, y: 0, z: scale.z, w: 0),
            "inputAVector": CIVector(x: 0, y: 0, z: 0, w: 1),
            "inputBiasVector": CIVector(x: 0, y: 0, z: 0, w: 0)
        ])
        let corrected = colorBalanced.applyingFilter("CIColorControls", parameters: [
            kCIInputSaturationKey: scale.edgeSaturation
        ])

        let extent = image.extent
        let innerRadius = min(extent.width, extent.height) * 0.42
        let outerRadius = hypot(extent.width, extent.height) * 0.52
        let mask = CIFilter(
            name: "CIRadialGradient",
            parameters: [
                "inputCenter": CIVector(x: extent.midX, y: extent.midY),
                "inputRadius0": innerRadius,
                "inputRadius1": outerRadius,
                "inputColor0": CIColor(red: 0, green: 0, blue: 0, alpha: 0),
                "inputColor1": CIColor(red: 1, green: 1, blue: 1, alpha: 1)
            ]
        )?.outputImage?.cropped(to: extent)

        guard let mask else { return image }

        return corrected.applyingFilter("CIBlendWithMask", parameters: [
            kCIInputBackgroundImageKey: image,
            kCIInputMaskImageKey: mask
        ])
    }

    private func edgeChromaCorrectionScale(for image: CIImage) -> ChromaScale? {
        let extent = image.extent
        guard extent.width > 0, extent.height > 0 else { return nil }

        let sampleWidth = 64
        let sampleHeight = max(1, Int(round(CGFloat(sampleWidth) * extent.height / extent.width)))
        let normalized = image
            .cropped(to: extent)
            .transformed(by: CGAffineTransform(translationX: -extent.minX, y: -extent.minY))
            .transformed(by: CGAffineTransform(
                scaleX: CGFloat(sampleWidth) / extent.width,
                y: CGFloat(sampleHeight) / extent.height
            ))

        let colorSpace = CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB()
        var bitmap = [UInt8](repeating: 0, count: sampleWidth * sampleHeight * 4)
        bitmap.withUnsafeMutableBytes { buffer in
            guard let baseAddress = buffer.baseAddress else { return }
            context.render(
                normalized,
                toBitmap: baseAddress,
                rowBytes: sampleWidth * 4,
                bounds: CGRect(x: 0, y: 0, width: sampleWidth, height: sampleHeight),
                format: .RGBA8,
                colorSpace: colorSpace
            )
        }

        var centerRed: CGFloat = 0
        var centerGreen: CGFloat = 0
        var centerBlue: CGFloat = 0
        var edgeRed: CGFloat = 0
        var edgeGreen: CGFloat = 0
        var edgeBlue: CGFloat = 0
        var centerWeight: CGFloat = 0
        var edgeWeight: CGFloat = 0
        let centerX = CGFloat(sampleWidth - 1) / 2
        let centerY = CGFloat(sampleHeight - 1) / 2

        for y in 0..<sampleHeight {
            for x in 0..<sampleWidth {
                let offset = (y * sampleWidth + x) * 4
                let red = CGFloat(bitmap[offset]) / 255
                let green = CGFloat(bitmap[offset + 1]) / 255
                let blue = CGFloat(bitmap[offset + 2]) / 255
                let luminance = 0.2126 * red + 0.7152 * green + 0.0722 * blue
                guard luminance > 0.06, luminance < 0.92 else { continue }

                let normalizedX = (CGFloat(x) - centerX) / max(centerX, 1)
                let normalizedY = (CGFloat(y) - centerY) / max(centerY, 1)
                let radius = sqrt(normalizedX * normalizedX + normalizedY * normalizedY)
                let maxChannel = max(red, green, blue)
                let minChannel = min(red, green, blue)
                let saturation = (maxChannel - minChannel) / max(maxChannel, 0.001)
                let neutralWeight = max(0, 1 - saturation / 0.38)
                guard neutralWeight > 0 else { continue }

                let weight = neutralWeight * min(max((luminance - 0.06) / 0.18, 0), 1)

                if radius < 0.45 {
                    centerRed += (red / luminance) * weight
                    centerGreen += (green / luminance) * weight
                    centerBlue += (blue / luminance) * weight
                    centerWeight += weight
                } else if radius > 0.72 {
                    edgeRed += (red / luminance) * weight
                    edgeGreen += (green / luminance) * weight
                    edgeBlue += (blue / luminance) * weight
                    edgeWeight += weight
                }
            }
        }

        guard centerWeight > 24, edgeWeight > 80 else { return nil }

        let centerAverage = ChromaScale(
            x: centerRed / centerWeight,
            y: centerGreen / centerWeight,
            z: centerBlue / centerWeight
        )
        let edgeAverage = ChromaScale(
            x: edgeRed / edgeWeight,
            y: edgeGreen / edgeWeight,
            z: edgeBlue / edgeWeight
        )
        let chromaDelta = ChromaScale(
            x: edgeAverage.x - centerAverage.x,
            y: edgeAverage.y - centerAverage.y,
            z: edgeAverage.z - centerAverage.z
        )
        let chromaDistance = sqrt(
            chromaDelta.x * chromaDelta.x +
            chromaDelta.y * chromaDelta.y +
            chromaDelta.z * chromaDelta.z
        )
        guard chromaDistance > 0.04 else { return nil }

        var scale = ChromaScale(
            centerAverage.x / max(edgeAverage.x, 0.001),
            centerAverage.y / max(edgeAverage.y, 0.001),
            centerAverage.z / max(edgeAverage.z, 0.001)
        )

        let luminanceNormalizer = max(0.2126 * scale.x + 0.7152 * scale.y + 0.0722 * scale.z, 0.001)
        scale.x /= luminanceNormalizer
        scale.y /= luminanceNormalizer
        scale.z /= luminanceNormalizer

        let strength = min((chromaDistance - 0.035) * 3.1, 0.72)
        let edgeSaturation = max(0.82, 1 - min((chromaDistance - 0.035) * 1.35, 0.16))
        return ChromaScale(
            min(max(1 + ((scale.x - 1) * strength), 0.90), 1.10),
            min(max(1 + ((scale.y - 1) * strength), 0.90), 1.10),
            min(max(1 + ((scale.z - 1) * strength), 0.90), 1.10),
            edgeSaturation: edgeSaturation
        )
    }
}

private struct ChromaScale {
    var x: CGFloat
    var y: CGFloat
    var z: CGFloat
    var edgeSaturation: CGFloat

    init(_ x: CGFloat, _ y: CGFloat, _ z: CGFloat, edgeSaturation: CGFloat = 1) {
        self.x = x
        self.y = y
        self.z = z
        self.edgeSaturation = edgeSaturation
    }

    init(x: CGFloat, y: CGFloat, z: CGFloat, edgeSaturation: CGFloat = 1) {
        self.x = x
        self.y = y
        self.z = z
        self.edgeSaturation = edgeSaturation
    }
}
