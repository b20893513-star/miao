#import "MiaoCore.h"

%hook SpringBoard
- (void)applicationDidFinishLaunching:(id)app {
	%orig;
	MiaoAfter(3, ^{ MiaoBoot(); });
}
%end

%hook SBVolumeControl
- (void)decreaseVolume {
	MiaoVol();
	%orig;
}
- (void)increaseVolume {
	MiaoVol();
	%orig;
}
%end

%ctor {
	@autoreleasepool {
		MiaoLog([@"ctor " stringByAppendingString:(NSBundle.mainBundle.bundleIdentifier ?: @"?")]);
		if (MiaoIsSB()) {
			[[NSNotificationCenter defaultCenter] addObserverForName:@"AVSystemController_SystemVolumeDidChangeNotification"
															  object:nil
															   queue:NSOperationQueue.mainQueue
														  usingBlock:^(__unused NSNotification *n) { MiaoVol(); }];
			MiaoAfter(5, ^{ MiaoBoot(); });
		} else if (MiaoIsSafari()) {
			dispatch_async(dispatch_get_main_queue(), ^{ MiaoStartSafari(); });
			MiaoAfter(2, ^{ MiaoBoot(); });
		}
	}
}
