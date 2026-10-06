import AppKit
@preconcurrency import AVFoundation
import Vision
import SwiftUI
import TouchOTPCore

// The delegate and its mutable state are confined to the capture session's serial queue.
private final class BarcodeReader: NSObject, AVCaptureVideoDataOutputSampleBufferDelegate, @unchecked Sendable {
    var onCode: ((String) -> Void)?
    private var lastScan = Date.distantPast
    func captureOutput(_ output: AVCaptureOutput, didOutput buffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        guard Date().timeIntervalSince(lastScan) > 0.7 else { return }
        lastScan = Date()
        let request = VNDetectBarcodesRequest()
        request.symbologies = [.qr]
        do {
            try VNImageRequestHandler(cmSampleBuffer: buffer).perform([request])
            for result in request.results ?? [] {
                if let text = result.payloadStringValue, text.hasPrefix("otpauth") { onCode?(text) }
            }
        } catch { /* A blurred frame is expected; try the next frame. */ }
    }
}

@MainActor
final class CameraScanner: ObservableObject {
    let session = AVCaptureSession()
    @Published var error: String?
    private let queue = DispatchQueue(label: "local.touchotp.camera")
    private let reader = BarcodeReader()
    private var generation = UUID()

    func start(onCode: @escaping (String) -> Void) async {
        let started = UUID()
        generation = started
        let granted = await AVCaptureDevice.requestAccess(for: .video)
        guard generation == started else { return }
        guard granted else { error = "Allow Camera access in System Settings, or import a local QR image."; return }
        guard let device = AVCaptureDevice.default(for: .video) else { error = "No camera found. You can import a local QR image instead."; return }
        do {
            let input = try AVCaptureDeviceInput(device: device)
            let output = AVCaptureVideoDataOutput()
            output.alwaysDiscardsLateVideoFrames = true
            output.setSampleBufferDelegate(reader, queue: queue)
            let captureSession = session
            let barcodeReader = reader
            queue.async {
                barcodeReader.onCode = { text in DispatchQueue.main.async { onCode(text) } }
                if captureSession.inputs.isEmpty {
                    captureSession.beginConfiguration()
                    captureSession.sessionPreset = .high
                    guard captureSession.canAddInput(input), captureSession.canAddOutput(output) else {
                        captureSession.commitConfiguration()
                        DispatchQueue.main.async { self.error = "The camera cannot be configured." }
                        return
                    }
                    captureSession.addInput(input); captureSession.addOutput(output)
                    captureSession.commitConfiguration()
                }
                captureSession.startRunning()
            }
        } catch { self.error = error.localizedDescription }
    }

    func stop() {
        generation = UUID()
        let captureSession = session
        queue.async { captureSession.stopRunning() }
    }
}

struct CameraPreview: NSViewRepresentable {
    let session: AVCaptureSession
    final class Preview: NSView {
        var preview: AVCaptureVideoPreviewLayer?
        override func layout() { super.layout(); preview?.frame = bounds }
    }
    func makeNSView(context: Context) -> Preview {
        let view = Preview()
        view.wantsLayer = true
        let preview = AVCaptureVideoPreviewLayer(session: session)
        preview.videoGravity = .resizeAspectFill
        view.layer?.addSublayer(preview); view.preview = preview
        return view
    }
    func updateNSView(_ view: Preview, context: Context) { view.preview?.frame = view.bounds }
}

enum QRImageReader {
    static func read(_ url: URL) throws -> [String] {
        let request = VNDetectBarcodesRequest()
        request.symbologies = [.qr]
        try VNImageRequestHandler(url: url).perform([request])
        let values = (request.results ?? []).compactMap(\.payloadStringValue).filter { $0.hasPrefix("otpauth") }
        guard !values.isEmpty else { throw OTPError("No authenticator QR was found in that image.") }
        return values
    }
}
