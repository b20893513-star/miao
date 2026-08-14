#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <objc/runtime.h>
#import <objc/message.h>

static NSInteger gVolCount = 0;
static NSTimeInterval gVolWindowStart = 0;
static NSTimeInterval gLastVol = 0;
static BOOL gBootDone = NO;

static void MiaoMarker(NSString *note) {
	NSString *line = [NSString stringWithFormat:@"%@ | %@\n", [NSDate date], note ?: @""];
	[line writeToFile:@"/var/mobile/Documents/miao-loaded.txt" atomically:YES encoding:NSUTF8StringEncoding error:nil];
}

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
		dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(2.2 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
			[lab removeFromSuperview];
		});
	});
}

static CGPoint MiaoPoint(void) {
	NSDictionary *prefs = [NSDictionary dictionaryWithContentsOfFile:@"/var/mobile/Library/Preferences/com.noxlab.miao.plist"];
	CGRect b = UIScreen.mainScreen.bounds;
	CGFloat x = prefs[@"TapX"] ? [prefs[@"TapX"] doubleValue] : CGRectGetMidX(b);
	CGFloat y = prefs[@"TapY"] ? [prefs[@"TapY"] doubleValue] : 160.0;
	return CGPointMake(x, y);
}

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

static BOOL MiaoIsIconView(UIView *v) {
	NSString *cls = NSStringFromClass(v.class);
	return [cls containsString:@"SBIconView"];
}

static void MiaoCollectIcons(UIView *view, NSMutableArray *out) {
	if (MiaoIsIconView(view) && !view.hidden && view.alpha > 0.01) {
		[out addObject:view];
	}
	for (UIView *sub in view.subviews) {
		MiaoCollectIcons(sub, out);
	}
}

static id MiaoIconFromView(UIView *iconView) {
	if ([iconView respondsToSelector:@selector(icon)]) {
		return ((id (*)(id, SEL))objc_msgSend)(iconView, @selector(icon));
	}
	return nil;
}

static NSString *MiaoIconName(id icon, UIView *iconView) {
	@try {
		if (icon && [icon respondsToSelector:@selector(displayName)]) {
			id name = ((id (*)(id, SEL))objc_msgSend)(icon, @selector(displayName));
			if ([name isKindOfClass:[NSString class]] && [name length]) return name;
		}
		SEL locSel = NSSelectorFromString(@"displayNameForLocation:");
		if (icon && [icon respondsToSelector:locSel]) {
			id name = ((id (*)(id, SEL, NSInteger))objc_msgSend)(icon, locSel, 0);
			if ([name isKindOfClass:[NSString class]] && [name length]) return name;
		}
	} @catch (NSException *ex) { (void)ex; }
	return NSStringFromClass(iconView.class);
}

static NSString *MiaoBundleID(id icon) {
	if (!icon) return nil;
	NSArray *sels = @[
		@"applicationBundleID",
		@"applicationBundleIdentifier",
		@"leafIdentifier",
		@"parentLeafIdentifier",
	];
	for (NSString *name in sels) {
		SEL sel = NSSelectorFromString(name);
		if (![icon respondsToSelector:sel]) continue;
		@try {
			id val = ((id (*)(id, SEL))objc_msgSend)(icon, sel);
			if ([val isKindOfClass:[NSString class]] && [val length] && ![val containsString:@":"]) {
				// leafIdentifier a volte e' bundle id puro
				return val;
			}
			if ([val isKindOfClass:[NSString class]] && [val hasPrefix:@"com."]) {
				return val;
			}
		} @catch (NSException *ex) { (void)ex; }
	}
	return nil;
}

static BOOL MiaoOpenBundleID(NSString *bid) {
	if (bid.length == 0) return NO;
	MiaoMarker([NSString stringWithFormat:@"open bid %@", bid]);

	// 1) LSApplicationWorkspace
	Class wsCls = NSClassFromString(@"LSApplicationWorkspace");
	if (wsCls) {
		id ws = ((id (*)(id, SEL))objc_msgSend)(wsCls, NSSelectorFromString(@"defaultWorkspace"));
		NSArray *openSels = @[
			@"openApplicationWithBundleID:",
			@"openApplicationWithBundleIdentifier:",
		];
		for (NSString *name in openSels) {
			SEL sel = NSSelectorFromString(name);
			if (ws && [ws respondsToSelector:sel]) {
				@try {
					BOOL ok = ((BOOL (*)(id, SEL, id))objc_msgSend)(ws, sel, bid);
					if (ok) return YES;
				} @catch (NSException *ex) { (void)ex; }
			}
		}
		// openApplicationWithBundleIdentifier:configuration:error:
		SEL confSel = NSSelectorFromString(@"openApplicationWithBundleIdentifier:configuration:error:");
		if (ws && [ws respondsToSelector:confSel]) {
			@try {
				NSError *err = nil;
				BOOL ok = ((BOOL (*)(id, SEL, id, id, NSError **))objc_msgSend)(ws, confSel, bid, nil, &err);
				if (ok) return YES;
			} @catch (NSException *ex) { (void)ex; }
		}
	}

	// 2) UIApplication private
	id app = [UIApplication sharedApplication];
	SEL launchSel = NSSelectorFromString(@"launchApplicationWithIdentifier:suspended:");
	if ([app respondsToSelector:launchSel]) {
		@try {
			BOOL ok = ((BOOL (*)(id, SEL, id, BOOL))objc_msgSend)(app, launchSel, bid, NO);
			if (ok) return YES;
		} @catch (NSException *ex) { (void)ex; }
	}

	// 3) URL scheme fallback for common apps
	NSDictionary *schemes = @{
		@"com.apple.mobilesafari": @"http://",
		@"com.apple.mobilemail": @"mailto:",
		@"com.apple.mobileslideshow": @"photos-redirect://",
		@"com.apple.camera": @"camera://",
		@"com.apple.Preferences": @"prefs:",
		@"com.apple.MobileSMS": @"sms:",
		@"com.apple.mobilephone": @"tel://",
	};
	NSString *urlStr = schemes[bid];
	if (urlStr) {
		NSURL *url = [NSURL URLWithString:urlStr];
		if (url) {
			[app openURL:url options:@{} completionHandler:nil];
			return YES;
		}
	}

	return NO;
}

static BOOL MiaoLaunchViaIconController(id icon, UIView *iconView) {
	Class icCls = NSClassFromString(@"SBIconController");
	if (!icCls) return NO;
	id ctrl = nil;
	if ([icCls respondsToSelector:NSSelectorFromString(@"sharedInstance")]) {
		ctrl = ((id (*)(id, SEL))objc_msgSend)(icCls, NSSelectorFromString(@"sharedInstance"));
	} else if ([icCls respondsToSelector:NSSelectorFromString(@"sharedInstanceIfExists")]) {
		ctrl = ((id (*)(id, SEL))objc_msgSend)(icCls, NSSelectorFromString(@"sharedInstanceIfExists"));
	}
	if (!ctrl) return NO;

	NSArray *pairs = @[
		@[ @"iconTapped:", iconView ?: icon ],
		@[ @"_iconTapped:", iconView ?: icon ],
		@[ @"iconHandleLongPress:", iconView ?: icon ],
		@[ @"_launchIcon:", icon ],
		@[ @"launchIcon:", icon ],
	];
	for (NSArray *pair in pairs) {
		SEL sel = NSSelectorFromString(pair[0]);
		id arg = pair[1];
		if (!arg || ![ctrl respondsToSelector:sel]) continue;
		@try {
			((void (*)(id, SEL, id))objc_msgSend)(ctrl, sel, arg);
			return YES;
		} @catch (NSException *ex) { (void)ex; }
	}
	return NO;
}

static void MiaoTapSpringBoardUI(void) {
	CGPoint target = MiaoPoint();
	NSMutableArray<UIView *> *icons = [NSMutableArray array];
	for (UIWindow *win in MiaoAllWindows()) {
		MiaoCollectIcons(win, icons);
	}
	MiaoMarker([NSString stringWithFormat:@"icons %lu at %.0f,%.0f", (unsigned long)icons.count, target.x, target.y]);
	if (icons.count == 0) {
		MiaoToast(@"Nessuna icona");
		return;
	}

	UIView *best = nil;
	CGFloat bestDist = CGFLOAT_MAX;
	UIView *containing = nil;
	for (UIView *iconView in icons) {
		CGRect frameInWin = [iconView convertRect:iconView.bounds toView:nil];
		if (CGRectContainsPoint(frameInWin, target)) {
			containing = iconView;
			break;
		}
		CGPoint c = CGPointMake(CGRectGetMidX(frameInWin), CGRectGetMidY(frameInWin));
		CGFloat d = (c.x - target.x) * (c.x - target.x) + (c.y - target.y) * (c.y - target.y);
		if (d < bestDist) { bestDist = d; best = iconView; }
	}
	UIView *chosen = containing ?: best;
	if (!chosen) {
		MiaoToast(@"Nessun target");
		return;
	}

	id icon = MiaoIconFromView(chosen);
	NSString *name = MiaoIconName(icon, chosen);
	NSString *bid = MiaoBundleID(icon);

	if (bid.length && MiaoOpenBundleID(bid)) {
		MiaoToast([NSString stringWithFormat:@"Apro %@", name]);
		return;
	}
	if (MiaoLaunchViaIconController(icon, chosen)) {
		MiaoToast([NSString stringWithFormat:@"Launch %@", name]);
		return;
	}

	// Foto: bundle tipico
	if ([name.lowercaseString containsString:@"foto"] || [name.lowercaseString containsString:@"photo"]) {
		if (MiaoOpenBundleID(@"com.apple.mobileslideshow")) {
			MiaoToast(@"Apro Foto");
			return;
		}
	}

	MiaoToast([NSString stringWithFormat:@"Fail %@ %@", name, bid ?: @"?"]);
	MiaoMarker([NSString stringWithFormat:@"fail name=%@ bid=%@", name, bid ?: @"nil"]);
}

static void MiaoFireTap(void) {
	MiaoToast(@"Miao TAP…");
	dispatch_async(dispatch_get_main_queue(), ^{
		MiaoTapSpringBoardUI();
	});
}

static void MiaoVol(void) {
	NSTimeInterval now = NSDate.date.timeIntervalSince1970;
	if (now - gLastVol < 0.15) return;
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
	if (gBootDone) return;
	gBootDone = YES;
	MiaoMarker(@"boot ok launch-bid");
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
		MiaoMarker(@"ctor launch-bid");
		[[NSNotificationCenter defaultCenter] addObserverForName:@"AVSystemController_SystemVolumeDidChangeNotification"
														  object:nil
														   queue:NSOperationQueue.mainQueue
													  usingBlock:^(__unused NSNotification *n) { MiaoVol(); }];
		dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(5 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
			MiaoBoot();
		});
	}
}
