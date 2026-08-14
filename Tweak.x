/**
 * Miao v0 — solo SpringBoard (vedi miao.plist).
 *
 * Trigger: 3x Volume DOWN entro ~1.2s → tap alle coordinate in config.
 * Config (opzionale): /var/mobile/Library/Preferences/com.noxlab.miao.plist
 *   TapX (float), TapY (float) — points. Default: zona icone Home.
 *
 * Darwin notify (NewTerm):
 *   notifyutil -p com.noxlab.miao.tap
 */

#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <notify.h>
#import "TouchSim.h"

static NSString * const kNotifyTap = @"com.noxlab.miao.tap";

static NSInteger gVolDownCount = 0;
static NSTimeInterval gVolDownWindowStart = 0;

static CGPoint MiaoReadTapPoint(void) {
	CGRect bounds = UIScreen.mainScreen.bounds;
	CGFloat defX = CGRectGetMidX(bounds);
	CGFloat defY = CGRectGetMidY(bounds) * 0.35f;

	NSString *path = @"/var/mobile/Library/Preferences/com.noxlab.miao.plist";
	NSString *jbPath = @"/var/jb/var/mobile/Library/Preferences/com.noxlab.miao.plist";
	if ([[NSFileManager defaultManager] fileExistsAtPath:jbPath]) {
		path = jbPath;
	}

	NSDictionary *prefs = [NSDictionary dictionaryWithContentsOfFile:path];
	if (![prefs isKindOfClass:[NSDictionary class]]) {
		return CGPointMake(defX, defY);
	}
	CGFloat x = prefs[@"TapX"] ? [prefs[@"TapX"] doubleValue] : defX;
	CGFloat y = prefs[@"TapY"] ? [prefs[@"TapY"] doubleValue] : defY;
	return CGPointMake(x, y);
}

static void MiaoFireConfiguredTap(void) {
	CGPoint p = MiaoReadTapPoint();
	NSLog(@"[Miao] firing configured tap at {%.1f, %.1f}", p.x, p.y);
	dispatch_async(dispatch_get_main_queue(), ^{
		MiaoPerformTap(p.x, p.y);
	});
}

static void MiaoOnVolumeDown(void) {
	NSTimeInterval now = [NSDate date].timeIntervalSince1970;
	if (gVolDownWindowStart <= 0 || (now - gVolDownWindowStart) > 1.2) {
		gVolDownWindowStart = now;
		gVolDownCount = 1;
		return;
	}
	gVolDownCount += 1;
	if (gVolDownCount >= 3) {
		gVolDownCount = 0;
		gVolDownWindowStart = 0;
		MiaoFireConfiguredTap();
	}
}

%hook SBVolumeControl

- (void)decreaseVolume {
	MiaoOnVolumeDown();
	%orig;
}

%end

%ctor {
	NSLog(@"[Miao] loaded in %@", NSBundle.mainBundle.bundleIdentifier ?: @"?");

	int token = 0;
	notify_register_dispatch(kNotifyTap.UTF8String, &token, dispatch_get_main_queue(), ^(int t) {
		(void)t;
		MiaoFireConfiguredTap();
	});
}
