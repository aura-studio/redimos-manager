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
    // Enable native full screen: the green (zoom) traffic-light button takes the
    // window full screen (⌥-click still does classic zoom). .fullScreenPrimary
    // is what lets a window BE the full-screen space — the previous
    // .fullScreenAuxiliary only allowed floating over someone else's full screen,
    // which is why the button did nothing. Keep .resizable so zoom/full screen
    // are offered at all.
    self.styleMask.insert(.resizable)
    self.collectionBehavior = [.fullScreenPrimary]

    RegisterGeneratedPlugins(registry: flutterViewController)
    super.awakeFromNib()

    // Human-readable window title. Deferred to the next runloop turn because the
    // launch sequence sets the title to the bundle name (redimos_manager) after
    // awakeFromNib; setting it async lets ours win.
    self.title = "Redimos Manager"
    DispatchQueue.main.async { [weak self] in self?.title = "Redimos Manager" }

    // Force the window visible + frontmost. Under some launch contexts the
    // storyboard's "visible at launch" doesn't order the window front, leaving
    // a running app with no on-screen window.
    self.makeKeyAndOrderFront(nil)
    NSApp.activate(ignoringOtherApps: true)
  }
}
