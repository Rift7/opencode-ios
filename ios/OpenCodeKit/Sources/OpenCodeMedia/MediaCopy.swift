import Foundation

/// English copy for media errors and labels. Views resolve their own localized keys where a screen
/// owns the sentence; this table covers the typed values reducers and package models produce.
public enum MediaCopy {
  public enum Text {
    case file
    case image
    case pastedText
    case uploading
    case uploadFailed
    case retry
    case remove
    case unavailable
    case loading
    case couldNotOpen
    case unsupported
    case tooLarge
    case cameraUnavailable
    case cameraDenied
    case uploadsUnsupported
    case couldNotSaveDrawing
  }

  public static func text(_ value: Text) -> String {
    switch value {
    case .file: "File"
    case .image: "Image"
    case .pastedText: "Pasted Text"
    case .uploading: "Uploading"
    case .uploadFailed: "Couldn’t upload"
    case .retry: "Try Again"
    case .remove: "Remove"
    case .unavailable: "Unavailable"
    case .loading: "Loading"
    case .couldNotOpen: "Couldn’t open this file"
    case .unsupported: "This file can’t be shown here"
    case .tooLarge: "This file is too large"
    case .cameraUnavailable: "The camera isn’t available"
    case .cameraDenied: "Camera access is off"
    case .uploadsUnsupported: "This server doesn’t accept file uploads"
    case .couldNotSaveDrawing: "Couldn’t add the drawing"
    }
  }

  public static func problem(_ problem: MediaAttachmentProblem) -> String {
    switch problem {
    case .tooLarge: text(.tooLarge)
    case .unreadable: "This file couldn’t be read"
    case .unsupported: text(.unsupported)
    case .couldNotWrite: "This file couldn’t be copied"
    case .couldNotRead: text(.couldNotOpen)
    case .cameraUnavailable: text(.cameraUnavailable)
    case .cameraDenied: text(.cameraDenied)
    case .uploadUnsupported: text(.uploadsUnsupported)
    case .uploadFailed: "The upload ended early"
    case .uploadInterrupted: "The upload was interrupted"
    case .notFound: "This file is no longer on the server"
    case .denied: "Access to this file was denied"
    }
  }
}
