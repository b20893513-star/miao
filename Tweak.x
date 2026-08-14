#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <notify.h>
#import "TouchSim.h"

static NSString * const kNotifyTap = @"com.noxlab.miao.tap";
static NSInteger gVolCount = 0;
static NSTimeInterval gVolWindowStart = 0;
static UILabel *gToastLabel = nil;
static BOOL gDidBootToast = NO;

static void MiaoWriteMarker(NSString *note) {
	NSString *msg = [NSString stringWithFormat:@"%@ | %@\n", [NSDate date], note ?: @""];
	NSArray *paths = @[
		@"/var/mobile/Documents/miao-loaded.txt",
		@"/var/jb/var/mobile/Documents/miao-loaded.txt",
		@"/tmp/miao-loaded.txt"
	];
	NSData *data = [msg dataUsingEncoding:NSUTF8StringEncoding];
	for (NSString *p in paths) {
		[data writeToFile:p atomically:YES];
	}
}

static UIWindow *MiaoFindWindow(void) {
	UIWindow *win = nil;
	if (@available(iOS 13.0, *)) {
		for (UIScene *scene in UIApplication.sharedApplication.connectedScenes) {
			if (![scene isKindOfClass:[UIWindowScene class]]) continue;
			UIWindowScene *ws = (UIWindowScene *)scene;
			for (UIWindow *w in ws.windows) {
				if (w.isKeyWindow) return w;
			}
			if (ws.windows.count) win = ws.windows.firstObject;
		}
	}
	if (!win) {
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations"
		win = UIApplication.sharedApplication.keyWindow;
#pragma clang diagnostic pop
	}
	return win;
}

static void MiaoToast(NSString *text) {
	dispatch_async(dispatch_get_main_queue(), ^{
		UIWindow *win = MiaoFindWindow();
		if (!win) {
			MiaoWriteMarker([@"toast-no-window: " stringByAppendingString:text ?: @""]);
			return;
		}
		if (!gToastLabel) {
			gToastLabel = [[UILabel alloc] initWithFrame:CGRectZero];
			gToastLabel.backgroundColor = [[UIColor blackColor] colorWithAlphaComponent:0.85];
			gToastLabel.textColor = [UIColor whiteColor];
			gToastLabel.font = [UIFont boldSystemFontOfSize:14];
			gToastLabel.textAlignment = NSTextAlignmentCenter;
			gToastLabel.layer.cornerRadius = 10;
			gToastLabel.clipsToBounds = YES;
			gToastLabel.numberOfLines = 2;
		}
		gToastLabel.text = [NSString stringWithFormat:@"  %@  ", text];
		[gToastLabel sizeToFit];
		CGFloat w = MAX(170, gToastLabel.bounds.size.width + 24);
		CGFloat h = MAX(36, gToastLabel.bounds.size.height + 12);
		gToastLabel.frame = CGRectMake((win.bounds.size.width - w) / 2.0, 64, w, h);
		if (!gToastLabel.superview) [win addSubview:gToastLabel];
		[win bringSubviewToFront:gToastLabel];
		gToastLabel.alpha = 1;
		dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(2.0 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
			[UIView animateWithDuration:0.25 animations:^{ gToastLabel.alpha = 0; }];
		});
	});
}

static CGPoint MiaoReadTapPoint(void) {
	CGRect bounds = UIScreen.mainScreen.bounds;
	CGFloat defX = CGRectGetMidX(bounds);
	CGFloat defY = CGRectGetMidY(bounds) * 0.35f;
	NSString *path = @"/var/mobile/Library/Preferences/com.noxlab.miao.plist";
	NSString *jbPath = @"/var/jb/var/mobile/Library/Preferences/com.noxlab.miao.plist";
	if ([[NSFileManager defaultManager] fileExistsAtPath:jbPath]) path = jbPath;
	NSDictionary *prefs = [NSDictionary dictionaryWithContentsOfFile:path];
	if (![prefs isKindOfClass:[NSDictionary class]]) return CGPointMake(defX, defY);
	CGFloat x = prefs[@"TapX"] ? [prefs[@"TapX"] doubleValue] : defX;
	CGFloat y = prefs[@"TapY"] ? [prefs[@"TapY"] doubleValue] : defY;
	return CGPointMake(x, y);
}

static void MiaoFireConfiguredTap(void) {
	CGPoint p = MiaoReadTapPoint();
	MiaoWriteMarker([NSString stringWithFormat:@"tap %.1f %.1f", p.x, p.y]);
	MiaoToast([NSString stringWithFormat:@"Miao TAP (%.0f, %.0f)", p.x, p.y]);
	dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.4 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
		MiaoPerformTap(p.x, p.y);
	});
}

static void MiaoOnVolumePulse(void) {
	NSTimeInterval now = [NSDate date].timeIntervalSince1970;
	if (gVolWindowStart <= 0 || (now - gVolWindowStart) > 1.4) {
		gVolWindowStart = now;
		gVolCount = 1;
		MiaoToast(@"Miao 1/3");
		return;
	}
	gVolCount += 1;
	if (gVolCount < 3) {
		MiaoToast([NSString stringWithFormat:@"Miao %ld/3", (long)gVolCount]);
		return;
	}
	gVolCount = 0;
	gVolWindowStart = 0;
	MiaoFireConfiguredTap();
}

static void MiaoBootBanner(void) {
	if (gDidBootToast) return;
	gDidBootToast = YES;
	MiaoWriteMarker(@"boot-banner");
	MiaoToast(@"Miao attivo — 3x Volume");
}

%hook SpringBoard

- (void)applicationDidFinishLaunching:(id)application {
	%orig;
	dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.0 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
		MiaoBootBanner();
	});
}

%end

%hook SBVolumeControl

- (void)decreaseVolume {
	MiaoOnVolumePulse();
	%orig;
}

- (void)increaseVolume {
	MiaoOnVolumePulse();
	%orig;
}

%end

%hook SBMediaController

- (void)decreaseVolume {
	MiaoOnVolumePulse();
	%orig;
}

- (void)increaseVolume {
	MiaoOnVolumePulse();
	%orig;
}

%end

%ctor {
	MiaoWriteMarker([NSString stringWithFormat:@"ctor %@", NSBundle.mainBundle.bundleIdentifier ?: @"?"]);
	NSLog(@"[Miao] ctor in %@", NSBundle.mainBundle.bundleIdentifier ?: @"?");
	dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(4.0 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
		MiaoBootBanner();
	});
	int token = 0;
	notify_register_dispatch([kNotifyTap UTF8String], &token, dispatch_get_main_queue(), ^(int t) {
		(void)t;
		MiaoFireConfiguredTap();
	});
}
