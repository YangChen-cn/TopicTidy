import AppKit
import SwiftUI
import Testing

@testable import TopicTidy

/// Renders the inline recovery notice that replaced the alert sheet.
/// Set TOPICTIDY_RENDER_RECOVERY to write PNGs for review.
@MainActor
@Test func recoveryNoticeRenders() throws {
    let model = AppModel()
    model.error = "数据库版本 6 与当前版本 7 不兼容"
    model.incompatibleDatabase = true

    let inline = ImageRenderer(content: RecoveryNotice(model: model).frame(width: 460))
    inline.scale = 2
    let inlineImage = try #require(inline.nsImage)
    #expect(inlineImage.size.width >= 460)
    #expect(inlineImage.size.height > 100)

    let compact = ImageRenderer(content: RecoveryNotice(model: model, compact: true).frame(width: 340))
    compact.scale = 2
    let compactImage = try #require(compact.nsImage)
    #expect(compactImage.size.width >= 340)

    model.incompatibleDatabase = false
    model.error = "无法打开应用锁：/tmp/organizer.lock"
    let failure = ImageRenderer(content: RecoveryNotice(model: model).frame(width: 460))
    failure.scale = 2
    #expect(try #require(failure.nsImage).size.height > 60)

    if let path = ProcessInfo.processInfo.environment["TOPICTIDY_RENDER_RECOVERY"] {
        try writePNG(inlineImage, to: "\(path)-window.png")
        try writePNG(compactImage, to: "\(path)-panel.png")
        try writePNG(try #require(failure.nsImage), to: "\(path)-failure.png")
    }
}

private func writePNG(_ image: NSImage, to path: String) throws {
    guard let tiff = image.tiffRepresentation,
          let bitmap = NSBitmapImageRep(data: tiff),
          let png = bitmap.representation(using: .png, properties: [:]) else {
        Issue.record("could not encode \(path)")
        return
    }
    try png.write(to: URL(fileURLWithPath: path))
}
