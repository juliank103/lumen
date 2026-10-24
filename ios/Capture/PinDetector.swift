import CoreML
import CoreGraphics
import CoreVideo
import Foundation

/// The pin model (Oct 24): a small network trained on the driver's own marked screenshots (tools/pin-model) that finds
/// every pin head on an offer map and says what it is — store, customer, or the driver's blue dot. It replaces the
/// pixel-rule pin finder in map-reader.js, which could not tell DoorDash/Grubhub stores from customers and counted its
/// way to an answer instead. Compiled into the reader at build time (PinDetector.mlmodelc); absent → nil, and the
/// reader falls back to the pixel rules.
final class PinDetector {
    static let shared = PinDetector()

    // Must match tools/pin-model/pins.py.
    private static let inputWidth = 320, inputHeight = 384, stride = 4
    private static let kinds = ["store", "customer", "you"]
    private static let pad: (r: CGFloat, g: CGFloat, b: CGFloat) = (40, 44, 56)
    private static let threshold: Float = 0.3

    private lazy var model: MLModel? = {
        let bundle = Bundle(for: PinDetector.self)
        guard let url = bundle.url(forResource: "PinDetector", withExtension: "mlmodelc", subdirectory: "Models")
                ?? bundle.url(forResource: "PinDetector", withExtension: "mlmodelc") else { return nil }
        let configuration = MLModelConfiguration()
        configuration.computeUnits = .cpuAndNeuralEngine
        return try? MLModel(contentsOf: url, configuration: configuration)
    }()

    var available: Bool { model != nil }

    struct Detection { let x: Double; let y: Double; let kind: String; let score: Double }

    /// map: the screen from `top` to `bottom` (fractions of the screen height), full width, as captured.
    /// Returns pins in screen-normalized coordinates (head centers), strongest first.
    func detect(map: CGImage, top: Double, bottom: Double) -> [Detection]? {
        guard let model, map.width > 10, map.height > 10 else { return nil }
        let W = Self.inputWidth, H = Self.inputHeight
        let scale = min(Double(W) / Double(map.width), Double(H) / Double(map.height))
        let w = max(1, Int((Double(map.width) * scale).rounded())), h = max(1, Int((Double(map.height) * scale).rounded()))
        var buffer: CVPixelBuffer?
        guard CVPixelBufferCreate(nil, W, H, kCVPixelFormatType_32BGRA, nil, &buffer) == kCVReturnSuccess, let buffer else { return nil }
        CVPixelBufferLockBaseAddress(buffer, [])
        let drawn: Bool = {
            guard let space = CGColorSpace(name: CGColorSpace.sRGB),
                  let context = CGContext(data: CVPixelBufferGetBaseAddress(buffer), width: W, height: H, bitsPerComponent: 8,
                                          bytesPerRow: CVPixelBufferGetBytesPerRow(buffer), space: space,
                                          bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue)
            else { return false }
            context.setFillColor(red: Self.pad.r / 255, green: Self.pad.g / 255, blue: Self.pad.b / 255, alpha: 1)
            context.fill(CGRect(x: 0, y: 0, width: W, height: H))
            context.interpolationQuality = .medium
            // Top-left aligned, padding right/bottom, as in training (CG's origin is the bottom-left).
            context.draw(map, in: CGRect(x: 0, y: H - h, width: w, height: h))
            return true
        }()
        CVPixelBufferUnlockBaseAddress(buffer, [])
        guard drawn,
              let input = try? MLDictionaryFeatureProvider(dictionary: ["map": MLFeatureValue(pixelBuffer: buffer)]),
              let output = try? model.prediction(from: input),
              let heatArray = output.featureValue(for: "heat")?.multiArrayValue,
              let offsetArray = output.featureValue(for: "offset")?.multiArrayValue else { return nil }
        let heat = MLShapedArray<Float>(converting: heatArray).scalars
        let offset = MLShapedArray<Float>(converting: offsetArray).scalars
        let ow = W / Self.stride, oh = H / Self.stride, plane = ow * oh
        guard heat.count >= Self.kinds.count * plane, offset.count >= 2 * plane else { return nil }
        var peaks: [(x: Double, y: Double, kind: Int, score: Float)] = []
        for k in 0..<Self.kinds.count {
            for y in 0..<oh {
                for x in 0..<ow {
                    let v = heat[k * plane + y * ow + x]
                    guard v >= Self.threshold else { continue }
                    var isPeak = true
                    for dy in -1...1 where isPeak {
                        for dx in -1...1 where !(dx == 0 && dy == 0) {
                            let nx = x + dx, ny = y + dy
                            if nx >= 0, ny >= 0, nx < ow, ny < oh, heat[k * plane + ny * ow + nx] > v { isPeak = false; break }
                        }
                    }
                    guard isPeak else { continue }
                    let px = (Double(x) + Double(offset[y * ow + x])) * Double(Self.stride)
                    let py = (Double(y) + Double(offset[plane + y * ow + x])) * Double(Self.stride)
                    guard px < Double(w), py < Double(h) else { continue }
                    peaks.append((px, py, k, v))
                }
            }
        }
        // One icon, one pin: a weaker peak of another kind on the same spot is dropped.
        peaks.sort { $0.score > $1.score }
        var kept: [(x: Double, y: Double, kind: Int, score: Float)] = []
        for p in peaks where !kept.contains(where: { abs($0.x - p.x) < 8 && abs($0.y - p.y) < 8 }) { kept.append(p) }
        let mapW = Double(map.width), mapH = Double(map.height)
        return kept.map { p in
            Detection(x: p.x / scale / mapW, y: top + (p.y / scale / mapH) * (bottom - top), kind: Self.kinds[p.kind], score: Double(p.score))
        }
    }

    static func json(_ detections: [Detection]) -> String {
        let list = detections.map { ["x": $0.x, "y": $0.y, "kind": $0.kind, "score": $0.score] as [String: Any] }
        return (try? JSONSerialization.data(withJSONObject: list)).flatMap { String(data: $0, encoding: .utf8) } ?? "[]"
    }

    /// Where the offer card's solid panel starts (fraction of screen height), from pixels: the first run of rows below
    /// 35% of the screen where the middle 80% of the width is one flat color. The card-text guess stopped short of it on
    /// 84 of 88 marked screenshots (town names and Uber's chips pull it up, and it was capped at 53%). Same rule as
    /// tools/pin-labeler/labeler.py card_top.
    static func cardTop(_ screen: CGImage) -> Double? {
        let W = 400, H = Int((400 * Double(screen.height) / Double(screen.width)).rounded())
        guard H > 100, let space = CGColorSpace(name: CGColorSpace.sRGB) else { return nil }
        var pixels = [UInt8](repeating: 0, count: W * H * 4)
        let drawn = pixels.withUnsafeMutableBytes { raw -> Bool in
            guard let context = CGContext(data: raw.baseAddress, width: W, height: H, bitsPerComponent: 8, bytesPerRow: W * 4,
                                          space: space, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { return false }
            context.draw(screen, in: CGRect(x: 0, y: 0, width: W, height: H))
            return true
        }
        guard drawn else { return nil }
        let x0 = 40, x1 = 360, n = x1 - x0
        func median(_ values: inout [Int]) -> Int { values.sort(); return values[values.count / 2] }
        var flat = [Bool](repeating: false, count: H), mean = [[Double]](repeating: [0, 0, 0], count: H)
        let from = Int(Double(H) * 0.35), to = min(H, Int(Double(H) * 0.85))
        var channel = [Int](repeating: 0, count: n)
        for y in from..<to {
            var med = [0, 0, 0]
            for c in 0..<3 {
                for i in 0..<n { channel[i] = Int(pixels[(y * W + x0 + i) * 4 + c]) }
                var copy = channel
                med[c] = median(&copy)
                mean[y][c] = Double(channel.reduce(0, +)) / Double(n)
            }
            var close = 0
            for i in 0..<n {
                let o = (y * W + x0 + i) * 4
                if abs(Int(pixels[o]) - med[0]) <= 10 && abs(Int(pixels[o + 1]) - med[1]) <= 10 && abs(Int(pixels[o + 2]) - med[2]) <= 10 { close += 1 }
            }
            flat[y] = Double(close) / Double(n) >= 0.97
        }
        let run = 3
        for y in from..<(to - run) where (y..<(y + run)).allSatisfy({ flat[$0] }) {
            let same = (y..<(y + run)).allSatisfy { r in (0..<3).allSatisfy { abs(mean[r][$0] - mean[y][$0]) <= 6 } }
            if same { return Double(y) / Double(H) }
        }
        return nil
    }
}
