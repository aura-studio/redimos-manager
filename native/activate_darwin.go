//go:build darwin

package main

/*
#cgo CFLAGS: -x objective-c
#cgo LDFLAGS: -framework AppKit

#include <dispatch/dispatch.h>
#import <AppKit/AppKit.h>

// The old activation API left the SDK headers on macOS 14; declare it so the
// fallback branch below still compiles against older deployment targets.
@interface NSApplication (RedimosCompat)
- (BOOL)activateWithOptions:(NSUInteger)options;
@end

// activateSelfApp brings this process's own windows to the front. It runs
// inside the lock HOLDER (the control server is in-process), so "self" is
// exactly the manager whose window must surface. Dispatching onto the main
// queue is safe from the listener goroutine: AppKit calls must happen on the
// main thread and the app's main run loop drains dispatch's main queue.
static void activateSelfApp() {
	dispatch_async(dispatch_get_main_queue(), ^{
		[NSApp unhide:nil];
		for (NSWindow *w in [NSApp windows]) {
			if ([w isMiniaturized]) {
				[w deminiaturize:nil];
			}
		}
		if ([NSApp respondsToSelector:@selector(activate)]) {
			[NSApp activate]; // macOS 14+
		} else {
			// NSApplicationActivateIgnoringOtherApps == 1 << 1
			[NSApp activateWithOptions:(1 << 1)];
		}
		if ([NSApp mainWindow]) {
			[[NSApp mainWindow] makeKeyAndOrderFront:nil];
		}
	});
}
*/
import "C"

// platformActivate brings this manager's own window to the front.
func platformActivate() {
	C.activateSelfApp()
}
