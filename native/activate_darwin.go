//go:build darwin

package main

/*
#cgo CFLAGS: -x objective-c
#cgo LDFLAGS: -framework AppKit

#include <dispatch/dispatch.h>
#import <AppKit/AppKit.h>

// activateSelfApp brings this process's own windows to the front. It runs
// inside the lock HOLDER (the control server is in-process), so "self" is
// exactly the manager whose window must surface. Dispatching onto the main
// queue is safe from the listener goroutine: AppKit calls must happen on the
// main thread and the app's main run loop drains dispatch's main queue.
//
// Re-activation goes through `open` on our own bundle — the same LaunchServices
// path a Dock/icon click uses, which targets the already-running instance and
// is honoured even while another app is frontmost (a direct [NSApp activate]
// from a background process is throttled on macOS 14+ and silently no-ops).
static void activateSelfApp() {
	dispatch_async(dispatch_get_main_queue(), ^{
		[NSApp unhide:nil];
		for (NSWindow *w in [NSApp windows]) {
			if ([w isMiniaturized]) {
				[w deminiaturize:nil];
			}
		}
		if ([NSApp mainWindow]) {
			[[NSApp mainWindow] makeKeyAndOrderFront:nil];
		}
		NSTask *t = [[NSTask alloc] init];
		t.launchPath = @"/usr/bin/open";
		t.arguments = @[ [NSBundle mainBundle].bundlePath ];
		[t launch];
	});
}
*/
import "C"

// platformActivate brings this manager's own window to the front.
func platformActivate() {
	C.activateSelfApp()
}
