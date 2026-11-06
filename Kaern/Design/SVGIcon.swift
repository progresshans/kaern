import CoreGraphics
import SwiftUI

/// A small icon drawn from the same SVG markup the canvas boards use, so toolbar, tab and
/// sidebar glyphs match the design stroke for stroke. Supports the subset the boards use:
/// paths (M L H V C A Z, absolute and relative), circles and rounded rects, each filled
/// and/or stroked with the current foreground color or white.
nonisolated struct SVGIcon: Sendable {
    enum Paint: Sendable { case none, current, white }

    struct Part: Sendable {
        var path: Path
        var fill: Paint = .none
        var stroke: Paint = .current
        var width: CGFloat = 1.4
        var cap: CGLineCap = .butt
        var join: CGLineJoin = .miter
    }

    /// The viewBox size (drawn aspect-fit and centered, like SVG's default `xMidYMid meet`).
    var box: CGSize
    var parts: [Part]

    init(_ side: CGFloat, _ parts: [Part]) {
        self.box = CGSize(width: side, height: side)
        self.parts = parts
    }

    init(width: CGFloat, height: CGFloat, _ parts: [Part]) {
        self.box = CGSize(width: width, height: height)
        self.parts = parts
    }
}

nonisolated extension SVGIcon.Part {
    /// `<path d="…">` stroked with the current color.
    static func path(_ d: String, width: CGFloat, cap: CGLineCap = .butt, join: CGLineJoin = .miter,
                     fill: SVGIcon.Paint = .none, stroke: SVGIcon.Paint = .current) -> Self {
        Self(path: Path(SVGPathParser.parse(d)), fill: fill, stroke: stroke, width: width, cap: cap, join: join)
    }

    /// `<path d="…" fill="currentColor">` without a stroke.
    static func filled(_ d: String, paint: SVGIcon.Paint = .current) -> Self {
        Self(path: Path(SVGPathParser.parse(d)), fill: paint, stroke: .none, width: 0)
    }

    static func circle(_ cx: CGFloat, _ cy: CGFloat, _ r: CGFloat, width: CGFloat = 0,
                       fill: SVGIcon.Paint = .none, stroke: SVGIcon.Paint = .current) -> Self {
        let path = Path(ellipseIn: CGRect(x: cx - r, y: cy - r, width: r * 2, height: r * 2))
        return Self(path: path, fill: fill, stroke: width > 0 ? stroke : .none, width: width)
    }

    static func rect(_ x: CGFloat, _ y: CGFloat, _ w: CGFloat, _ h: CGFloat, rx: CGFloat, width: CGFloat) -> Self {
        let path = Path(roundedRect: CGRect(x: x, y: y, width: w, height: h), cornerRadius: rx)
        return Self(path: path, fill: .none, stroke: .current, width: width)
    }
}

/// Draws an ``SVGIcon`` at `size` points in the current foreground style.
struct Icon: View {
    let icon: SVGIcon
    var size: CGFloat
    var height: CGFloat?

    init(_ icon: SVGIcon, size: CGFloat, height: CGFloat? = nil) {
        self.icon = icon
        self.size = size
        self.height = height
    }

    var body: some View {
        Canvas { context, canvasSize in
            let scale = min(canvasSize.width / icon.box.width, canvasSize.height / icon.box.height)
            let dx = (canvasSize.width - icon.box.width * scale) / 2
            let dy = (canvasSize.height - icon.box.height * scale) / 2
            let transform = CGAffineTransform(translationX: dx, y: dy).scaledBy(x: scale, y: scale)
            for part in icon.parts {
                let path = part.path.applying(transform)
                if part.fill != .none {
                    context.fill(path, with: Self.shading(part.fill))
                }
                if part.stroke != .none, part.width > 0 {
                    context.stroke(path, with: Self.shading(part.stroke), style: StrokeStyle(
                        lineWidth: part.width * scale, lineCap: part.cap, lineJoin: part.join
                    ))
                }
            }
        }
        .frame(width: size, height: height ?? size)
        .accessibilityHidden(true)
    }

    nonisolated private static func shading(_ paint: SVGIcon.Paint) -> GraphicsContext.Shading {
        paint == .white ? .color(.white) : .foreground
    }
}

/// Parses SVG path data into a `CGPath` (y down, like SVG and SwiftUI).
nonisolated enum SVGPathParser {
    static func parse(_ d: String) -> CGPath {
        var scanner = Tokens(d)
        let path = CGMutablePath()
        var current = CGPoint.zero
        var start = CGPoint.zero
        var command: Character = "M"

        while let next = scanner.nextCommandOrNumber() {
            if case .command(let c) = next {
                command = c
                if c == "Z" || c == "z" {
                    path.closeSubpath()
                    current = start
                    continue
                }
            } else {
                scanner.pushBack()
            }
            let relative = command.isLowercase
            let base = relative ? current : .zero
            switch command {
            case "M", "m":
                let p = scanner.point(base)
                path.move(to: p)
                current = p
                start = p
                // Further pairs after a moveto are implicit linetos.
                command = relative ? "l" : "L"
            case "L", "l":
                let p = scanner.point(base)
                path.addLine(to: p)
                current = p
            case "H", "h":
                let x = scanner.number() + (relative ? current.x : 0)
                current = CGPoint(x: x, y: current.y)
                path.addLine(to: current)
            case "V", "v":
                let y = scanner.number() + (relative ? current.y : 0)
                current = CGPoint(x: current.x, y: y)
                path.addLine(to: current)
            case "C", "c":
                let c1 = scanner.point(base)
                let c2 = scanner.point(base)
                let p = scanner.point(base)
                path.addCurve(to: p, control1: c1, control2: c2)
                current = p
            case "A", "a":
                let rx = scanner.number()
                let ry = scanner.number()
                let rotation = scanner.number()
                let large = scanner.flag()
                let sweep = scanner.flag()
                let p = scanner.point(base)
                addArc(to: path, from: current, to: p, rx: rx, ry: ry, rotation: rotation, large: large, sweep: sweep)
                current = p
            default:
                return path
            }
        }
        return path
    }

    /// SVG elliptical arc (endpoint parameterization) as cubic Béziers.
    private static func addArc(to path: CGMutablePath, from p0: CGPoint, to p1: CGPoint,
                               rx rxIn: CGFloat, ry ryIn: CGFloat, rotation: CGFloat, large: Bool, sweep: Bool) {
        var rx = abs(rxIn), ry = abs(ryIn)
        guard rx > 0, ry > 0, p0 != p1 else {
            path.addLine(to: p1)
            return
        }
        let phi = rotation * .pi / 180
        let cosPhi = cos(phi), sinPhi = sin(phi)
        let dx = (p0.x - p1.x) / 2, dy = (p0.y - p1.y) / 2
        let x1p = cosPhi * dx + sinPhi * dy
        let y1p = -sinPhi * dx + cosPhi * dy
        let lambda = (x1p * x1p) / (rx * rx) + (y1p * y1p) / (ry * ry)
        if lambda > 1 {
            rx *= sqrt(lambda)
            ry *= sqrt(lambda)
        }
        let num = rx * rx * ry * ry - rx * rx * y1p * y1p - ry * ry * x1p * x1p
        let den = rx * rx * y1p * y1p + ry * ry * x1p * x1p
        var coef = sqrt(max(0, num / den))
        if large == sweep { coef = -coef }
        let cxp = coef * (rx * y1p / ry)
        let cyp = coef * -(ry * x1p / rx)
        let cx = cosPhi * cxp - sinPhi * cyp + (p0.x + p1.x) / 2
        let cy = sinPhi * cxp + cosPhi * cyp + (p0.y + p1.y) / 2

        func angle(_ ux: CGFloat, _ uy: CGFloat, _ vx: CGFloat, _ vy: CGFloat) -> CGFloat {
            let dot = ux * vx + uy * vy
            let len = sqrt(ux * ux + uy * uy) * sqrt(vx * vx + vy * vy)
            var a = acos(max(-1, min(1, dot / len)))
            if ux * vy - uy * vx < 0 { a = -a }
            return a
        }
        let theta1 = angle(1, 0, (x1p - cxp) / rx, (y1p - cyp) / ry)
        var delta = angle((x1p - cxp) / rx, (y1p - cyp) / ry, (-x1p - cxp) / rx, (-y1p - cyp) / ry)
        if !sweep, delta > 0 { delta -= 2 * .pi }
        if sweep, delta < 0 { delta += 2 * .pi }

        let segments = max(1, Int(ceil(abs(delta) / (.pi / 2))))
        let step = delta / CGFloat(segments)
        let t = 4.0 / 3.0 * tan(step / 4)
        var theta = theta1
        for _ in 0..<segments {
            let cos1 = cos(theta), sin1 = sin(theta)
            let cos2 = cos(theta + step), sin2 = sin(theta + step)
            func map(_ x: CGFloat, _ y: CGFloat) -> CGPoint {
                CGPoint(x: cx + rx * x * cosPhi - ry * y * sinPhi, y: cy + rx * x * sinPhi + ry * y * cosPhi)
            }
            let c1 = map(cos1 - t * sin1, sin1 + t * cos1)
            let c2 = map(cos2 + t * sin2, sin2 - t * cos2)
            let end = map(cos2, sin2)
            path.addCurve(to: end, control1: c1, control2: c2)
            theta += step
        }
    }

    private struct Tokens {
        enum Token { case command(Character), number }
        let chars: [Character]
        var index = 0
        var lastIndex = 0

        init(_ text: String) { chars = Array(text) }

        mutating func skipSeparators() {
            while index < chars.count, chars[index] == " " || chars[index] == "," || chars[index] == "\n" || chars[index] == "\t" {
                index += 1
            }
        }

        mutating func nextCommandOrNumber() -> Token? {
            skipSeparators()
            lastIndex = index
            guard index < chars.count else { return nil }
            let c = chars[index]
            if c.isLetter {
                index += 1
                return .command(c)
            }
            return .number
        }

        mutating func pushBack() { index = lastIndex }

        mutating func number() -> CGFloat {
            skipSeparators()
            let begin = index
            if index < chars.count, chars[index] == "-" || chars[index] == "+" { index += 1 }
            var seenDot = false
            var seenExp = false
            while index < chars.count {
                let c = chars[index]
                if c.isNumber {
                    index += 1
                } else if c == ".", !seenDot, !seenExp {
                    seenDot = true
                    index += 1
                } else if (c == "e" || c == "E"), !seenExp {
                    seenExp = true
                    index += 1
                    if index < chars.count, chars[index] == "-" || chars[index] == "+" { index += 1 }
                } else {
                    break
                }
            }
            return CGFloat(Double(String(chars[begin..<index])) ?? 0)
        }

        /// Arc flags may be written without separators ("a1 1 0 0 1 1-1" or "a1 1 0 011-1").
        mutating func flag() -> Bool {
            skipSeparators()
            guard index < chars.count else { return false }
            let c = chars[index]
            index += 1
            return c == "1"
        }

        mutating func point(_ base: CGPoint) -> CGPoint {
            let x = number()
            let y = number()
            return CGPoint(x: base.x + x, y: base.y + y)
        }
    }
}
