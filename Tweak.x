#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <objc/runtime.h>
#import <objc/message.h>
#import <CoreFoundation/CoreFoundation.h>

static NSInteger gVolCount = 0;
static NSTimeInterval gVolWindowStart = 0;
static NSTimeInterval gLastVol = 0;
static BOOL gBootDone = NO;
static BOOL gSessionBusy = NO;

static NSString *const kMiaoPrefPath = @"/var/mobile/Library/Preferences/com.noxlab.miao.plist";
static NSString *const kMiaoDefaultURL = @"https://noxreel.uk/";
static CFStringRef const kNotifyTap = CFSTR("com.noxlab.miao.tapcenter");
static CFStringRef const kNotifyCloseTabs = CFSTR("com.noxlab.miao.closetabs");

#pragma mark - Utils

static void MiaoMarker(NSString *note) {
	NSString *line = [NSString stringWithFormat:@"%@ | %@\n", [NSDate date], note ?: @""];
	[line writeToFile:@"/var/mobile/Documents/miao-loaded.txt" atomically:YES encoding:NSUTF8StringEncoding error:nil];
}

static __weak UILabel *gToastLab = nil;

static void MiaoToast(NSString *text) {
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
		if (!win && UIApplication.sharedApplication.windows.count) {
			win = UIApplication.sharedApplication.windows.firstObject;
		}
		if (!win) return;

		[gToastLab removeFromSuperview];
		UILabel *lab = [[UILabel alloc] initWithFrame:CGRectZero];
		lab.backgroundColor = [[UIColor blackColor] colorWithAlphaComponent:0.85];
		lab.textColor = UIColor.whiteColor;
		lab.font = [UIFont boldSystemFontOfSize:15];
		lab.textAlignment = NSTextAlignmentCenter;
		lab.layer.cornerRadius = 10;
		lab.clipsToBounds = YES;
		lab.numberOfLines = 2;
		lab.text = [NSString stringWithFormat:@"  %@  ", text];
		[lab sizeToFit];
		CGFloat w = MAX(200, lab.bounds.size.width + 28);
		CGFloat h = MAX(40, lab.bounds.size.height + 14);
		lab.frame = CGRectMake((win.bounds.size.width - w) / 2.0, 70, w, h);
		[win addSubview:lab];
		gToastLab = lab;
		dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(2.5 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
			if (gToastLab == lab) [lab removeFromSuperview];
		});
	});
}

static NSDictionary *MiaoPrefs(void) {
	NSDictionary *p = [NSDictionary dictionaryWithContentsOfFile:kMiaoPrefPath];
	return p ?: @{};
}

static NSString *MiaoSessionURL(void) {
	NSString *u = MiaoPrefs()[@"SessionURL"];
	if ([u isKindOfClass:[NSString class]] && u.length > 4) return u;
	return kMiaoDefaultURL;
}

static NSTimeInterval MiaoWaitSeconds(void) {
	id v = MiaoPrefs()[@"WaitSeconds"];
	double s = v ? [v doubleValue] : 12.0;
	if (s < 5.0) s = 5.0;
	if (s > 120.0) s = 120.0;
	return s;
}

static NSInteger MiaoCycles(void) {
	id v = MiaoPrefs()[@"Cycles"];
	NSInteger n = v ? [v integerValue] : 1;
	if (n < 1) n = 1;
	if (n > 20) n = 20;
	return n;
}

static BOOL MiaoIsSpringBoard(void) {
	NSString *bid = NSBundle.mainBundle.bundleIdentifier ?: @"";
	return [bid isEqualToString:@"com.apple.springboard"];
}

static BOOL MiaoIsSafari(void) {
	NSString *bid = NSBundle.mainBundle.bundleIdentifier ?: @"";
	return [bid isEqualToString:@"com.apple.mobilesafari"];
}

#pragma mark - Open URL / Safari

static BOOL MiaoOpenURLString(NSString *urlStr) {
	if (urlStr.length == 0) return NO;
	NSURL *url = [NSURL URLWithString:urlStr];
	if (!url) return NO;
	MiaoMarker([NSString stringWithFormat:@"openURL %@", urlStr]);

	id app = [UIApplication sharedApplication];
	if ([app respondsToSelector:@selector(openURL:options:completionHandler:)]) {
		[app openURL:url options:@{} completionHandler:nil];
		return YES;
	}
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations"
	if ([app respondsToSelector:@selector(openURL:)]) {
		return [app openURL:url];
	}
#pragma clang diagnostic pop
	return NO;
}

static BOOL MiaoOpenBundleID(NSString *bid) {
	if (bid.length == 0) return NO;
	MiaoMarker([NSString stringWithFormat:@"open bid %@", bid]);

	Class wsCls = NSClassFromString(@"LSApplicationWorkspace");
	if (wsCls) {
		id ws = ((id (*)(id, SEL))objc_msgSend)(wsCls, NSSelectorFromString(@"defaultWorkspace"));
		for (NSString *name in @[ @"openApplicationWithBundleID:", @"openApplicationWithBundleIdentifier:" ]) {
			SEL sel = NSSelectorFromString(name);
			if (ws && [ws respondsToSelector:sel]) {
				@try {
					if (((BOOL (*)(id, SEL, id))objc_msgSend)(ws, sel, bid)) return YES;
				} @catch (NSException *ex) { (void)ex; }
			}
		}
	}

	id app = [UIApplication sharedApplication];
	SEL launchSel = NSSelectorFromString(@"launchApplicationWithIdentifier:suspended:");
	if ([app respondsToSelector:launchSel]) {
		@try {
			if (((BOOL (*)(id, SEL, id, BOOL))objc_msgSend)(app, launchSel, bid, NO)) return YES;
		} @catch (NSException *ex) { (void)ex; }
	}
	return NO;
}

#pragma mark - Soft tap (in-process, no HID)

static NSArray<UIWindow *> *MiaoAllWindows(void) {
	NSMutableArray *arr = [NSMutableArray array];
	for (UIScene *scene in UIApplication.sharedApplication.connectedScenes) {
		if (![scene isKindOfClass:[UIWindowScene class]]) continue;
		[arr addObjectsFromArray:((UIWindowScene *)scene).windows];
	}
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations"
	if (arr.count == 0 && UIApplication.sharedApplication.windows.count) {
		[arr addObjectsFromArray:UIApplication.sharedApplication.windows];
	}
#pragma clang diagnostic pop
	return arr;
}

static CGPoint MiaoTapPoint(void) {
	NSDictionary *prefs = MiaoPrefs();
	CGRect b = UIScreen.mainScreen.bounds;
	CGFloat x = prefs[@"TapX"] ? [prefs[@"TapX"] doubleValue] : CGRectGetMidX(b);
	CGFloat y = prefs[@"TapY"] ? [prefs[@"TapY"] doubleValue] : (CGRectGetMidY(b) + 40.0);
	return CGPointMake(x, y);
}

/// Tap soft: hitTest + UIControl / gesture — niente digitizer HID (quello crashava).
static BOOL MiaoSoftTapAt(CGPoint pt) {
	UIWindow *win = nil;
	for (UIWindow *w in MiaoAllWindows()) {
		if (w.isKeyWindow || w.windowLevel >= UIWindowLevelNormal) {
			win = w;
			if (w.isKeyWindow) break;
		}
	}
	if (!win && MiaoAllWindows().count) win = MiaoAllWindows().firstObject;
	if (!win) {
		MiaoMarker(@"softTap no window");
		return NO;
	}

	UIView *hit = [win hitTest:pt withEvent:nil];
	MiaoMarker([NSString stringWithFormat:@"softTap (%.0f,%.0f) hit=%@", pt.x, pt.y, hit ? NSStringFromClass(hit.class) : @"nil"]);
	if (!hit) return NO;

	UIView *v = hit;
	while (v) {
		if ([v isKindOfClass:[UIControl class]]) {
			UIControl *c = (UIControl *)v;
			[c sendActionsForControlEvents:UIControlEventTouchUpInside];
			return YES;
		}
		v = v.superview;
	}

	// Fallback: tap gesture recognizers
	v = hit;
	while (v) {
		for (UIGestureRecognizer *gr in v.gestureRecognizers) {
			if (![gr isKindOfClass:[UITapGestureRecognizer class]]) continue;
			if (!gr.enabled) continue;
			@try {
				SEL act = NSSelectorFromString(@"_executeAction");
				if ([gr respondsToSelector:act]) {
					((void (*)(id, SEL))objc_msgSend)(gr, act);
					return YES;
				}
				id targets = [gr valueForKey:@"_targets"];
				(void)targets;
			} @catch (NSException *ex) { (void)ex; }
		}
		// UIView tap via private
		SEL tapSel = NSSelectorFromString(@"_sendActionsForEvents:withEvent:");
		(void)tapSel;
		v = v.superview;
	}

	// Ultimo tentativo: becomeFirstResponder / touches simulation minima su UIView
	@try {
		NSSet *set = [NSSet set];
		(void)set;
		if ([hit respondsToSelector:@selector(touchesBegan:withEvent:)]) {
			// Senza UITouch reale spesso non basta — log e basta
			MiaoMarker(@"softTap hit no control — serve OCR/IA dopo");
		}
	} @catch (NSException *ex) { (void)ex; }
	return NO;
}

static void MiaoSoftTapCenter(void) {
	CGPoint pt = MiaoTapPoint();
	BOOL ok = MiaoSoftTapAt(pt);
	MiaoToast(ok ? @"Tap soft OK" : @"Tap soft miss");
}

#pragma mark - Safari close tabs

static BOOL MiaoSafariCloseAllTabs(void) {
	NSArray *classNames = @[ @"BrowserController", @"TabController", @"_SFBrowserController", @"SafariWebViewController" ];
	for (NSString *cn in classNames) {
		Class cls = NSClassFromString(cn);
		if (!cls) continue;
		id obj = nil;
		for (NSString *shared in @[ @"sharedBrowserController", @"sharedInstance", @"sharedController" ]) {
			SEL sel = NSSelectorFromString(shared);
			if ([cls respondsToSelector:sel]) {
				@try {
					obj = ((id (*)(id, SEL))objc_msgSend)(cls, sel);
					if (obj) break;
				} @catch (NSException *ex) { (void)ex; }
			}
		}
		if (!obj) continue;

		for (NSString *m in @[ @"closeAllTabs", @"closeAllOpenTabs", @"closeTabs:", @"closeAllTabsAnimated:" ]) {
			SEL sel = NSSelectorFromString(m);
			if (![obj respondsToSelector:sel]) continue;
			@try {
				if ([m hasSuffix:@":"]) {
					((void (*)(id, SEL, id))objc_msgSend)(obj, sel, @YES);
				} else {
					((void (*)(id, SEL))objc_msgSend)(obj, sel);
				}
				MiaoMarker([NSString stringWithFormat:@"closeTabs via %@ %@", cn, m]);
				return YES;
			} @catch (NSException *ex) { (void)ex; }
		}
	}
	MiaoMarker(@"closeTabs fail");
	return NO;
}

#pragma mark - Session (SpringBoard)

static void MiaoPost(CFStringRef name) {
	CFNotificationCenterPostNotification(CFNotificationCenterGetDarwinNotifyCenter(), name, NULL, NULL, true);
}

static void MiaoRunOneCycle(NSInteger index, NSInteger total, void (^done)(void)) {
	NSString *url = MiaoSessionURL();
	NSTimeInterval wait = MiaoWaitSeconds();

	MiaoToast([NSString stringWithFormat:@"Ciclo %ld/%ld\nApro Safari", (long)(index + 1), (long)total]);
	MiaoMarker([NSString stringWithFormat:@"cycle %ld url=%@", (long)index, url]);

	MiaoOpenURLString(url);

	// Dopo caricamento: chiedi a Safari un tap soft al centro (play / video)
	dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(4.0 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
		MiaoToast(@"Tap centro…");
		MiaoPost(kNotifyTap);
	});

	dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)((4.0 + wait) * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
		MiaoToast([NSString stringWithFormat:@"Attesi %.0fs — chiudo schede", wait]);
		MiaoPost(kNotifyCloseTabs);
		dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.2 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
			if (done) done();
		});
	});
}

static void MiaoSessionStep(NSInteger index, NSInteger total) {
	if (index >= total) {
		gSessionBusy = NO;
		MiaoToast(@"Sessione fine");
		MiaoMarker(@"session end");
		return;
	}
	MiaoRunOneCycle(index, total, ^{
		dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.8 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
			MiaoSessionStep(index + 1, total);
		});
	});
}

static void MiaoRunSession(void) {
	if (!MiaoIsSpringBoard()) return;
	if (gSessionBusy) {
		MiaoToast(@"Sessione già in corso");
		return;
	}
	gSessionBusy = YES;
	NSInteger cycles = MiaoCycles();
	MiaoToast(@"Sessione Miao…");
	MiaoMarker(@"session start");
	MiaoSessionStep(0, cycles);
}

#pragma mark - Volume trigger (SpringBoard)

static void MiaoFire(void) {
	NSString *mode = MiaoPrefs()[@"Mode"];
	if ([mode isKindOfClass:[NSString class]] && [mode.lowercaseString isEqualToString:@"icon"]) {
		// legacy: apri Safari bundle (non sessione)
		MiaoToast(@"Apro Safari…");
		if (MiaoOpenBundleID(@"com.apple.mobilesafari") || MiaoOpenURLString(@"https://")) {
			return;
		}
		MiaoToast(@"Fail Safari");
		return;
	}
	MiaoRunSession();
}

static void MiaoVol(void) {
	if (!MiaoIsSpringBoard()) return;
	NSTimeInterval now = NSDate.date.timeIntervalSince1970;
	if (now - gLastVol < 0.45) return;
	gLastVol = now;
	if (gVolWindowStart <= 0 || (now - gVolWindowStart) > 2.0) {
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
	MiaoFire();
}

static void MiaoBoot(void) {
	if (gBootDone) return;
	gBootDone = YES;
	NSString *bid = NSBundle.mainBundle.bundleIdentifier ?: @"?";
	MiaoMarker([NSString stringWithFormat:@"boot ok %@", bid]);
	if (MiaoIsSpringBoard()) {
		MiaoToast(@"Miao 0.4 - 3x Vol = sessione");
	}
}

#pragma mark - Darwin (Safari)

static void MiaoDarwinCallback(CFNotificationCenterRef center, void *observer, CFStringRef name, const void *object, CFDictionaryRef userInfo) {
	(void)center; (void)observer; (void)object; (void)userInfo;
	NSString *n = (__bridge NSString *)name;
	dispatch_async(dispatch_get_main_queue(), ^{
		if (!MiaoIsSafari()) return;
		if ([n containsString:@"tapcenter"]) {
			MiaoToast(@"Miao tap…");
			MiaoSoftTapCenter();
		} else if ([n containsString:@"closetabs"]) {
			BOOL ok = MiaoSafariCloseAllTabs();
			MiaoToast(ok ? @"Schede chiuse" : @"Chiudi schede fail");
		}
	});
}

static void MiaoRegisterSafariNotify(void) {
	if (!MiaoIsSafari()) return;
	CFNotificationCenterRef darwin = CFNotificationCenterGetDarwinNotifyCenter();
	CFNotificationCenterAddObserver(darwin, NULL, MiaoDarwinCallback,
		CFSTR("com.noxlab.miao.tapcenter"), NULL,
		CFNotificationSuspensionBehaviorDeliverImmediately);
	CFNotificationCenterAddObserver(darwin, NULL, MiaoDarwinCallback,
		CFSTR("com.noxlab.miao.closetabs"), NULL,
		CFNotificationSuspensionBehaviorDeliverImmediately);
	MiaoMarker(@"safari notify registered");
}

#pragma mark - Hooks

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
		NSString *bid = NSBundle.mainBundle.bundleIdentifier ?: @"?";
		MiaoMarker([NSString stringWithFormat:@"ctor %@", bid]);
		if (MiaoIsSpringBoard()) {
			[[NSNotificationCenter defaultCenter] addObserverForName:@"AVSystemController_SystemVolumeDidChangeNotification"
															  object:nil
															   queue:NSOperationQueue.mainQueue
														  usingBlock:^(__unused NSNotification *n) { MiaoVol(); }];
			dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(5 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
				MiaoBoot();
			});
		} else if (MiaoIsSafari()) {
			MiaoRegisterSafariNotify();
		}
	}
}
