// OCR every frame of the given images (PNG, JPEG, GIF…) with Apple Vision and
// print the recognized text, one line per observation, prefixed by "file#frame: ".
// Used by scripts/pii-gate.sh --images. Usage: swift scripts/ocr.swift <image>...
import Foundation
import ImageIO
import Vision

var failed = false
for path in CommandLine.arguments.dropFirst() {
    let url = URL(fileURLWithPath: path)
    guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else {
        FileHandle.standardError.write("ocr: cannot read \(path)\n".data(using: .utf8)!)
        failed = true
        continue
    }
    for frame in 0..<CGImageSourceGetCount(source) {
        guard let image = CGImageSourceCreateImageAtIndex(source, frame, nil) else { continue }
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.usesLanguageCorrection = false
        do {
            try VNImageRequestHandler(cgImage: image).perform([request])
        } catch {
            FileHandle.standardError.write("ocr: \(path)#\(frame): \(error)\n".data(using: .utf8)!)
            failed = true
            continue
        }
        for observation in request.results ?? [] {
            if let text = observation.topCandidates(1).first?.string {
                print("\(path)#\(frame): \(text)")
            }
        }
    }
}
exit(failed ? 1 : 0)
