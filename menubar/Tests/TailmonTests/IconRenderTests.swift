import AppKit
import XCTest

@testable import Tailmon

final class IconRenderTests: XCTestCase {
    // Renders the label image and writes a PNG artifact (inspectable at
    // /tmp/tailmon-icon-test.png) — the menu bar itself can't be
    // screenshotted headlessly, so this is the visual check's stand-in.
    func testRenderIconArtifact() throws {
        let info = IconInfo(
            cpu: 5, gpu: 11, ram: 20, pressure: "normal",
            peers: [
                PeerBadge(letter: "B5", status: .offline),
                PeerBadge(letter: "BM", status: .live),
            ])
        let img = IconRenderer.render(info)
        XCTAssertGreaterThan(img.size.width, 40)
        XCTAssertEqual(img.size.height, 22)

        let rep = NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: Int(img.size.width) * 2,
            pixelsHigh: Int(img.size.height) * 2, bitsPerSample: 8, samplesPerPixel: 4,
            hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
            bytesPerRow: 0, bitsPerPixel: 0)!
        rep.size = img.size
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        NSColor.black.setFill() // menu bar is dark on the owner's machines
        NSRect(origin: .zero, size: img.size).fill()
        img.draw(in: NSRect(origin: .zero, size: img.size))
        NSGraphicsContext.restoreGraphicsState()
        let png = try XCTUnwrap(rep.representation(using: .png, properties: [:]))
        try png.write(to: URL(fileURLWithPath: "/tmp/tailmon-icon-test.png"))
        XCTAssertGreaterThan(png.count, 500) // not a blank image
    }
}
