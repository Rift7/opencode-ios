#if canImport(AVFoundation) && os(iOS)
  import AVFoundation
  import Foundation

  /// The production QR boundary. It owns one capture session at a time and emits decoded payloads;
  /// it never parses, confirms or redeems a code. Simulator tests replace the client.
  @MainActor
  public final class QRCameraScanner: NSObject, AVCaptureMetadataOutputObjectsDelegate {
    public static let shared = QRCameraScanner()

    public private(set) var captureSession: AVCaptureSession?
    private var continuation: AsyncStream<PairingScanEvent>.Continuation?

    func events() async -> AsyncStream<PairingScanEvent> {
      await start()
    }

    func stopScanning() {
      stop()
    }

    private func start() async -> AsyncStream<PairingScanEvent> {
      stop()
      let stream = AsyncStream<PairingScanEvent> { continuation in
        self.continuation = continuation
        continuation.onTermination = { @Sendable _ in
          Task { @MainActor in self.stop() }
        }
      }
      guard let continuation = self.continuation else { return stream }
      switch AVCaptureDevice.authorizationStatus(for: .video) {
      case .authorized:
        break
      case .notDetermined:
        let granted = await AVCaptureDevice.requestAccess(for: .video)
        guard granted else {
          continuation.yield(.denied)
          continuation.finish()
          return stream
        }
      case .denied:
        continuation.yield(.denied)
        continuation.finish()
        return stream
      case .restricted:
        continuation.yield(.restricted)
        continuation.finish()
        return stream
      @unknown default:
        continuation.yield(.failed)
        continuation.finish()
        return stream
      }

      guard let device = AVCaptureDevice.default(for: .video),
        let input = try? AVCaptureDeviceInput(device: device)
      else {
        continuation.yield(.unavailable)
        continuation.finish()
        return stream
      }
      let session = AVCaptureSession()
      session.beginConfiguration()
      guard session.canAddInput(input) else {
        session.commitConfiguration()
        continuation.yield(.unavailable)
        continuation.finish()
        return stream
      }
      session.addInput(input)
      let output = AVCaptureMetadataOutput()
      guard session.canAddOutput(output) else {
        session.commitConfiguration()
        continuation.yield(.unavailable)
        continuation.finish()
        return stream
      }
      session.addOutput(output)
      output.setMetadataObjectsDelegate(self, queue: .main)
      output.metadataObjectTypes = output.availableMetadataObjectTypes.contains(.qr) ? [.qr] : []
      session.commitConfiguration()
      self.captureSession = session
      session.startRunning()
      return stream
    }

    private func stop() {
      captureSession?.stopRunning()
      captureSession = nil
      continuation?.finish()
      continuation = nil
    }

    public nonisolated func metadataOutput(
      _ output: AVCaptureMetadataOutput,
      didOutput metadataObjects: [AVMetadataObject],
      from connection: AVCaptureConnection
    ) {
      guard let code = metadataObjects
        .compactMap({ $0 as? AVMetadataMachineReadableCodeObject })
        .first(where: { $0.type == .qr })?
        .stringValue,
        !code.isEmpty
      else { return }
      Task { @MainActor in
        self.continuation?.yield(.code(code))
        self.stop()
      }
    }
  }
#endif
