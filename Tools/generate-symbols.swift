#!/usr/bin/env swift
// Generates Packages/DesignSystem/Sources/DesignSystem/Symbols/Resources/Symbols.xcassets from the 24 board symbols
// (Icons.dc.html), the ear (Main.dc.html), and distinct Search/Replace derivatives, as SF Symbols 7 template SVGs.
//
// Approach (recorded in specs/design/m8-symbol-review.md): every symbol is authored once as centreline paths on the
// board's 24 px grid (ink layer + one Ember accent layer). For each of the 27 weight x scale cells the centrelines are
// scaled onto the template (grid unit = 4.0 / 5.0 / 6.5 template units for S / M / L), stroked with a weight-specific
// width that was MEASURED from stock SF Symbols (see `inkStemM`), expanded to outlines with CoreGraphics and unioned.
// All 27 cells are written explicitly, so no master interpolation (and no point-compatible contours) is needed.
//
// Usage: swift Tools/generate-symbols.swift [output-xcassets-dir]
import CoreGraphics
import Foundation

// MARK: - Geometry sources (verbatim from the Icons board; `p` = ink, `a` = Ember accent)

struct Glyph { let name: String; let asset: String; let p: String; let a: String }

let glyphs: [Glyph] = [
    .init(name: "Home", asset: "earmark.home", p: "M4 11.2 12 4.5l8 6.7V19a1 1 0 0 1-1 1H5a1 1 0 0 1-1-1z", a: "M10 20v-4.5h4V20"),
    .init(name: "Queue", asset: "earmark.queue", p: "M5 7h9M5 12h14M5 17h7", a: "M19 7h.01"),
    .init(name: "Meetings", asset: "earmark.meetings", p: "M3.8 19c.5-3 2.8-4.8 5.2-4.8s4.7 1.8 5.2 4.8M9 11.5a3 3 0 1 0 0-6 3 3 0 0 0 0 6z", a: "M15.5 5.6a2.6 2.6 0 0 1 0 5M17.6 14.6c1.6.6 2.7 2 3 4.2"),
    .init(name: "Live captions", asset: "earmark.live.captions", p: "M4 6h16a1 1 0 0 1 1 1v8a1 1 0 0 1-1 1h-7l-4 3.5V16H4a1 1 0 0 1-1-1V7a1 1 0 0 1 1-1z", a: "M7 10h4M7 13h8"),
    .init(name: "Library", asset: "earmark.library", p: "M7 3h7l4 4v13a1 1 0 0 1-1 1H7a1 1 0 0 1-1-1V4a1 1 0 0 1 1-1z", a: "M14 3v4h4"),
    .init(name: "Recently deleted", asset: "earmark.recently.deleted", p: "M4.5 7h15M9.5 7V4.8h5V7M6.5 7l.8 12a1 1 0 0 0 1 .9h7.4a1 1 0 0 0 1-.9l.8-12", a: "M12 16v-5M9.8 13l2.2-2.2 2.2 2.2"),
    .init(name: "Dictation", asset: "earmark.dictation", p: "M12 3.5a3 3 0 0 1 3 3v5a3 3 0 0 1-6 0v-5a3 3 0 0 1 3-3zM6 11.5a6 6 0 0 0 12 0", a: "M12 17.5V21M9 21h6"),
    .init(name: "Record", asset: "earmark.record", p: "M12 21a9 9 0 1 0 0-18 9 9 0 0 0 0 18z", a: "M12 15.2a3.2 3.2 0 1 0 0-6.4 3.2 3.2 0 0 0 0 6.4z"),
    .init(name: "Speaker", asset: "earmark.speaker", p: "M12 12a3.6 3.6 0 1 0 0-7.2 3.6 3.6 0 0 0 0 7.2zM5 20c.6-3.4 3.4-5.4 7-5.4s6.4 2 7 5.4", a: "M18.5 4.5l1 1 2-2"),
    .init(name: "Translate", asset: "earmark.translate", p: "M4 6h9M8.5 4v2M6 6c.4 3.4 2.6 6 5.5 7.5M11.5 6c-.6 3.2-2.8 5.8-6 7.4", a: "M12.8 20l3.6-8.2 3.6 8.2M14 17.4h4.8"),
    .init(name: "Export", asset: "earmark.export", p: "M5 13.5V18a1 1 0 0 0 1 1h12a1 1 0 0 0 1-1v-4.5", a: "M12 15V4.5M8 8.4l4-3.9 4 3.9"),
    .init(name: "Hidden", asset: "earmark.hidden", p: "M3 12s3.4-6 9-6 9 6 9 6-3.4 6-9 6-9-6-9-6z", a: "M4.5 4.5l15 15"),
    .init(name: "Earmark", asset: "earmark.earmark", p: "M7 3.5h10a1 1 0 0 1 1 1V20l-6-3.8L6 20V4.5a1 1 0 0 1 1-1z", a: "M14 3.5v3.5h4"),
    .init(name: "Search", asset: "earmark.search",
        p: "M10 3.5a6.5 6.5 0 1 0 0 13 6.5 6.5 0 0 0 0-13z", a: "M15 15l5.5 5.5"),
    .init(name: "Find", asset: "earmark.find",
        p: "M6 3.5h9l3 3v5M6 3.5v17h6M15 3.5v4h3M9 8h3M9 11h2",
        a: "M16 12a3.5 3.5 0 1 0 0 7 3.5 3.5 0 0 0 0-7zM18.5 18.5l3 3"),
    .init(name: "Replace", asset: "earmark.replace",
        p: "M4 5h10M4 9h7M10 15h10M13 19h7", a: "M17 4l3 3-3 3M20 7h-4M7 14l-3 3 3 3M4 17h4"),
    .init(name: "Models", asset: "earmark.models", p: "M8 6.5h8a1.5 1.5 0 0 1 1.5 1.5v8a1.5 1.5 0 0 1-1.5 1.5H8A1.5 1.5 0 0 1 6.5 16V8A1.5 1.5 0 0 1 8 6.5zM9.5 3.5v3M14.5 3.5v3M9.5 17.5v3M14.5 17.5v3M3.5 9.5h3M3.5 14.5h3M17.5 9.5h3M17.5 14.5h3", a: "M10.5 10.5h3v3h-3z"),
    .init(name: "Settings", asset: "earmark.settings", p: "M4 8h9.8M17.6 8H20M4 16h2.4M10.2 16H20", a: "M13.8 8a1.9 1.9 0 1 0 3.8 0 1.9 1.9 0 1 0-3.8 0zM6.4 16a1.9 1.9 0 1 0 3.8 0 1.9 1.9 0 1 0-3.8 0z"),
    .init(name: "Play", asset: "earmark.play", p: "M12 21a9 9 0 1 0 0-18 9 9 0 0 0 0 18z", a: "M10.2 8.8v6.4l5-3.2z"),
    .init(name: "Waveform", asset: "earmark.waveform", p: "M4 10v4M8 7v10M16 8v8M20 10.5v3", a: "M12 4v16"),
    .init(name: "Folder", asset: "earmark.folder", p: "M3.5 7.5A1.5 1.5 0 0 1 5 6h4l2 2.2h8a1.5 1.5 0 0 1 1.5 1.5v8.3a1.5 1.5 0 0 1-1.5 1.5H5A1.5 1.5 0 0 1 3.5 18z", a: "M3.5 11.5h17"),
    .init(name: "Language", asset: "earmark.language", p: "M12 21a9 9 0 1 0 0-18 9 9 0 0 0 0 18zM12 3c2.5 2.4 3.6 5.4 3.6 9s-1.1 6.6-3.6 9c-2.5-2.4-3.6-5.4-3.6-9S9.5 5.4 12 3z", a: "M3.5 12h17"),
    .init(name: "Download", asset: "earmark.download", p: "M5 19.5h14", a: "M12 4.5v11M8 11.8l4 4 4-4"),
    .init(name: "System audio", asset: "earmark.system.audio", p: "M4 9.8v4.4h3.4l4.6 3.6V6.2L7.4 9.8z", a: "M15.5 9a4 4 0 0 1 0 6M18 6.5a7.5 7.5 0 0 1 0 11"),
    .init(name: "Video", asset: "earmark.video", p: "M3.5 7.5A1.5 1.5 0 0 1 5 6h8.5A1.5 1.5 0 0 1 15 7.5v9a1.5 1.5 0 0 1-1.5 1.5H5A1.5 1.5 0 0 1 3.5 16.5z", a: "M15 10.5l5.5-3v9l-5.5-3z"),
    .init(name: "Retry", asset: "earmark.retry", p: "M19.5 12a7.5 7.5 0 1 1-2.2-5.3", a: "M19.5 4v4h-4"),
    // The ear from the Main board (listening ear: one continuous line plus a sound arc). The board draws it in a 100-unit
    // icon space; `normalizeToLiveArea` refits it onto the 24 px grid.
    .init(name: "Ear", asset: "earmark.ear", p: "M30 8c-9 0-16 7-16 16v6c0 5 3 7 6 10 2 2 3 4 3 7a6 6 0 0 0 11 3M30 20c-4 0-7 3-7 7", a: "M44 20a15 15 0 0 1 0 20"),
]

// MARK: - Weight / scale tables

let weights = ["Ultralight", "Thin", "Light", "Regular", "Medium", "Semibold", "Bold", "Heavy", "Black"]
/// Ink stroke width in template units at Medium scale, measured from stock SF Symbol `circle` at 100 pt
/// (NSImage.SymbolConfiguration, 4x raster, alpha > 50 %): UL 2.25, Thin 3.75, Light 6.25, Regular 8.25, Medium 9.75,
/// Semibold 11.0, Bold 12.75, Heavy 15.0, Black 17.25. The board's Regular 1.6 px on a 24 grid (5.0 units/px) is 8.0.
let inkStemM: [Double] = [2.25, 3.75, 6.25, 8.25, 9.75, 11.0, 12.75, 15.0, 17.25]
/// Template units per board grid pixel. Stock circle centreline diameters at 100 pt measure 72.2 / 90.3 / 117.5 (S/M/L),
/// i.e. 18 px live area x 4.0 / 5.0 / 6.5.
let scales: [(id: String, unit: Double, stemFactor: Double, baseline: Double)] = [
    ("S", 4.0, 0.91, 696), ("M", 5.0, 1.0, 1126), ("L", 6.5, 1.12, 1556),
]
let accentRatio = 2.1 / 1.6
let capHeight = 70.459  // Baseline-S 696 to Capline-S 625.541
let sideBearingM = 12.7  // measured from a stock-derived template (rss.square Regular-M), scaled by unit / 5.0

// MARK: - SVG path parsing (M L H V C S Q T A Z, absolute and relative) into CGPath

struct Scanner2 {
    let chars: [Character]
    var i = 0
    init(_ s: String) { chars = Array(s) }
    mutating func skipSep() { while i < chars.count, chars[i] == " " || chars[i] == "," || chars[i] == "\n" { i += 1 } }
    mutating func peekCommand() -> Character? {
        skipSep()
        guard i < chars.count, chars[i].isLetter else { return nil }
        return chars[i]
    }
    mutating func atNumber() -> Bool {
        skipSep()
        guard i < chars.count else { return false }
        let c = chars[i]
        return c.isNumber || c == "-" || c == "." || c == "+"
    }
    mutating func number() -> Double {
        skipSep()
        var s = ""
        if i < chars.count, chars[i] == "-" || chars[i] == "+" { s.append(chars[i]); i += 1 }
        var seenDot = false
        while i < chars.count {
            let c = chars[i]
            if c.isNumber { s.append(c); i += 1 } else if c == ".", !seenDot { seenDot = true; s.append(c); i += 1 } else { break }
        }
        return Double(s) ?? 0
    }
    /// Arc flags may be written without separators ("0 0 1"), always a single 0/1 character.
    mutating func flag() -> Bool {
        skipSep()
        let c = chars[i]; i += 1
        return c == "1"
    }
}

func arcToCubics(path: CGMutablePath, from p0: CGPoint, rx rxIn: Double, ry ryIn: Double, rotation: Double, large: Bool, sweep: Bool, to p1: CGPoint) {
    var rx = abs(rxIn), ry = abs(ryIn)
    if rx == 0 || ry == 0 || (p0.x == p1.x && p0.y == p1.y) { path.addLine(to: p1); return }
    let phi = rotation * .pi / 180
    let cosPhi = cos(phi), sinPhi = sin(phi)
    let dx = (p0.x - p1.x) / 2, dy = (p0.y - p1.y) / 2
    let x1p = cosPhi * dx + sinPhi * dy, y1p = -sinPhi * dx + cosPhi * dy
    let lambda = (x1p * x1p) / (rx * rx) + (y1p * y1p) / (ry * ry)
    if lambda > 1 { let s = sqrt(lambda); rx *= s; ry *= s }
    let num = rx * rx * ry * ry - rx * rx * y1p * y1p - ry * ry * x1p * x1p
    let den = rx * rx * y1p * y1p + ry * ry * x1p * x1p
    var coef = den == 0 ? 0 : sqrt(max(0, num / den))
    if large == sweep { coef = -coef }
    let cxp = coef * (rx * y1p / ry), cyp = coef * -(ry * x1p / rx)
    let cx = cosPhi * cxp - sinPhi * cyp + (p0.x + p1.x) / 2
    let cy = sinPhi * cxp + cosPhi * cyp + (p0.y + p1.y) / 2
    func angle(_ ux: Double, _ uy: Double, _ vx: Double, _ vy: Double) -> Double {
        let a = atan2(ux * vy - uy * vx, ux * vx + uy * vy)
        return a
    }
    let theta1 = angle(1, 0, (x1p - cxp) / rx, (y1p - cyp) / ry)
    var dTheta = angle((x1p - cxp) / rx, (y1p - cyp) / ry, (-x1p - cxp) / rx, (-y1p - cyp) / ry)
    if !sweep && dTheta > 0 { dTheta -= 2 * .pi }
    if sweep && dTheta < 0 { dTheta += 2 * .pi }
    let segments = Int(ceil(abs(dTheta) / (.pi / 2) - 1e-9))
    let delta = dTheta / Double(max(segments, 1))
    let t = 4.0 / 3.0 * tan(delta / 4)
    var th = theta1
    for _ in 0..<max(segments, 1) {
        let c1 = cos(th), s1 = sin(th), c2 = cos(th + delta), s2 = sin(th + delta)
        func pt(_ x: Double, _ y: Double) -> CGPoint {
            CGPoint(x: cosPhi * rx * x - sinPhi * ry * y + cx, y: sinPhi * rx * x + cosPhi * ry * y + cy)
        }
        let e1 = pt(c1 - t * s1, s1 + t * c1)
        let e2 = pt(c2 + t * s2, s2 - t * c2)
        let end = pt(c2, s2)
        path.addCurve(to: end, control1: e1, control2: e2)
        th += delta
    }
}

func parse(_ d: String) -> CGMutablePath {
    let path = CGMutablePath()
    var sc = Scanner2(d)
    var cur = CGPoint.zero, start = CGPoint.zero
    var lastC: CGPoint? = nil, lastQ: CGPoint? = nil
    var cmd: Character = "M"
    while sc.i < sc.chars.count {
        if let c = sc.peekCommand() { cmd = c; sc.i += 1 } else if !sc.atNumber() { break }
        let rel = cmd.isLowercase
        let up = Character(cmd.uppercased())
        func abs(_ x: Double, _ y: Double) -> CGPoint { rel ? CGPoint(x: cur.x + x, y: cur.y + y) : CGPoint(x: x, y: y) }
        switch up {
        case "Z":
            path.closeSubpath(); cur = start; lastC = nil; lastQ = nil
            continue
        case "M":
            // Zero-length segments in the source ("h.01") are real; only the first pair starts a subpath.
            let p = abs(sc.number(), sc.number()); path.move(to: p); cur = p; start = p
            cmd = rel ? "l" : "L"; lastC = nil; lastQ = nil
        case "L":
            let p = abs(sc.number(), sc.number()); path.addLine(to: p); cur = p; lastC = nil; lastQ = nil
        case "H":
            let x = sc.number(); let p = CGPoint(x: rel ? cur.x + x : x, y: cur.y); path.addLine(to: p); cur = p; lastC = nil; lastQ = nil
        case "V":
            let y = sc.number(); let p = CGPoint(x: cur.x, y: rel ? cur.y + y : y); path.addLine(to: p); cur = p; lastC = nil; lastQ = nil
        case "C":
            let c1 = abs(sc.number(), sc.number()); let c2 = abs(sc.number(), sc.number()); let p = abs(sc.number(), sc.number())
            path.addCurve(to: p, control1: c1, control2: c2); cur = p; lastC = c2; lastQ = nil
        case "S":
            let r = lastC.map { CGPoint(x: 2 * cur.x - $0.x, y: 2 * cur.y - $0.y) } ?? cur
            let c2 = abs(sc.number(), sc.number()); let p = abs(sc.number(), sc.number())
            path.addCurve(to: p, control1: r, control2: c2); cur = p; lastC = c2; lastQ = nil
        case "Q":
            let c1 = abs(sc.number(), sc.number()); let p = abs(sc.number(), sc.number())
            path.addQuadCurve(to: p, control: c1); cur = p; lastQ = c1; lastC = nil
        case "T":
            let c1 = lastQ.map { CGPoint(x: 2 * cur.x - $0.x, y: 2 * cur.y - $0.y) } ?? cur
            let p = abs(sc.number(), sc.number()); path.addQuadCurve(to: p, control: c1); cur = p; lastQ = c1; lastC = nil
        case "A":
            let rx = sc.number(), ry = sc.number(), rot = sc.number()
            let large = sc.flag(), sweep = sc.flag()
            let p = abs(sc.number(), sc.number())
            arcToCubics(path: path, from: cur, rx: rx, ry: ry, rotation: rot, large: large, sweep: sweep, to: p)
            cur = p; lastC = nil; lastQ = nil
        default: fatalError("unsupported path command \(cmd)")
        }
    }
    return path
}

// MARK: - Output

func fmt(_ v: CGFloat) -> String {
    var s = String(format: "%.3f", Double(v))
    while s.contains("."), s.hasSuffix("0") { s.removeLast() }
    if s.hasSuffix(".") { s.removeLast() }
    return s == "-0" ? "0" : s
}

func svgD(_ path: CGPath) -> String {
    var out = ""
    path.applyWithBlock { e in
        let el = e.pointee, p = el.points
        switch el.type {
        case .moveToPoint: out += "M\(fmt(p[0].x)) \(fmt(p[0].y))"
        case .addLineToPoint: out += "L\(fmt(p[0].x)) \(fmt(p[0].y))"
        case .addQuadCurveToPoint: out += "Q\(fmt(p[0].x)) \(fmt(p[0].y)) \(fmt(p[1].x)) \(fmt(p[1].y))"
        case .addCurveToPoint: out += "C\(fmt(p[0].x)) \(fmt(p[0].y)) \(fmt(p[1].x)) \(fmt(p[1].y)) \(fmt(p[2].x)) \(fmt(p[2].y))"
        case .closeSubpath: out += "Z"
        @unknown default: break
        }
    }
    return out
}

/// Refits a centreline pair onto the 24 px grid: longest side 18 px (the board's live area), centred on (12, 12).
func normalizeToLiveArea(_ ink: CGPath, _ accent: CGPath) -> (CGPath, CGPath) {
    let box = ink.boundingBoxOfPath.union(accent.boundingBoxOfPath)
    let k = 18.0 / max(box.width, box.height)
    var t = CGAffineTransform(translationX: 12 - box.midX * k, y: 12 - box.midY * k)
    t = CGAffineTransform(scaleX: k, y: k).concatenating(t)
    return (ink.copy(using: &t)!, accent.copy(using: &t)!)
}

struct Cell { let weight: String; let scale: String; let ink: CGPath; let accent: CGPath; let advance: Double; let dx: Double }

func outline(_ centreline: CGPath, width: Double, transform: CGAffineTransform) -> CGPath {
    var t = transform
    let scaled = centreline.copy(using: &t)!
    let stroked = scaled.copy(strokingWithWidth: width, lineCap: .round, lineJoin: .round, miterLimit: 10)
    return stroked.normalized(using: .winding)
}

func buildCells(_ g: Glyph) -> [Cell] {
    var ink = parse(g.p) as CGPath, accent = parse(g.a) as CGPath
    if g.asset == "earmark.ear" { (ink, accent) = normalizeToLiveArea(ink, accent) }
    var cells: [Cell] = []
    for (wi, w) in weights.enumerated() {
        for s in scales {
            let stem = inkStemM[wi] * s.stemFactor
            // grid (12,12) -> cap-height centre of the baseline; y grows downwards like the template.
            let t = CGAffineTransform(a: s.unit, b: 0, c: 0, d: s.unit, tx: -12 * s.unit, ty: -12 * s.unit - capHeight / 2)
            let i = outline(ink, width: stem, transform: t)
            let a = outline(accent, width: stem * accentRatio, transform: t)
            let box = i.boundingBoxOfPath.union(a.boundingBoxOfPath)
            let sb = sideBearingM * s.unit / 5.0
            let advance = box.width + 2 * sb
            cells.append(Cell(weight: w, scale: s.id, ink: i, accent: a, advance: advance, dx: sb - box.minX))
        }
    }
    return cells
}

func shifted(_ p: CGPath, dx: Double) -> CGPath {
    var t = CGAffineTransform(translationX: dx, y: 0)
    return p.copy(using: &t)!
}

func templateSVG(_ g: Glyph) -> String {
    let cells = buildCells(g)
    var out = """
    <?xml version="1.0" encoding="UTF-8"?>
    <!--Generator: Earmark generate-symbols.swift (stroke-expanded, 9 weights x 3 scales, all 27 cells explicit)-->
    <!DOCTYPE svg
    PUBLIC "-//W3C//DTD SVG 1.1//EN"
           "http://www.w3.org/Graphics/SVG/1.1/DTD/svg11.dtd">
    <svg version="1.1" xmlns="http://www.w3.org/2000/svg" xmlns:xlink="http://www.w3.org/1999/xlink" viewBox="0 0 3300 2200">
     <!--symbol: "Earmark \(g.name)", point size: 100.0, font version: "22.0d5e4", template writer version: "138.0.0"-->
     <style>.defaults {-sfsymbols-wiggle-style:linear;-sfsymbols-wiggle-angle:0;-sfsymbols-variable-value-mode:color;-sfsymbols-draw-reverses-motion-groups:false}
    .monochrome-0 {-sfsymbols-motion-group:1}
    .monochrome-1 {-sfsymbols-motion-group:0}
    .multicolor-0:black {-sfsymbols-motion-group:1}
    .multicolor-1:tintColor {-sfsymbols-motion-group:0}
    .hierarchical-0:primary {-sfsymbols-motion-group:1}
    .hierarchical-1:secondary {-sfsymbols-motion-group:0}
    .SFSymbolsPreviewWireframe {fill:none;opacity:1.0;stroke:black;stroke-width:0.5}
    </style>
     <g id="Notes">
      <rect height="2200" id="artboard" style="fill:white;opacity:1" width="3300" x="0" y="0"/>
      <line style="fill:none;stroke:black;opacity:1;stroke-width:0.5;" x1="263" x2="3036" y1="292" y2="292"/>
      <text style="stroke:none;fill:black;font-family:sans-serif;font-size:13;font-weight:bold;" transform="matrix(1 0 0 1 263 322)">Weight/Scale Variations</text>

    """
    let centres = (0..<9).map { 559.711 + 296.711 * Double($0) }
    for (i, w) in weights.enumerated() {
        out += "  <text style=\"stroke:none;fill:black;font-family:sans-serif;font-size:13;text-anchor:middle;\" transform=\"matrix(1 0 0 1 \(fmt(centres[i])) 322)\">\(w)</text>\n"
    }
    out += """
      <text id="template-version" style="stroke:none;fill:black;font-family:sans-serif;font-size:13;text-anchor:end;" transform="matrix(1 0 0 1 3036 1933)">Template v.7.0</text>
      <text style="stroke:none;fill:black;font-family:sans-serif;font-size:13;text-anchor:end;" transform="matrix(1 0 0 1 3036 1951)">Requires Xcode 26 or greater</text>
      <text id="descriptive-name" style="stroke:none;fill:black;font-family:sans-serif;font-size:13;text-anchor:end;" transform="matrix(1 0 0 1 3036 1969)">Earmark \(g.name) (ink line plus one Ember accent)</text>
      <text style="stroke:none;fill:black;font-family:sans-serif;font-size:13;text-anchor:end;" transform="matrix(1 0 0 1 3036 1987)">Typeset at 100.0 points</text>
      <text style="stroke:none;fill:black;font-family:sans-serif;font-size:13;" transform="matrix(1 0 0 1 263 726)">Small</text>
      <text style="stroke:none;fill:black;font-family:sans-serif;font-size:13;" transform="matrix(1 0 0 1 263 1156)">Medium</text>
      <text style="stroke:none;fill:black;font-family:sans-serif;font-size:13;" transform="matrix(1 0 0 1 263 1586)">Large</text>
     </g>
     <g id="Guides">

    """
    for s in scales {
        out += "  <line id=\"Baseline-\(s.id)\" style=\"fill:none;stroke:#27AAE1;opacity:1;stroke-width:0.5;\" x1=\"263\" x2=\"3036\" y1=\"\(fmt(s.baseline))\" y2=\"\(fmt(s.baseline))\"/>\n"
        out += "  <line id=\"Capline-\(s.id)\" style=\"fill:none;stroke:#27AAE1;opacity:1;stroke-width:0.5;\" x1=\"263\" x2=\"3036\" y1=\"\(fmt(s.baseline - capHeight))\" y2=\"\(fmt(s.baseline - capHeight))\"/>\n"
    }
    func tx(_ c: Cell) -> Double { centres[weights.firstIndex(of: c.weight)!] - c.advance / 2 }
    for s in scales.reversed() {
        for c in cells.reversed() where c.scale == s.id {
            let x = tx(c)
            let top = s.baseline - 95.2, bottom = s.baseline + 24.1
            out += "  <line id=\"right-margin-\(c.weight)-\(s.id)\" style=\"fill:none;stroke:#00AEEF;stroke-width:0.5;opacity:1.0;\" x1=\"\(fmt(x + c.advance))\" x2=\"\(fmt(x + c.advance))\" y1=\"\(fmt(top))\" y2=\"\(fmt(bottom))\"/>\n"
            out += "  <line id=\"left-margin-\(c.weight)-\(s.id)\" style=\"fill:none;stroke:#00AEEF;stroke-width:0.5;opacity:1.0;\" x1=\"\(fmt(x))\" x2=\"\(fmt(x))\" y1=\"\(fmt(top))\" y2=\"\(fmt(bottom))\"/>\n"
        }
    }
    out += " </g>\n <g id=\"Symbols\">\n"
    for s in scales.reversed() {
        for c in cells.reversed() where c.scale == s.id {
            out += "  <g id=\"\(c.weight)-\(s.id)\" transform=\"matrix(1 0 0 1 \(fmt(tx(c))) \(fmt(s.baseline)))\">\n"
            out += "   <path class=\"monochrome-0 multicolor-0:black hierarchical-0:primary SFSymbolsPreviewWireframe\" d=\"\(svgD(shifted(c.ink, dx: c.dx)))\"/>\n"
            out += "   <path class=\"monochrome-1 multicolor-1:tintColor hierarchical-1:secondary SFSymbolsPreviewWireframe\" d=\"\(svgD(shifted(c.accent, dx: c.dx)))\"/>\n"
            out += "  </g>\n"
        }
    }
    out += " </g>\n</svg>\n"
    return out
}

// MARK: - Main

let args = CommandLine.arguments
let root = args.count > 1 ? args[1] : "Packages/DesignSystem/Sources/DesignSystem/Symbols/Resources/Symbols.xcassets"
let fm = FileManager.default
try? fm.removeItem(atPath: root)
try fm.createDirectory(atPath: root, withIntermediateDirectories: true)
try #"{"info":{"author":"xcode","version":1}}"#.write(toFile: root + "/Contents.json", atomically: true, encoding: .utf8)
for g in glyphs {
    let dir = "\(root)/\(g.asset).symbolset"
    try fm.createDirectory(atPath: dir, withIntermediateDirectories: true)
    try templateSVG(g).write(toFile: "\(dir)/\(g.asset).svg", atomically: true, encoding: .utf8)
    let contents = """
    {
      "info" : {
        "author" : "xcode",
        "version" : 1
      },
      "symbols" : [
        {
          "filename" : "\(g.asset).svg",
          "idiom" : "universal"
        }
      ]
    }

    """
    try contents.write(toFile: "\(dir)/Contents.json", atomically: true, encoding: .utf8)
}
print("wrote \(glyphs.count) symbolsets to \(root)")
