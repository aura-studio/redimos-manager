import Cocoa
import FlutterMacOS

class MainFlutterWindow: NSWindow {
  override func awakeFromNib() {
    let flutterViewController = FlutterViewController()
    self.contentViewController = flutterViewController

    // The manager UI is wide (sidebar + editor). Open at a comfortable size,
    // centered, rather than the 800x600 storyboard default.
    if let screen = self.screen ?? NSScreen.main {
      let vf = screen.visibleFrame
      let w = min(1360, vf.width * 0.9)
      let h = min(900, vf.height * 0.9)
      let x = vf.origin.x + (vf.width - w) / 2
      let y = vf.origin.y + (vf.height - h) / 2
      self.setFrame(NSRect(x: x, y: y, width: w, height: h), display: true)
    }
    self.minSize = NSSize(width: 900, height: 600)
    self.center()
    // Appear on whatever Space is currently displayed (avoids the window
    // opening on a background Space where it stays occluded/unrendered).
    self.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]

    RegisterGeneratedPlugins(registry: flutterViewController)
    super.awakeFromNib()

    // Force the window visible + frontmost. Under some launch contexts the
    // storyboard's "visible at launch" doesn't order the window front, leaving
    // a running app with no on-screen window.
    self.makeKeyAndOrderFront(nil)
    NSApp.activate(ignoringOtherApps: true)
  }
}
