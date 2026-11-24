import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

public struct AnnotationPoint: Codable, Equatable, Sendable {
  /// 0…1 across the image's width and height; independent of the view's zoom.
  public var x: Double
  public var y: Double

  public init(x: Double, y: Double) {
    self.x = x
    self.y = y
  }
}

public enum AnnotationInk: String, Codable, CaseIterable, Equatable, Sendable {
  case red
  case orange
  case yellow
  case green
  case blue
  case black

  /// RGB components, red first as in the audited editor.
  public var components: (red: Double, green: Double, blue: Double) {
    switch self {
    case .red: (0.90, 0.22, 0.20)
    case .orange: (0.96, 0.55, 0.14)
    case .yellow: (0.96, 0.78, 0.16)
    case .green: (0.24, 0.70, 0.38)
    case .blue: (0.20, 0.48, 0.90)
    case .black: (0.10, 0.10, 0.10)
    }
  }
}

public struct AnnotationStroke: Codable, Equatable, Sendable {
  public var points: [AnnotationPoint]
  public var ink: AnnotationInk
  /// Fraction of the image's long edge, so a stroke keeps its visual weight at any size.
  public var width: Double

  public init(points: [AnnotationPoint] = [], ink: AnnotationInk = .red, width: Double = 0.012) {
    self.points = points
    self.ink = ink
    self.width = width
  }
}

/// Flattens strokes into a JPEG at the import bounds. The original image is never modified.
public enum AnnotationRenderer {
  public static func jpeg(
    base: CGImage,
    strokes: [AnnotationStroke],
    maximumPixelSize: Int = MediaLimits.maximumImageLongEdge
  ) -> Data? {
    let width = base.width
    let height = base.height
    guard width > 0, height > 0 else { return nil }
    let scale = min(1, Double(maximumPixelSize) / Double(max(width, height)))
    let outputWidth = max(1, Int((Double(width) * scale).rounded()))
    let outputHeight = max(1, Int((Double(height) * scale).rounded()))
    let colorSpace = CGColorSpaceCreateDeviceRGB()
    guard let context = CGContext(
      data: nil,
      width: outputWidth,
      height: outputHeight,
      bitsPerComponent: 8,
      bytesPerRow: 0,
      space: colorSpace,
      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
    ) else { return nil }
    context.interpolationQuality = .high
    context.draw(base, in: CGRect(x: 0, y: 0, width: outputWidth, height: outputHeight))
    let longEdge = Double(max(outputWidth, outputHeight))
    for stroke in strokes where stroke.points.count > 0 {
      let components = stroke.ink.components
      context.setStrokeColor(
        red: components.red,
        green: components.green,
        blue: components.blue,
        alpha: 1
      )
      context.setLineWidth(max(1, stroke.width * longEdge))
      context.setLineCap(.round)
      context.setLineJoin(.round)
      let points = stroke.points.map {
        CGPoint(
          x: $0.x * Double(outputWidth),
          y: (1 - $0.y) * Double(outputHeight)
        )
      }
      context.beginPath()
      if points.count == 1 {
        context.move(to: points[0])
        context.addLine(to: points[0])
      } else {
        context.move(to: points[0])
        for point in points.dropFirst() {
          context.addLine(to: point)
        }
      }
      context.strokePath()
    }
    guard let image = context.makeImage() else { return nil }
    let data = NSMutableData()
    guard let destination = CGImageDestinationCreateWithData(
      data,
      UTType.jpeg.identifier as CFString,
      1,
      nil
    ) else { return nil }
    CGImageDestinationAddImage(
      destination,
      image,
      [kCGImageDestinationLossyCompressionQuality: MediaLimits.imageQuality] as CFDictionary
    )
    guard CGImageDestinationFinalize(destination) else { return nil }
    return data as Data
  }
}
