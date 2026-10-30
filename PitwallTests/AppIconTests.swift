import SwiftUI
import XCTest
@testable import Pitwall

/// Renders the app icon (notifications, Settings, Finder) into the asset catalog.
/// Opt-in: TEST_RUNNER_APPICON_DIR=<repo>/Pitwall/Assets.xcassets/AppIcon.appiconset xcodebuild ... test
final class AppIconTests: XCTestCase {
    @MainActor
    func testRenderAppIcon() throws {
        let path = ProcessInfo.processInfo.environment["APPICON_DIR"]
        try XCTSkipIf(path == nil, "app icon rendering is opt-in")
        let dir = URL(fileURLWithPath: path!)
        for pixels in [16, 32, 64, 128, 256, 512, 1024] {
            let renderer = ImageRenderer(content: AppIconArt().frame(width: 1024, height: 1024))
            renderer.scale = CGFloat(pixels) / 1024
            let cg = try XCTUnwrap(renderer.cgImage)
            let png = try XCTUnwrap(NSBitmapImageRep(cgImage: cg).representation(using: .png, properties: [:]))
            try png.write(to: dir.appending(path: "icon_\(pixels).png"))
        }
    }
}

/// macOS icon grid: an 824 pt rounded square on a 1024 canvas, the mascot standing in a soft teal light.
private struct AppIconArt: View {
    var body: some View {
        Canvas { ctx, size in
            let s = size.width / 1024
            let tile = CGRect(x: 100 * s, y: 100 * s, width: 824 * s, height: 824 * s)
            let shape = Path(roundedRect: tile, cornerRadius: 185 * s, style: .continuous)
            ctx.drawLayer { layer in // drop shadow under the tile, like system icons
                layer.addFilter(.shadow(color: .black.opacity(0.35), radius: 14 * s, y: 10 * s))
                layer.fill(shape, with: .color(.black))
            }
            ctx.fill(shape, with: .linearGradient(
                Gradient(colors: [Color(red: 0.20, green: 0.21, blue: 0.25), Color(red: 0.08, green: 0.09, blue: 0.11)]),
                startPoint: CGPoint(x: 512 * s, y: 100 * s), endPoint: CGPoint(x: 512 * s, y: 924 * s)))
            var inner = ctx
            inner.clip(to: shape)
            inner.fill(Path(ellipseIn: CGRect(x: 152 * s, y: 130 * s, width: 720 * s, height: 720 * s)),
                       with: .radialGradient(Gradient(colors: [Color(red: 0.24, green: 0.78, blue: 0.76).opacity(0.28), .clear]),
                                             center: CGPoint(x: 512 * s, y: 470 * s), startRadius: 0, endRadius: 360 * s))
            inner.fill(Path(ellipseIn: CGRect(x: 292 * s, y: 744 * s, width: 440 * s, height: 56 * s)),
                       with: .color(.black.opacity(0.35)))
            ctx.withCGContext { cg in
                NSAppearance(named: .darkAqua)!.performAsCurrentDrawingAppearance {
                    Mark.draw(cg, in: CGRect(x: 182 * s, y: 160 * s, width: 660 * s, height: 660 * s),
                              state: MarkState(mode: .running), t: 0, template: false)
                }
            }
        }
    }
}
