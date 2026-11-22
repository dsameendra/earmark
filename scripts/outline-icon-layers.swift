// Converts the ear and arc strokes from Brand geometry into filled outlines, because Icon Composer
// layers must be filled shapes (strokes are not rendered). Writes App/Earmark.icon/Assets/{ear,arc}{,-dark}.svg.
// Usage: swift scripts/outline-icon-layers.swift   (run from the repo root; render-brand.sh calls it)
import CoreGraphics
import Foundation

// Geometry from specs/design/m8-mockups/static/Main.html (100-unit tile grid).
let earScale = 1.15, earTX = 12.0, earTY = 16.0   // group transform translate(12 16) scale(1.15)
let earStroke = 4.8, arcStroke = 4.2

func arc(_ p: CGMutablePath, from a: CGPoint, to b: CGPoint, r: CGFloat, large: Bool, sweep: Bool) {
    let hx = (a.x - b.x) / 2, hy = (a.y - b.y) / 2
    let d2 = hx * hx + hy * hy
    let sign: CGFloat = (large == sweep) ? -1 : 1
    let coef = sign * sqrt(max(0, (r * r - d2) / d2))
    let c = CGPoint(x: coef * hy + (a.x + b.x) / 2, y: -coef * hx + (a.y + b.y) / 2)
    let t1 = atan2(a.y - c.y, a.x - c.x), t2 = atan2(b.y - c.y, b.x - c.x)
    // SVG sweep=1 is increasing angle in y-down space; CG's `clockwise` is in y-up space, so invert.
    p.addArc(center: c, radius: r, startAngle: t1, endAngle: t2, clockwise: !sweep)
}

func earPath() -> CGPath {
    let p = CGMutablePath()
    p.move(to: CGPoint(x: 30, y: 8))
    p.addCurve(to: CGPoint(x: 14, y: 24), control1: CGPoint(x: 21, y: 8), control2: CGPoint(x: 14, y: 15))
    p.addLine(to: CGPoint(x: 14, y: 30))
    p.addCurve(to: CGPoint(x: 20, y: 40), control1: CGPoint(x: 14, y: 35), control2: CGPoint(x: 17, y: 37))
    p.addCurve(to: CGPoint(x: 23, y: 47), control1: CGPoint(x: 22, y: 42), control2: CGPoint(x: 23, y: 44))
    arc(p, from: CGPoint(x: 23, y: 47), to: CGPoint(x: 34, y: 50), r: 6, large: false, sweep: false)
    p.move(to: CGPoint(x: 30, y: 20))
    p.addCurve(to: CGPoint(x: 23, y: 27), control1: CGPoint(x: 26, y: 20), control2: CGPoint(x: 23, y: 23))
    return p
}

func arcPath() -> CGPath {
    let p = CGMutablePath()
    p.move(to: CGPoint(x: 44, y: 20))
    arc(p, from: CGPoint(x: 44, y: 20), to: CGPoint(x: 44, y: 40), r: 15, large: false, sweep: true)
    return p
}

func svgD(_ path: CGPath) -> String {
    var d = ""
    func pt(_ q: CGPoint) -> String {
        String(format: "%.2f %.2f", Double(q.x) * earScale + earTX, Double(q.y) * earScale + earTY)
    }
    path.applyWithBlock { e in
        let pts = e.pointee.points
        switch e.pointee.type {
        case .moveToPoint: d += "M\(pt(pts[0]))"
        case .addLineToPoint: d += "L\(pt(pts[0]))"
        case .addQuadCurveToPoint: d += "Q\(pt(pts[0])) \(pt(pts[1]))"
        case .addCurveToPoint: d += "C\(pt(pts[0])) \(pt(pts[1])) \(pt(pts[2]))"
        case .closeSubpath: d += "Z"
        @unknown default: break
        }
    }
    return d
}

func write(_ name: String, _ path: CGPath, width: CGFloat, color: String) {
    let outline = path.copy(strokingWithWidth: width, lineCap: .round, lineJoin: .round, miterLimit: 10)
    let svg = """
    <svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 100 100" width="1024" height="1024">\
    <path d="\(svgD(outline))" fill="\(color)" fill-rule="nonzero"/></svg>

    """
    try! svg.write(toFile: "App/Earmark.icon/Assets/\(name).svg", atomically: true, encoding: .utf8)
}

write("ear", earPath(), width: earStroke, color: "#FFFCF6")
write("ear-dark", earPath(), width: earStroke, color: "#F3EFE7")
write("arc", arcPath(), width: arcStroke, color: "#FFD7BF")
write("arc-dark", arcPath(), width: arcStroke, color: "#F28A57")
