import SwiftUI
import UIKit

struct CameraView: View {
    @StateObject private var viewModel = CameraViewModel(camera: CameraService())

    var body: some View {
        GeometryReader { geometry in
            let isLandscape = geometry.size.width > geometry.size.height

            ZStack {
                Color.black.ignoresSafeArea()

                switch viewModel.authorizationState {
                case .authorized:
                    CameraPreview(
                        session: viewModel.session,
                        interfaceOrientation: viewModel.interfaceOrientation,
                        onTapToFocus: viewModel.focus(at:viewPoint:)
                    )
                        .ignoresSafeArea()
                        .overlay {
                            if let focusPoint = viewModel.focusPoint {
                                FocusReticle()
                                    .position(focusPoint)
                                    .transition(.scale.combined(with: .opacity))
                            }
                        }
                case .notDetermined:
                    ProgressView()
                        .tint(.white)
                case .denied:
                    VStack(spacing: 12) {
                        Image(systemName: "camera.fill")
                            .font(.system(size: 42, weight: .medium))
                        Text("Camera access is off")
                            .font(.headline)
                        Text("Enable camera access in Settings to shoot.")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                    .foregroundStyle(.white)
                    .multilineTextAlignment(.center)
                    .padding(32)
                }

                controls(isLandscape: isLandscape)
            }
            .statusBarHidden()
            .task {
                await viewModel.start()
            }
            .onAppear {
                viewModel.refreshInterfaceOrientation()
            }
            .onReceive(NotificationCenter.default.publisher(for: UIDevice.orientationDidChangeNotification)) { _ in
                viewModel.refreshInterfaceOrientation()
            }
            .onDisappear {
                viewModel.stop()
            }
            .overlay(alignment: .top) {
                if let message = viewModel.message {
                    Text(message)
                        .font(.footnote.weight(.semibold))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 14)
                        .padding(.vertical, 8)
                        .background(.black.opacity(0.48), in: Capsule())
                        .padding(.top, 18)
                        .transition(.move(edge: .top).combined(with: .opacity))
                }
            }
            .animation(.snappy(duration: 0.2), value: viewModel.message)
            .fullScreenCover(isPresented: $viewModel.showingLastCapture) {
                LastCaptureViewer(image: viewModel.lastCapturedImage) {
                    viewModel.showingLastCapture = false
                }
            }
        }
    }

    @ViewBuilder
    private func controls(isLandscape: Bool) -> some View {
        if isLandscape {
            HStack {
                Spacer()
                HStack(spacing: 6) {
                    exposureControl(isLandscape: true)
                    zoomControl(isLandscape: true)
                    captureCluster(isLandscape: true)
                }
                .frame(maxHeight: .infinity)
                .padding(.trailing, 12)
            }
        } else {
            VStack {
                Spacer()
                exposureControl(isLandscape: false)
                    .padding(.bottom, 2)
                zoomControl(isLandscape: false)
                    .padding(.bottom, 2)
                captureCluster(isLandscape: false)
                .padding(.bottom, 28)
            }
        }
    }

    private func exposureControl(isLandscape: Bool) -> some View {
        ExposureControl(
            exposureState: viewModel.exposureState,
            isLandscape: isLandscape,
            onExposureChanged: viewModel.setExposureBias(_:)
        )
    }

    private func zoomControl(isLandscape: Bool) -> some View {
        ZoomControl(
            zoomState: viewModel.zoomState,
            isLandscape: isLandscape,
            onZoomChanged: viewModel.setZoom(displayFactor:)
        )
    }

    @ViewBuilder
    private func captureCluster(isLandscape: Bool) -> some View {
        if isLandscape {
            ZStack {
                shutterButton

                lastCaptureButton
                    .offset(y: 80)
            }
            .frame(width: 92, height: 232)
        } else {
            GeometryReader { geometry in
                let thumbnailOffset = min(112, max(0, geometry.size.width / 2 - 50))

                ZStack {
                    shutterButton

                    lastCaptureButton
                        .offset(x: thumbnailOffset)
                }
                .frame(width: geometry.size.width, height: geometry.size.height)
            }
            .frame(height: 96)
        }
    }

    private var shutterButton: some View {
        Button {
            viewModel.capture()
        } label: {
            ZStack {
                Circle()
                    .stroke(.white, lineWidth: 4)
                    .frame(width: 78, height: 78)

                Circle()
                    .fill(.white)
                    .frame(width: viewModel.isCapturing ? 58 : 64, height: viewModel.isCapturing ? 58 : 64)
            }
            .frame(width: 92, height: 92)
            .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .disabled(viewModel.authorizationState != .authorized || viewModel.isCapturing)
        .opacity(viewModel.authorizationState == .authorized ? 1 : 0.45)
        .accessibilityLabel("Take photo")
    }

    private var lastCaptureButton: some View {
        Button {
            viewModel.showLastCapture()
        } label: {
            LastCaptureThumbnail(image: viewModel.lastCapturedImage)
        }
        .buttonStyle(.plain)
        .disabled(viewModel.lastCapturedImage == nil)
        .opacity(viewModel.lastCapturedImage == nil ? 0.62 : 1)
        .accessibilityLabel("Last photo")
    }
}

private struct FocusReticle: View {
    var body: some View {
        RoundedRectangle(cornerRadius: 6)
            .stroke(.yellow, lineWidth: 1.5)
            .frame(width: 76, height: 76)
            .shadow(color: .black.opacity(0.4), radius: 4)
            .allowsHitTesting(false)
    }
}

private struct LastCaptureThumbnail: View {
    let image: UIImage?

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 11, style: .continuous)
                .fill(.black.opacity(0.46))

            if let image {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFill()
            } else {
                Image(systemName: "photo")
                    .font(.system(size: 20, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.52))
            }
        }
        .frame(width: 58, height: 58)
        .clipShape(RoundedRectangle(cornerRadius: 11, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 11, style: .continuous)
                .stroke(.white.opacity(image == nil ? 0.24 : 0.86), lineWidth: image == nil ? 1 : 2)
        }
        .shadow(color: .black.opacity(0.35), radius: 8, y: 3)
        .contentShape(RoundedRectangle(cornerRadius: 11, style: .continuous))
    }
}

private struct LastCaptureViewer: View {
    let image: UIImage?
    let onDismiss: () -> Void

    @State private var dragOffset: CGFloat = 0
    @State private var zoomScale: CGFloat = 1
    @State private var settledZoomScale: CGFloat = 1
    @State private var panOffset: CGSize = .zero
    @State private var settledPanOffset: CGSize = .zero

    var body: some View {
        GeometryReader { geometry in
            ZStack {
                Color.black
                    .opacity(backgroundOpacity)
                    .ignoresSafeArea()

                photoContent
                    .offset(x: panOffset.width, y: panOffset.height + dragOffset)
                    .scaleEffect(contentScale)

                VStack {
                    HStack {
                        Spacer()
                        Button(action: onDismiss) {
                            Image(systemName: "xmark")
                                .font(.system(size: 17, weight: .bold))
                                .foregroundStyle(.white)
                                .frame(width: 44, height: 44)
                                .background(.black.opacity(0.48), in: Circle())
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("Close")
                    }
                    Spacer()
                }
                .padding(.top, 12)
                .padding(.horizontal, 18)
            }
            .contentShape(Rectangle())
            .gesture(dragGesture(in: geometry.size))
            .simultaneousGesture(zoomGesture(in: geometry.size))
            .onTapGesture(count: 2) {
                toggleZoom(in: geometry.size)
            }
        }
    }

    @ViewBuilder
    private var photoContent: some View {
        if let image {
            Image(uiImage: image)
                .resizable()
                .scaledToFit()
                .ignoresSafeArea()
        }
    }

    private var backgroundOpacity: Double {
        max(0.35, 1 - Double(dragOffset / 420))
    }

    private var contentScale: CGFloat {
        zoomScale * max(0.92, 1 - dragOffset / 2200)
    }

    private var isZoomed: Bool {
        zoomScale > 1.01
    }

    private func dragGesture(in size: CGSize) -> some Gesture {
        DragGesture(minimumDistance: 8)
            .onChanged { value in
                if isZoomed {
                    let nextOffset = CGSize(
                        width: settledPanOffset.width + value.translation.width,
                        height: settledPanOffset.height + value.translation.height
                    )
                    panOffset = clampedPanOffset(nextOffset, scale: zoomScale, in: size)
                    return
                }

                guard value.translation.height > 0, abs(value.translation.height) > abs(value.translation.width) else { return }
                dragOffset = value.translation.height
            }
            .onEnded { value in
                if isZoomed {
                    let nextOffset = CGSize(
                        width: settledPanOffset.width + value.translation.width,
                        height: settledPanOffset.height + value.translation.height
                    )
                    settledPanOffset = clampedPanOffset(nextOffset, scale: zoomScale, in: size)
                    panOffset = settledPanOffset
                    return
                }

                let shouldDismiss = value.translation.height > 110 || value.predictedEndTranslation.height > 220

                if shouldDismiss {
                    onDismiss()
                } else {
                    withAnimation(.spring(response: 0.28, dampingFraction: 0.86)) {
                        dragOffset = 0
                    }
                }
            }
    }

    private func zoomGesture(in size: CGSize) -> some Gesture {
        MagnificationGesture()
            .onChanged { value in
                let nextScale = clampedZoomScale(settledZoomScale * value)
                zoomScale = nextScale
                panOffset = clampedPanOffset(panOffset, scale: nextScale, in: size)
            }
            .onEnded { value in
                let nextScale = clampedZoomScale(settledZoomScale * value)
                settleZoomScale(nextScale, in: size, animated: nextScale <= 1.01)
            }
    }

    private func toggleZoom(in size: CGSize) {
        let nextScale: CGFloat = isZoomed ? 1 : 2.5
        settleZoomScale(nextScale, in: size, animated: true)
    }

    private func settleZoomScale(_ scale: CGFloat, in size: CGSize, animated: Bool) {
        let nextScale = scale <= 1.01 ? 1 : clampedZoomScale(scale)
        let nextPanOffset = nextScale == 1 ? .zero : clampedPanOffset(panOffset, scale: nextScale, in: size)

        let updates = {
            zoomScale = nextScale
            settledZoomScale = nextScale
            panOffset = nextPanOffset
            settledPanOffset = nextPanOffset
            dragOffset = 0
        }

        if animated {
            withAnimation(.spring(response: 0.28, dampingFraction: 0.86)) {
                updates()
            }
        } else {
            updates()
        }
    }

    private func clampedZoomScale(_ scale: CGFloat) -> CGFloat {
        min(max(scale, 1), 6)
    }

    private func clampedPanOffset(_ offset: CGSize, scale: CGFloat, in size: CGSize) -> CGSize {
        guard scale > 1 else { return .zero }

        let maxX = size.width * (scale - 1) / 2
        let maxY = size.height * (scale - 1) / 2

        return CGSize(
            width: min(max(offset.width, -maxX), maxX),
            height: min(max(offset.height, -maxY), maxY)
        )
    }
}

private struct ExposureControl: View {
    let exposureState: CameraService.ExposureState
    let isLandscape: Bool
    let onExposureChanged: (CGFloat) -> Void

    @State private var isDragging = false
    @State private var dragStartBias: CGFloat?

    var body: some View {
        GeometryReader { geometry in
            let rawLength = isLandscape ? geometry.size.height - 24 : geometry.size.width - 48
            let maxLength: CGFloat = isLandscape ? 220 : 300
            let minLength: CGFloat = isLandscape ? 170 : 180
            let availableLength = max(min(rawLength, maxLength), minLength)

            ZStack {
                if isDragging {
                    slider(length: availableLength)
                        .transition(.scale(scale: 0.92).combined(with: .opacity))
                }

                exposureBubble
                    .offset(bubbleOffset(for: exposureState.bias, length: availableLength))
                    .gesture(dragGesture(length: availableLength))
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(width: isLandscape ? 60 : nil, height: isLandscape ? 236 : 42)
        .animation(.snappy(duration: 0.18), value: isDragging)
        .animation(.snappy(duration: 0.18), value: exposureState.bias)
    }

    private var exposureBubble: some View {
        Text(exposureLabel(exposureState.bias))
            .font(.system(size: 13, weight: .bold, design: .rounded))
            .monospacedDigit()
            .foregroundStyle(.white)
            .frame(width: 60, height: 34)
            .background(.black.opacity(0.56), in: Capsule())
            .overlay {
                Capsule()
                    .stroke(.white.opacity(0.18), lineWidth: 1)
            }
            .contentShape(Capsule())
    }

    private func slider(length: CGFloat) -> some View {
        ZStack {
            Capsule()
                .fill(.black.opacity(0.46))
                .frame(width: isLandscape ? 4 : length, height: isLandscape ? length : 4)

            ForEach(exposureMarks, id: \.self) { bias in
                marker(for: bias)
                    .offset(markerOffset(for: bias, length: length))
            }
        }
        .frame(width: isLandscape ? 58 : length, height: isLandscape ? length : 50)
    }

    private var exposureMarks: [CGFloat] {
        [exposureState.minBias, 0, exposureState.maxBias]
    }

    @ViewBuilder
    private func marker(for bias: CGFloat) -> some View {
        if isLandscape {
            HStack(spacing: 7) {
                Text(markLabel(bias))
                    .font(.system(size: 11, weight: .semibold, design: .rounded))
                    .monospacedDigit()
                    .foregroundStyle(.white.opacity(isNearCurrent(bias) ? 1 : 0.75))
                    .frame(width: 34, alignment: .trailing)
                Circle()
                    .fill(.white.opacity(isNearCurrent(bias) ? 1 : 0.68))
                    .frame(width: isNearCurrent(bias) ? 8 : 6, height: isNearCurrent(bias) ? 8 : 6)
            }
            .offset(x: -18)
        } else {
            VStack(spacing: 7) {
                Circle()
                    .fill(.white.opacity(isNearCurrent(bias) ? 1 : 0.68))
                    .frame(width: isNearCurrent(bias) ? 8 : 6, height: isNearCurrent(bias) ? 8 : 6)
                Text(markLabel(bias))
                    .font(.system(size: 11, weight: .semibold, design: .rounded))
                    .monospacedDigit()
                    .foregroundStyle(.white.opacity(isNearCurrent(bias) ? 1 : 0.75))
            }
            .offset(y: 12)
        }
    }

    private func dragGesture(length: CGFloat) -> some Gesture {
        DragGesture(minimumDistance: 0)
            .onChanged { value in
                if dragStartBias == nil {
                    dragStartBias = exposureState.bias
                }

                isDragging = true
                let startOffset = axisOffset(for: dragStartBias ?? exposureState.bias, length: length)
                let translation = isLandscape ? -value.translation.height : value.translation.width
                onExposureChanged(stickyBias(bias(forOffset: startOffset + translation, length: length)))
            }
            .onEnded { value in
                let startOffset = axisOffset(for: dragStartBias ?? exposureState.bias, length: length)
                let translation = isLandscape ? -value.translation.height : value.translation.width
                onExposureChanged(stickyBias(bias(forOffset: startOffset + translation, length: length)))
                isDragging = false
                dragStartBias = nil
            }
    }

    private func bias(forOffset offset: CGFloat, length: CGFloat) -> CGFloat {
        let normalized = min(max(offset / (length / 2), -1), 1)

        if normalized < 0 {
            return normalized * abs(exposureState.minBias)
        }

        return normalized * exposureState.maxBias
    }

    private func axisOffset(for bias: CGFloat, length: CGFloat) -> CGFloat {
        if bias < 0 {
            return (bias / max(abs(exposureState.minBias), 0.001)) * (length / 2)
        }

        return (bias / max(exposureState.maxBias, 0.001)) * (length / 2)
    }

    private func bubbleOffset(for bias: CGFloat, length: CGFloat) -> CGSize {
        let offset = axisOffset(for: bias, length: length)
        return isLandscape ? CGSize(width: 0, height: -offset) : CGSize(width: offset, height: 0)
    }

    private func markerOffset(for bias: CGFloat, length: CGFloat) -> CGSize {
        let offset = axisOffset(for: bias, length: length)
        return isLandscape ? CGSize(width: 0, height: -offset) : CGSize(width: offset, height: 0)
    }

    private func stickyBias(_ bias: CGFloat) -> CGFloat {
        abs(bias) < 0.08 ? 0 : bias
    }

    private func isNearCurrent(_ bias: CGFloat) -> Bool {
        abs(bias - exposureState.bias) < 0.08
    }

    private func exposureLabel(_ bias: CGFloat) -> String {
        if abs(bias) < 0.05 {
            return "EV 0"
        }

        return String(format: "EV %+0.1f", bias)
    }

    private func markLabel(_ bias: CGFloat) -> String {
        if abs(bias) < 0.05 {
            return "0"
        }

        return String(format: "%+0.0f", bias)
    }
}

private struct ZoomControl: View {
    let zoomState: CameraService.ZoomState
    let isLandscape: Bool
    let onZoomChanged: (CGFloat) -> Void

    @State private var isDragging = false
    @State private var dragStartFactor: CGFloat?

    var body: some View {
        GeometryReader { geometry in
            let rawLength = isLandscape ? geometry.size.height - 24 : geometry.size.width - 36
            let maxLength: CGFloat = isLandscape ? 238 : 340
            let minLength: CGFloat = isLandscape ? 184 : 220
            let availableLength = max(min(rawLength, maxLength), minLength)

            ZStack {
                if isDragging {
                    slider(length: availableLength)
                        .transition(.scale(scale: 0.92).combined(with: .opacity))
                }

                zoomBubble
                    .offset(bubbleOffset(for: zoomState.displayFactor, length: availableLength))
                    .gesture(dragGesture(length: availableLength))
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(width: isLandscape ? 60 : nil, height: isLandscape ? 254 : 46)
        .animation(.snappy(duration: 0.18), value: isDragging)
        .animation(.snappy(duration: 0.18), value: zoomState.displayFactor)
    }

    private var zoomBubble: some View {
        Text(zoomLabel(zoomState.displayFactor))
            .font(.system(size: 14, weight: .bold, design: .rounded))
            .monospacedDigit()
            .foregroundStyle(.white)
            .frame(width: 52, height: 38)
            .background(.black.opacity(0.56), in: Capsule())
            .overlay {
                Capsule()
                    .stroke(.white.opacity(0.18), lineWidth: 1)
            }
            .contentShape(Capsule())
    }

    private func slider(length: CGFloat) -> some View {
        ZStack {
            Capsule()
                .fill(.black.opacity(0.46))
                .frame(width: isLandscape ? 4 : length, height: isLandscape ? length : 4)

            ForEach(zoomState.lensDisplayFactors, id: \.self) { factor in
                marker(for: factor)
                    .offset(markerOffset(for: factor, length: length))
            }
        }
        .frame(width: isLandscape ? 58 : length, height: isLandscape ? length : 50)
    }

    @ViewBuilder
    private func marker(for factor: CGFloat) -> some View {
        if isLandscape {
            HStack(spacing: 7) {
                Text(zoomLabel(factor))
                    .font(.system(size: 11, weight: .semibold, design: .rounded))
                    .monospacedDigit()
                    .foregroundStyle(.white.opacity(isNearCurrent(factor) ? 1 : 0.75))
                    .frame(width: 30, alignment: .trailing)
                Circle()
                    .fill(.white.opacity(isNearCurrent(factor) ? 1 : 0.68))
                    .frame(width: isNearCurrent(factor) ? 8 : 6, height: isNearCurrent(factor) ? 8 : 6)
            }
            .offset(x: -18)
        } else {
            VStack(spacing: 7) {
                Circle()
                    .fill(.white.opacity(isNearCurrent(factor) ? 1 : 0.68))
                    .frame(width: isNearCurrent(factor) ? 8 : 6, height: isNearCurrent(factor) ? 8 : 6)
                Text(zoomLabel(factor))
                    .font(.system(size: 11, weight: .semibold, design: .rounded))
                    .monospacedDigit()
                    .foregroundStyle(.white.opacity(isNearCurrent(factor) ? 1 : 0.75))
            }
            .offset(y: 12)
        }
    }

    private func dragGesture(length: CGFloat) -> some Gesture {
        DragGesture(minimumDistance: 0)
            .onChanged { value in
                if dragStartFactor == nil {
                    dragStartFactor = zoomState.displayFactor
                }

                isDragging = true
                let startOffset = axisOffset(for: dragStartFactor ?? zoomState.displayFactor, length: length)
                let translation = isLandscape ? -value.translation.height : value.translation.width
                let raw = factor(forOffset: startOffset + translation, length: length)
                onZoomChanged(stickyFactor(raw))
            }
            .onEnded { value in
                let startOffset = axisOffset(for: dragStartFactor ?? zoomState.displayFactor, length: length)
                let translation = isLandscape ? -value.translation.height : value.translation.width
                let raw = factor(forOffset: startOffset + translation, length: length)
                onZoomChanged(stickyFactor(raw))
                isDragging = false
                dragStartFactor = nil
            }
    }

    private func factor(forOffset offset: CGFloat, length: CGFloat) -> CGFloat {
        let normalized = min(max(offset / (length / 2), -1), 1)

        if normalized < 0 {
            return 1 + normalized * (1 - zoomState.minFactor)
        }

        let maxFactor = max(zoomState.maxFactor, 1.01)
        return pow(maxFactor, normalized)
    }

    private func axisOffset(for factor: CGFloat, length: CGFloat) -> CGFloat {
        let clamped = min(max(factor, zoomState.minFactor), zoomState.maxFactor)

        if clamped < 1 {
            let span = max(1 - zoomState.minFactor, 0.001)
            return ((clamped - 1) / span) * (length / 2)
        }

        let maxFactor = max(zoomState.maxFactor, 1.01)
        return (log(clamped) / log(maxFactor)) * (length / 2)
    }

    private func bubbleOffset(for factor: CGFloat, length: CGFloat) -> CGSize {
        let offset = axisOffset(for: factor, length: length)
        return isLandscape ? CGSize(width: 0, height: -offset) : CGSize(width: offset, height: 0)
    }

    private func markerOffset(for factor: CGFloat, length: CGFloat) -> CGSize {
        let offset = axisOffset(for: factor, length: length)
        return isLandscape ? CGSize(width: 0, height: -offset) : CGSize(width: offset, height: 0)
    }

    private func stickyFactor(_ factor: CGFloat) -> CGFloat {
        let clamped = min(max(factor, zoomState.minFactor), zoomState.maxFactor)
        let sticky = zoomState.lensDisplayFactors.first { abs(axisOffset(for: $0, length: 300) - axisOffset(for: clamped, length: 300)) < 18 }
        return sticky ?? clamped
    }

    private func isNearCurrent(_ factor: CGFloat) -> Bool {
        abs(factor - zoomState.displayFactor) < 0.06
    }

    private func zoomLabel(_ factor: CGFloat) -> String {
        if abs(factor.rounded() - factor) < 0.06 {
            return "\(Int(factor.rounded()))x"
        }

        return String(format: "%.1fx", factor)
    }
}

#Preview {
    CameraView()
}
