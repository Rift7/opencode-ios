import ComposableArchitecture
import OpenCodeCore
import OpenCodeMedia
import OpenCodeServer
import SwiftUI

/// Draws over an image and returns a flattened JPEG. The source image is never modified; cancel
/// leaves the originating draft untouched.
struct AnnotationEditor: View {
  let source: MediaImageSource
  let server: OpenCodeServer?
  let imageLoaded: MediaLoadedImage?
  let initialStrokes: [AnnotationStroke]
  let onChanged: ([AnnotationStroke]) -> Void
  let onSave: (Data) -> Void
  let onCancel: () -> Void

  @Dependency(\.mediaImages) private var images
  @State private var image: MediaLoadedImage?
  @State private var strokes: [AnnotationStroke] = []
  @State private var current: AnnotationStroke?
  @State private var ink: AnnotationInk = .red
  @State private var confirmingDiscard = false
  @State private var saving = false
  @State private var problem: String?

  var body: some View {
    NavigationStack {
      ZStack {
        Color.black.ignoresSafeArea()
        if let image {
          GeometryReader { proxy in
            let size = fittedSize(image: image, in: proxy.size)
            ZStack {
              Image(decorative: image.image, scale: 1)
                .resizable()
                .frame(width: size.width, height: size.height)
              Canvas { context, canvasSize in
                for stroke in strokes + (current.map { [$0] } ?? []) {
                  draw(stroke, in: context, size: canvasSize)
                }
              }
              .frame(width: size.width, height: size.height)
              .contentShape(Rectangle())
              .accessibilityIdentifier("annotation-canvas")
              .gesture(drawGesture(size: size))
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
          }
          .padding(.horizontal, OpenCodeSpacing.s8)
        } else {
          ProgressView().tint(.white)
        }
        if let problem {
          Text(problem)
            .font(OpenCodeFonts.font(.footnote))
            .foregroundStyle(OpenCodeColors.color(.danger))
            .padding()
            .background(.black.opacity(0.7), in: .rect(cornerRadius: OpenCodeRadius.control))
        }
      }
      .navigationTitle(AppCopy.text("media.annotation_title"))
      .navigationBarTitleDisplayMode(.inline)
      .toolbarBackground(.black, for: .navigationBar)
      .toolbarColorScheme(.dark, for: .navigationBar)
      .toolbar {
        ToolbarItem(placement: .cancellationAction) {
          Button(AppCopy.text("common.cancel")) {
            if strokes.isEmpty {
              onCancel()
            } else {
              confirmingDiscard = true
            }
          }
        }
        ToolbarItem(placement: .confirmationAction) {
          Button {
            save()
          } label: {
            if saving {
              ProgressView().controlSize(.small)
            } else {
              Text(AppCopy.text("media.annotation_add")).fontWeight(.semibold)
            }
          }
          .disabled(strokes.isEmpty || saving || image == nil)
          .accessibilityIdentifier("annotation-add")
        }
        ToolbarItemGroup(placement: .bottomBar) {
          ForEach(AnnotationInk.allCases, id: \.self) { candidate in
            Button {
              ink = candidate
            } label: {
              Circle()
                .fill(
                  Color(
                    red: candidate.components.red,
                    green: candidate.components.green,
                    blue: candidate.components.blue
                  )
                )
                .frame(width: 22, height: 22)
                .overlay {
                  Circle()
                    .strokeBorder(.white, lineWidth: ink == candidate ? 2 : 0)
                }
            }
            .accessibilityLabel(candidate.rawValue.capitalized)
            .accessibilityAddTraits(ink == candidate ? [.isSelected] : [])
          }
          Spacer()
          Button {
            guard !strokes.isEmpty else { return }
            strokes.removeLast()
            onChanged(strokes)
          } label: {
            Image(systemName: "arrow.uturn.backward")
          }
          .disabled(strokes.isEmpty)
          .accessibilityLabel(AppCopy.text("media.annotation_undo"))
        }
      }
      .confirmationDialog(
        AppCopy.text("media.annotation_discard_title"),
        isPresented: $confirmingDiscard,
        titleVisibility: .visible
      ) {
        Button(AppCopy.text("media.annotation_discard"), role: .destructive) { onCancel() }
        Button(AppCopy.text("media.annotation_keep"), role: .cancel) {}
      }
    }
    .task {
      if let imageLoaded {
        image = imageLoaded
      } else {
        image = await images.load(source, server, 2_560)
      }
      if strokes.isEmpty { strokes = initialStrokes }
      if image == nil { problem = AppCopy.text("media.viewer_unavailable") }
    }
  }

  private func fittedSize(image: MediaLoadedImage, in bounds: CGSize) -> CGSize {
    guard bounds.width > 0, bounds.height > 0 else { return CGSize(width: 1, height: 1) }
    let ratio = image.aspectRatio
    let width = min(bounds.width, bounds.height * ratio)
    return CGSize(width: width, height: width / ratio)
  }

  private func draw(_ stroke: AnnotationStroke, in context: GraphicsContext, size: CGSize) {
    guard let first = stroke.points.first else { return }
    var path = Path()
    path.move(to: CGPoint(x: first.x * size.width, y: first.y * size.height))
    for point in stroke.points.dropFirst() {
      path.addLine(to: CGPoint(x: point.x * size.width, y: point.y * size.height))
    }
    let components = stroke.ink.components
    context.stroke(
      path,
      with: .color(
        Color(red: components.red, green: components.green, blue: components.blue)
      ),
      style: StrokeStyle(
        lineWidth: max(2, stroke.width * Double(max(size.width, size.height))),
        lineCap: .round,
        lineJoin: .round
      )
    )
  }

  private func drawGesture(size: CGSize) -> some Gesture {
    DragGesture(minimumDistance: 0)
      .onChanged { value in
        let point = AnnotationPoint(
          x: min(1, max(0, value.location.x / max(1, size.width))),
          y: min(1, max(0, value.location.y / max(1, size.height)))
        )
        if current == nil {
          current = AnnotationStroke(points: [point], ink: ink)
        } else {
          current?.points.append(point)
        }
      }
      .onEnded { _ in
        guard let finished = current, finished.points.count > 0 else { return }
        strokes.append(finished)
        current = nil
        onChanged(strokes)
      }
  }

  private func save() {
    guard let image, !saving else { return }
    saving = true
    problem = nil
    let strokes = strokes
    let base = image.image
    Task {
      let data = await Task.detached(priority: .userInitiated) {
        AnnotationRenderer.jpeg(base: base, strokes: strokes)
      }.value
      saving = false
      if let data {
        onSave(data)
      } else {
        problem = AppCopy.text("media.annotation_failed")
      }
    }
  }
}
