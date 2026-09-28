//
//  QRScannerView.swift
//  HopChat-1
//
//  QR scanning for safety-number verification. `NSCameraUsageDescription` is in
//  Info.plist; denial, restriction and "no camera at all" (Simulator) are all
//  handled with an explanation rather than a blank screen.
//

import SwiftUI
import AVFoundation
import os

struct QRScannerView: View {

    /// Called with the scanned string; the view dismisses itself first.
    let onScan: (String) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var authorization = AVCaptureDevice.authorizationStatus(for: .video)
    @State private var hasCamera = QRScannerView.cameraAvailable
    @State private var didScan = false

    nonisolated static var cameraAvailable: Bool {
        AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .back) != nil
    }

    var body: some View {
        NavigationStack {
            Group {
                if !hasCamera {
                    message(title: String(localized: "No camera available"),
                            body: String(localized: "This device has no camera, so QR scanning isn't possible. You can compare the digits out loud instead and mark the contact as verified manually."),
                            systemImage: "camera.slash")
                } else {
                    switch authorization {
                    case .authorized:
                        scanner
                    case .notDetermined:
                        message(title: String(localized: "Camera access needed"),
                                body: String(localized: "hoppin uses the camera only to scan your contact's verification QR code."),
                                systemImage: "camera",
                                actionTitle: String(localized: "Allow Camera")) {
                            AVCaptureDevice.requestAccess(for: .video) { granted in
                                Task { @MainActor in
                                    authorization = granted ? .authorized : .denied
                                }
                            }
                        }
                    case .denied, .restricted:
                        message(title: String(localized: "Camera access is off"),
                                body: String(localized: "Turn on camera access for hoppin in Settings to scan a verification code, or compare the digits out loud instead."),
                                systemImage: "camera.slash",
                                actionTitle: String(localized: "Open Settings")) {
                            if let url = URL(string: UIApplication.openSettingsURLString) {
                                UIApplication.shared.open(url)
                            }
                        }
                    @unknown default:
                        message(title: String(localized: "Camera unavailable"),
                                body: String(localized: "hoppin can't use the camera right now."),
                                systemImage: "camera.slash")
                    }
                }
            }
            .navigationTitle("Scan Code")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
            }
        }
    }

    private var scanner: some View {
        ZStack(alignment: .bottom) {
            CameraScannerRepresentable { value in
                guard !didScan else { return }
                didScan = true
                Log.ui.debug("qr scanned")
                dismiss()
                onScan(value)
            }
            .ignoresSafeArea(edges: .bottom)
            .accessibilityLabel(Text("Camera viewfinder. Point it at your contact's QR code."))

            Text("Point the camera at the QR code on your contact's screen.")
                .font(.footnote)
                .multilineTextAlignment(.center)
                .padding()
                .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 12))
                .padding()
        }
    }

    private func message(title: String,
                         body: String,
                         systemImage: String,
                         actionTitle: String? = nil,
                         action: (() -> Void)? = nil) -> some View {
        VStack(spacing: 16) {
            Image(systemName: systemImage)
                .font(.largeTitle)
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)
            Text(title)
                .font(.headline)
            Text(body)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            if let actionTitle, let action {
                Button(action: action) {
                    Text(actionTitle)
                        .font(.headline)
                        .frame(minHeight: 44)
                        .padding(.horizontal, 24)
                }
                .buttonStyle(.ink)
            }
        }
        .padding(24)
        .frame(maxWidth: 480)
    }
}

// MARK: - AVFoundation

struct CameraScannerRepresentable: UIViewControllerRepresentable {

    let onScan: (String) -> Void

    func makeUIViewController(context: Context) -> ScannerController {
        let controller = ScannerController()
        controller.onScan = onScan
        return controller
    }

    func updateUIViewController(_ controller: ScannerController, context: Context) {
        controller.onScan = onScan
    }

    final class ScannerController: UIViewController, AVCaptureMetadataOutputObjectsDelegate {

        var onScan: ((String) -> Void)?
        private let session = AVCaptureSession()
        private var previewLayer: AVCaptureVideoPreviewLayer?
        private let sessionQueue = DispatchQueue(label: "hoppin.qr.session")

        override func viewDidLoad() {
            super.viewDidLoad()
            view.backgroundColor = .black
            configure()
        }

        private func configure() {
            guard let device = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .back),
                  let input = try? AVCaptureDeviceInput(device: device),
                  session.canAddInput(input) else {
                Log.ui.error("qr scanner: no usable camera input")
                return
            }
            session.addInput(input)

            let output = AVCaptureMetadataOutput()
            guard session.canAddOutput(output) else { return }
            session.addOutput(output)
            output.setMetadataObjectsDelegate(self, queue: .main)
            output.metadataObjectTypes = output.availableMetadataObjectTypes.contains(.qr) ? [.qr] : []

            let layer = AVCaptureVideoPreviewLayer(session: session)
            layer.videoGravity = .resizeAspectFill
            layer.frame = view.bounds
            view.layer.addSublayer(layer)
            previewLayer = layer
        }

        override func viewWillAppear(_ animated: Bool) {
            super.viewWillAppear(animated)
            let session = self.session
            sessionQueue.async {
                if !session.isRunning { session.startRunning() }
            }
        }

        override func viewDidDisappear(_ animated: Bool) {
            super.viewDidDisappear(animated)
            let session = self.session
            sessionQueue.async {
                if session.isRunning { session.stopRunning() }
            }
        }

        override func viewDidLayoutSubviews() {
            super.viewDidLayoutSubviews()
            previewLayer?.frame = view.bounds
        }

        nonisolated func metadataOutput(_ output: AVCaptureMetadataOutput,
                                        didOutput metadataObjects: [AVMetadataObject],
                                        from connection: AVCaptureConnection) {
            MainActor.assumeIsolated {
                guard let object = metadataObjects.first as? AVMetadataMachineReadableCodeObject,
                      object.type == .qr,
                      let value = object.stringValue else { return }
                onScan?(value)
            }
        }
    }
}
