import AVFoundation
import OpenCodeCore
import SwiftUI
import UIKit

/// The camera, reached only from the composer's + menu. The system capture UI is the bridge; this
/// sheet owns permission, availability and the JPEG it hands back.
struct CameraCaptureSheet: View {
  let onCapture: (Data) -> Void
  let onCancel: () -> Void

  @State private var phase: Phase = .checking
  @State private var pickerShown = false

  enum Phase: Equatable {
    case checking
    case ready
    case denied
    case unavailable
  }

  var body: some View {
    NavigationStack {
      Group {
        switch phase {
        case .checking:
          ProgressView()
        case .ready:
          Color.black
            .onAppear { pickerShown = true }
        case .denied:
          unavailable(
            title: AppCopy.text("composer.camera_denied"),
            showsSettings: true
          )
        case .unavailable:
          unavailable(
            title: AppCopy.text("composer.camera_unavailable"),
            showsSettings: false
          )
        }
      }
      .frame(maxWidth: .infinity, maxHeight: .infinity)
      .background(Color.black)
      .navigationTitle(AppCopy.text("composer.camera"))
      .navigationBarTitleDisplayMode(.inline)
      .toolbar {
        ToolbarItem(placement: .cancellationAction) {
          Button(AppCopy.text("common.cancel"), action: onCancel)
        }
      }
    }
    .preferredColorScheme(.dark)
    .task { await prepare() }
    .fullScreenCover(isPresented: $pickerShown) {
      ImagePickerController(
        onImage: { image in
          pickerShown = false
          guard let data = image.jpegData(compressionQuality: 0.9) else {
            onCancel()
            return
          }
          onCapture(data)
        },
        onCancel: {
          pickerShown = false
          onCancel()
        }
      )
      .ignoresSafeArea()
    }
  }

  private func prepare() async {
    guard UIImagePickerController.isSourceTypeAvailable(.camera) else {
      phase = .unavailable
      return
    }
    switch AVCaptureDevice.authorizationStatus(for: .video) {
    case .authorized:
      phase = .ready
    case .notDetermined:
      let granted = await AVCaptureDevice.requestAccess(for: .video)
      phase = granted ? .ready : .denied
    case .denied, .restricted:
      phase = .denied
    @unknown default:
      phase = .unavailable
    }
  }

  private func unavailable(title: String, showsSettings: Bool) -> some View {
    VStack(spacing: OpenCodeSpacing.s16) {
      Image(systemName: "camera.fill")
        .font(.largeTitle)
        .foregroundStyle(.white.opacity(0.7))
      Text(title)
        .font(OpenCodeFonts.font(.body))
        .foregroundStyle(.white)
        .multilineTextAlignment(.center)
      if showsSettings, let url = URL(string: UIApplication.openSettingsURLString) {
        Button(AppCopy.text("composer.camera_settings")) {
          UIApplication.shared.open(url)
        }
        .buttonStyle(.borderedProminent)
      }
    }
    .padding()
  }
}

private struct ImagePickerController: UIViewControllerRepresentable {
  let onImage: (UIImage) -> Void
  let onCancel: () -> Void

  func makeUIViewController(context: Context) -> UIImagePickerController {
    let picker = UIImagePickerController()
    picker.sourceType = .camera
    picker.cameraCaptureMode = .photo
    picker.delegate = context.coordinator
    return picker
  }

  func updateUIViewController(_ controller: UIImagePickerController, context: Context) {}

  func makeCoordinator() -> Coordinator {
    Coordinator(onImage: onImage, onCancel: onCancel)
  }

  final class Coordinator: NSObject, UIImagePickerControllerDelegate, UINavigationControllerDelegate {
    let onImage: (UIImage) -> Void
    let onCancel: () -> Void

    init(onImage: @escaping (UIImage) -> Void, onCancel: @escaping () -> Void) {
      self.onImage = onImage
      self.onCancel = onCancel
    }

    func imagePickerController(
      _ picker: UIImagePickerController,
      didFinishPickingMediaWithInfo info: [UIImagePickerController.InfoKey: Any]
    ) {
      if let image = info[.originalImage] as? UIImage {
        onImage(image)
      } else {
        onCancel()
      }
    }

    func imagePickerControllerDidCancel(_ picker: UIImagePickerController) {
      onCancel()
    }
  }
}
