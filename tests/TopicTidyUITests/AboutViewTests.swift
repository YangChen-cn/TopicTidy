import AppKit
import SwiftUI
import Testing

@testable import TopicTidy

/// Renders the About window offscreen so its layout is exercised without
/// launching the app. Set TOPICTIDY_RENDER_ABOUT to write a PNG for review.
@MainActor
@Test func aboutViewRenders() throws {
    let renderer = ImageRenderer(content: AboutView())
    renderer.scale = 2
    let image = try #require(renderer.nsImage)
    #expect(image.size.width > 300)
    #expect(image.size.height > 300)

    if let path = ProcessInfo.processInfo.environment["TOPICTIDY_RENDER_ABOUT"] {
        guard let tiff = image.tiffRepresentation,
              let bitmap = NSBitmapImageRep(data: tiff),
              let png = bitmap.representation(using: .png, properties: [:]) else {
            Issue.record("could not encode the About view")
            return
        }
        try png.write(to: URL(fileURLWithPath: path))
    }
}
