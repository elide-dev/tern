// Prints the message of every QR code CoreImage finds in the image given as the argument.
import CoreImage
import Foundation

guard CommandLine.arguments.count == 2, let image = CIImage(contentsOf: URL(fileURLWithPath: CommandLine.arguments[1])) else {
  FileHandle.standardError.write("usage: swift decode-qr.swift IMAGE\n".data(using: .utf8)!)
  exit(2)
}
let detector = CIDetector(ofType: CIDetectorTypeQRCode, context: nil, options: [CIDetectorAccuracy: CIDetectorAccuracyHigh])
for case let feature as CIQRCodeFeature in detector?.features(in: image) ?? [] {
  if let message = feature.messageString { print(message) }
}
