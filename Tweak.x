#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <notify.h>
#import "TouchSim.h"

static NSString * const kNotifyTap = @"com.noxlab.miao.tap";
static NSString * const kNotifyHID = @"com.noxlab.miao.hid";
static NSString * const kTapFile = @"/var/mobile/Library/Preferences/com.noxlab.miao.tapcoords.plist";

static NSInteger gVolCount = 0;
static NSTimeInterval gVolWindowStart = 0;
static NSTimeInterval gLastVol = 0;
static BOOL gBootDone = NO;

static BOOL MiaoIsSpringBoard(void) {
	NSString *b = NSBundle.mainBundle.bundleIdentifier;
	return [b isEqualToString:@"com.apple.springboard"];
}

static void MiaoMarker(NSString *note) {
	NSString *line = [NSString stringWithFormat:@"%@ | %@ | %@\n",
		[NSDate date], NSBundle.mainBundle.bundleIdentifier ?: @"?", note ?: @""];
	[line writeToFile:@"/var/mobile/Documents/miao-loaded.txt" atomically:YES encoding:NSUTF8StringEncoding error:nil];
}

static void MiaoToast(NSString *text) {
	if (!MiaoIsSpringBoard()) return;
	dispatch_async(dispatch_get_main_queue(), ^{
		UIWindow *win = nil;
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations"
		win = UIApplication.sharedApplication.keyWindow;
#pragma clang diagnostic pop
		if (!win) {
			for (UIWindow *w in UIApplication.sharedApplication.windows) {
				if (w.isKeyWindow) { win = w; break; }
			}
		}
		if (!win && UIApplication.sharedApplication.windows.count) win = UIApplication.sharedApplication.windows.firstObject;
		if (!win) return;

		UILabel *lab = [[UILabel alloc] initWithFrame:CGRectZero];
		lab.backgroundColor = [[UIColor blackColor] colorWithAlphaComponent:0.85];
		lab.textColor = UIColor.whiteColor;
		lab.font = [UIFont boldSystemFontOfSize:15];
		lab.textAlignment = NSTextAlignmentCenter;
		lab.layer.cornerRadius = 10;
		lab.clipsToBounds = YES;
		lab.text = [NSString stringWithFormat:@"  %@  ", text];
		[lab sizeToFit];
		CGFloat w = MAX(180, lab.bounds.size.width + 28);
		CGFloat h = MAX(40, lab.bounds.size.height + 14);
		lab.frame = CGRectMake((win.bounds.size.width - w) / 2.0, 70, w, h);
		[win addSubview:lab];
		dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(2.0 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
			[lab removeFromSuperview];
		});
	});
}

static CGPoint MiaoPoint(void) {
	NSDictionary *prefs = [NSDictionary dictionaryWithContentsOfFile:@"/var/mobile/Library/Preferences/com.noxlab.miao.plist"];
	CGRect b = UIScreen.mainScreen.bounds;
	if (b.size.width < 1) b = CGRectMake(0, 0, 414, 896);
	CGFloat x = prefs[@"TapX"] ? [prefs[@"TapX"] doubleValue] : CGRectGetMidX(b);
	CGFloat y = prefs[@"TapY"] ? [prefs[@"TapY"] doubleValue] : (CGRectGetMidY(b) * 0.35);
	return CGPointMake(x, y);
}

static void MiaoSaveCoords(CGPoint p) {
	NSDictionary *d = @{ @"x": @(p.x), @"y": @(p.y), @"t": @([[NSDate date] timeIntervalSince1970]) };
	[d writeToFile:kTapFile atomically:YES];
}

static CGPoint MiaoLoadCoords(void) {
	NSDictionary *d = [NSDictionary dictionaryWithContentsOfFile:kTapFile];
	if (![d isKindOfClass:[NSDictionary class]]) return MiaoPoint();
	return CGPointMake([d[@"x"] doubleValue], [d[@"y"] doubleValue]);
}

static void MiaoDoHID(void) {
	CGPoint p = MiaoLoadCoords();
	MiaoMarker([NSString stringWithFormat:@"hid %.0f %.0f", p.x, p.y]);
	// Fuori dal main se possibile: usleep dentro PerformTap
	dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INTERACTIVE, 0), ^{
		MiaoPerformTap(p.x, p.y);
	});
}

static void MiaoFireTap(void) {
	CGPoint p = MiaoPoint();
	MiaoSaveCoords(p);
	MiaoMarker([NSString stringWithFormat:@"fire %.0f %.0f", p.x, p.y]);
	MiaoToast(@"Miao TAP");
	// Locale + notifica a backboardd
	dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.2 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
		MiaoDoHID();
		notify_post(kNotifyHID.UTF8String);
	});
}

static void MiaoVol(void) {
	if (!MiaoIsSpringBoard()) return;
	NSTimeInterval now = NSDate.date.timeIntervalSince1970;
	if (now - gLastVol < 0.12) return;
	gLastVol = now;

	if (gVolWindowStart <= 0 || (now - gVolWindowStart) > 1.6) {
		gVolWindowStart = now;
		gVolCount = 1;
		MiaoToast(@"Miao 1/3");
		return;
	}
	gVolCount++;
	if (gVolCount < 3) {
		MiaoToast([NSString stringWithFormat:@"Miao %ld/3", (long)gVolCount]);
		return;
	}
	gVolCount = 0;
	gVolWindowStart = 0;
	MiaoFireTap();
}

static void MiaoBoot(void) {
	if (!MiaoIsSpringBoard()) return;
	if (gBootDone) return;
	gBootDone = YES;
	MiaoMarker(@"boot ok");
	MiaoToast(@"Miao OK - 3x Volume");
}

%hook SpringBoard
- (void)applicationDidFinishLaunching:(id)app {
	%orig;
	dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(3 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
		MiaoBoot();
	});
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
		MiaoMarker(@"ctor");
		int tokHid = 0;
		notify_register_dispatch(kNotifyHID.UTF8String, &tokHid, dispatch_get_global_queue(QOS_CLASS_USER_INTERACTIVE, 0), ^(__unused int t) {
			MiaoDoHID();
		});
		int tokTap = 0;
		notify_register_dispatch(kNotifyTap.UTF8String, &tokTap, dispatch_get_main_queue(), ^(__unused int t) {
			MiaoFireTap();
		});

		if (MiaoIsSpringBoard()) {
			[[NSNotificationCenter defaultCenter] addObserverForName:@"AVSystemController_SystemVolumeDidChangeNotification"
															  object:nil
															   queue:NSOperationQueue.mainQueue
														  usingBlock:^(__unused NSNotification *n) { MiaoVol(); }];
			dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(6 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
				MiaoBoot();
			});
		}
	}
}
