import CoreGraphics
import Foundation
import ImageIO

/**
 * "Background from artwork"'s wash, made by the app for the page at
 * `aiostv://localhost/wash?u=<address>` (patches/web/0043): the title's art read
 * small, blurred and toned, drawn out to 320x180 and dithered, as a PNG, with
 * its edge colour and panel shade in the response's `X-Wash-Tint` and
 * `X-Wash-Panel`. The page's artwork workers, which make it off the page's
 * thread elsewhere, don't start for the app's scheme on this WebKit, so the
 * page made each one on its own thread as a background changed.
 *
 * The same steps as upstream's packages/web/src/lib/artwork/wash.ts
 * (`makeWash`, `drawWash`) and background.ts (`washHere`), constant for
 * constant, its noise from the same seed, so the wash looks the same.
 */
enum ArtWash {
    static let path = "/wash"

    private static let gridW = 96
    private static let gridH = 54
    private static let washW = 320
    private static let washH = 180
    /// Three box passes of this radius approximate a Gaussian.
    private static let boxRadius = 8
    /// The mean brightness a wash is brought to, in linear light.
    private static let mean = 0.045
    private static let minGain = 0.08
    private static let maxGain = 1.2
    /// Brightness the highlights roll off towards, so no patch glares.
    private static let white = 0.2
    private static let saturation = 1.5
    private static let panelLightness = 0.1
    private static let panelSaturation = 0.32
    private static let lut = 4096
    private static let noiseSize = 64

    struct Made {
        let png: Data
        let tint: String
        let panel: String
    }

    private static let lock = NSLock()
    /// Each title's, so showing one again sends it at once.
    private static var kept: [String: Made] = [:]
    private static var order: [String] = []
    private static let keptMax = 40
    private static let queue = DispatchQueue(label: "io.github.aiostreams.art-wash", qos: .userInitiated)

    /// The wash of the art at `source`, as `done(made)`, or `done(nil)`.
    static func make(_ source: URL, done: @escaping (Made?) -> Void) {
        guard ["http", "https"].contains(source.scheme?.lowercased() ?? "") else { return done(nil) }
        let key = source.absoluteString
        lock.lock()
        let hit = kept[key]
        lock.unlock()
        if let hit { return done(hit) }
        ImageFit.session.dataTask(with: source) { data, response, error in
            let status = (response as? HTTPURLResponse)?.statusCode ?? 200
            guard error == nil, let data, (200..<300).contains(status) else { return done(nil) }
            queue.async {
                guard let pixels = grid(data), let made = wash(pixels) else { return done(nil) }
                lock.lock()
                if kept.updateValue(made, forKey: key) == nil { order.append(key) }
                while order.count > keptMax { kept.removeValue(forKey: order.removeFirst()) }
                lock.unlock()
                done(made)
            }
        }.resume()
    }

    // MARK: Reading the art (background.ts washHere)

    /// The art covering a 96x54 grid, cropped to the middle as `object-fit: cover` does: RGBA, top row first.
    private static func grid(_ data: Data) -> [UInt8]? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
        // The page asks for the art at most 300 wide; no more is needed for 96.
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: 400,
        ]
        guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else { return nil }
        let w = Double(image.width)
        let h = Double(image.height)
        guard w > 0, h > 0 else { return nil }
        var pixels = [UInt8](repeating: 0, count: gridW * gridH * 4)
        let drawn = pixels.withUnsafeMutableBytes { buffer -> Bool in
            guard let space = CGColorSpace(name: CGColorSpace.sRGB),
                  let context = CGContext(data: buffer.baseAddress, width: gridW, height: gridH, bitsPerComponent: 8,
                                          bytesPerRow: gridW * 4, space: space,
                                          bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
            else { return false }
            context.interpolationQuality = .high
            let scale = max(Double(gridW) / w, Double(gridH) / h)
            let width = w * scale
            let height = h * scale
            // The middle of the art, its overflow cropped evenly from both sides.
            context.draw(image, in: CGRect(x: (Double(gridW) - width) / 2, y: (Double(gridH) - height) / 2,
                                           width: width, height: height))
            return true
        }
        return drawn ? pixels : nil
    }

    // MARK: The wash (wash.ts makeWash)

    private static let toLinear: [Float] = (0..<256).map { i in
        let c = Double(i) / 255
        return Float(c <= 0.04045 ? c / 12.92 : pow((c + 0.055) / 1.055, 2.4))
    }

    private static let toSrgb: [Float] = (0...lut).map { i in
        let c = Double(i) / Double(lut)
        return Float(255 * (c <= 0.0031308 ? c * 12.92 : 1.055 * pow(c, 1 / 2.4) - 0.055))
    }

    /// One box pass along rows (`step` 1) or columns (`step` gridW), edges held.
    private static func boxPass(_ src: [Float], _ dst: inout [Float], lines: Int, length: Int, lineStep: Int, step: Int) {
        let r = boxRadius
        let scale = 1 / Double(2 * r + 1)
        for line in 0..<lines {
            let base = line * lineStep
            let last = base + (length - 1) * step
            var sum = Double(src[base]) * Double(r + 1)
            for i in 1...r { sum += Double(src[base + min(i, length - 1) * step]) }
            for i in 0..<length {
                dst[base + i * step] = Float(sum * scale)
                let add = i + r + 1
                let drop = i - r
                sum += Double(src[add < length ? base + add * step : last]) - Double(src[drop > 0 ? base + drop * step : base])
            }
        }
    }

    private static func blur(_ channel: inout [Float]) {
        var scratch = [Float](repeating: 0, count: channel.count)
        for _ in 0..<3 {
            boxPass(channel, &scratch, lines: gridH, length: gridW, lineStep: gridW, step: 1)
            boxPass(scratch, &channel, lines: gridW, length: gridH, lineStep: 1, step: gridW)
        }
    }

    private static func smoothstep(_ a: Double, _ b: Double, _ x: Double) -> Double {
        let t = min(1, max(0, (x - a) / (b - a)))
        return t * t * (3 - 2 * t)
    }

    /// JavaScript's `Math.round`: halves go up.
    private static func jsRound(_ v: Double) -> Double { (v + 0.5).rounded(.down) }

    private static func hex(_ rgb: [Double]) -> String {
        "#" + rgb.map { String(format: "%02x", Int(jsRound($0))) }.joined()
    }

    /// `rgb` (0-255) with its lightness set and saturation capped, as HSL does it.
    private static func shade(_ rgb: [Double], lightness: Double, saturation: Double) -> String {
        let r = rgb[0] / 255
        let g = rgb[1] / 255
        let b = rgb[2] / 255
        let high = max(r, g, b)
        let low = min(r, g, b)
        let d = high - low
        let l = (high + low) / 2
        let s = d != 0 ? min(saturation, d / (1 - abs(2 * l - 1))) : 0
        let h: Double
        if d == 0 {
            h = 0
        } else if high == r {
            h = ((g - b) / d + 6).truncatingRemainder(dividingBy: 6)
        } else if high == g {
            h = (b - r) / d + 2
        } else {
            h = (r - g) / d + 4
        }
        let a = s * min(lightness, 1 - lightness)
        func f(_ n: Double) -> Double {
            let k = (n + h * 2).truncatingRemainder(dividingBy: 12)
            return 255 * (lightness - a * max(-1, min(k - 3, 9 - k, 1)))
        }
        return hex([f(0), f(8), f(4)])
    }

    private struct Toned {
        var rgb: [Float]
        var tint: String
        var panel: String
    }

    private static func tone(_ rgba: [UInt8]) -> Toned {
        let n = gridW * gridH
        var r = [Float](repeating: 0, count: n)
        var g = [Float](repeating: 0, count: n)
        var b = [Float](repeating: 0, count: n)
        for i in 0..<n {
            r[i] = toLinear[Int(rgba[i * 4])]
            g[i] = toLinear[Int(rgba[i * 4 + 1])]
            b[i] = toLinear[Int(rgba[i * 4 + 2])]
        }
        blur(&r)
        blur(&g)
        blur(&b)

        var mean = 0.0
        for i in 0..<n { mean += 0.2126 * Double(r[i]) + 0.7152 * Double(g[i]) + 0.0722 * Double(b[i]) }
        mean /= Double(n)
        let gain = min(maxGain, max(minGain, Self.mean / (mean != 0 ? mean : 1e-4)))

        var rgb = [Float](repeating: 0, count: n * 3)
        var edge = [0.0, 0.0, 0.0]
        var whole = [0.0, 0.0, 0.0]
        let edgeFrom = gridH - 4
        for y in 0..<gridH {
            let v = Double(y) / Double(gridH - 1)
            // Darker towards the bottom, where rows and text sit, and a little at the sides.
            let fall = 1 - 0.3 * smoothstep(0.3, 1, v)
            for x in 0..<gridW {
                let i = y * gridW + x
                let u = Double(2 * x) / Double(gridW - 1) - 1
                let shade = fall * (1 - 0.12 * u * u)
                var cr = Double(r[i]) * gain
                var cg = Double(g[i]) * gain
                var cb = Double(b[i]) * gain
                let lum = 0.2126 * cr + 0.7152 * cg + 0.0722 * cb
                cr = max(0, lum + (cr - lum) * saturation)
                cg = max(0, lum + (cg - lum) * saturation)
                cb = max(0, lum + (cb - lum) * saturation)
                let toned = 1 / (1 + lum / white)
                whole[0] += cr * toned
                whole[1] += cg * toned
                whole[2] += cb * toned
                if y >= edgeFrom {
                    edge[0] += cr * toned
                    edge[1] += cg * toned
                    edge[2] += cb * toned
                }
                rgb[i * 3] = Float(cr * toned * shade)
                rgb[i * 3 + 1] = Float(cg * toned * shade)
                rgb[i * 3 + 2] = Float(cb * toned * shade)
            }
        }

        // Before the vignette, which would leave it all but black.
        func srgb(_ sum: [Double], _ cells: Int) -> [Double] {
            sum.map { Double(toSrgb[min(lut, Int(($0 / Double(cells)) * Double(lut)))]) }
        }
        let tint = hex(srgb(edge, (gridH - edgeFrom) * gridW))
        let panel = shade(srgb(whole, n), lightness: panelLightness, saturation: panelSaturation)
        return Toned(rgb: rgb, tint: tint, panel: panel)
    }

    // MARK: Drawing it out (wash.ts drawWash)

    /// Triangular noise of +-1 step, tiled, from the page's seed.
    private static let noise: [Float] = {
        var seed = Int32(bitPattern: 0x9e37_79b9)
        func rand() -> Double {
            seed ^= seed &<< 13
            seed ^= Int32(bitPattern: UInt32(bitPattern: seed) >> 17)
            seed ^= seed &<< 5
            return Double(UInt32(bitPattern: seed)) / 4_294_967_296
        }
        return (0..<(noiseSize * noiseSize * 3)).map { _ in Float(rand() - rand()) }
    }()

    /// A `Uint8ClampedArray` store: clamped, halves to even.
    private static func clamped(_ v: Double) -> UInt8 {
        guard v.isFinite else { return 0 }
        return UInt8(min(255, max(0, v)).rounded(.toNearestOrEven))
    }

    private static func wash(_ grid: [UInt8]) -> Made? {
        let toned = tone(grid)
        let rgb = toned.rgb
        var col0 = [Int](repeating: 0, count: washW)
        var col1 = [Int](repeating: 0, count: washW)
        var colWeight = [Double](repeating: 0, count: washW)
        for x in 0..<washW {
            let g = min(Double(gridW - 1), max(0, (Double(x) + 0.5) * Double(gridW) / Double(washW) - 0.5))
            let whole = Int(g)
            col0[x] = whole * 3
            col1[x] = min(gridW - 1, whole + 1) * 3
            colWeight[x] = Double(Float(g - Double(whole)))
        }
        var out = [UInt8](repeating: 0, count: washW * washH * 4)
        for y in 0..<washH {
            let g = min(Double(gridH - 1), max(0, (Double(y) + 0.5) * Double(gridH) / Double(washH) - 0.5))
            let y0 = Int(g)
            let fy = g - Double(y0)
            let row0 = y0 * gridW * 3
            let row1 = min(gridH - 1, y0 + 1) * gridW * 3
            let noiseRow = (y & (noiseSize - 1)) * noiseSize
            var o = y * washW * 4
            for x in 0..<washW {
                let a0 = row0 + col0[x]
                let a1 = row0 + col1[x]
                let b0 = row1 + col0[x]
                let b1 = row1 + col1[x]
                let fx = colWeight[x]
                let n = (noiseRow + (x & (noiseSize - 1))) * 3
                for ch in 0..<3 {
                    let top = Double(rgb[a0 + ch]) + (Double(rgb[a1 + ch]) - Double(rgb[a0 + ch])) * fx
                    let bottom = Double(rgb[b0 + ch]) + (Double(rgb[b1 + ch]) - Double(rgb[b0 + ch])) * fx
                    let lin = min(1, top + (bottom - top) * fy)
                    out[o + ch] = clamped(Double(toSrgb[Int(lin * Double(lut))]) + Double(noise[n + ch]))
                }
                out[o + 3] = 255
                o += 4
            }
        }
        guard let png = png(out) else { return nil }
        return Made(png: png, tint: toned.tint, panel: toned.panel)
    }

    private static func png(_ rgba: [UInt8]) -> Data? {
        guard let space = CGColorSpace(name: CGColorSpace.sRGB),
              let provider = CGDataProvider(data: Data(rgba) as CFData),
              let image = CGImage(width: washW, height: washH, bitsPerComponent: 8, bitsPerPixel: 32,
                                  bytesPerRow: washW * 4, space: space,
                                  bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipLast.rawValue),
                                  provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent)
        else { return nil }
        let out = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(out as CFMutableData, "public.png" as CFString, 1, nil)
        else { return nil }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else { return nil }
        return out as Data
    }
}
