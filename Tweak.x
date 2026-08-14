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
	CGFloat y = prefs[@"TapY"] ? [prefs[@"TapY"] doubleValue] : 160.0; // prima riga icone tipica
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
	return [cls containsString:@"SBIconView"] || [cls isEqualToString:@"SBIconView"];
}

static void MiaoCollectIcons(UIView *view, NSMutableArray *out) {
	if (MiaoIsIconView(view) && !view.hidden && view.alpha > 0.01) {
		[out addObject:view];
	}
	for (UIView *sub in view.subviews) {
		MiaoCollectIcons(sub, out);
	}
}

static NSString *MiaoIconName(UIView *iconView) {
	@try {
		id icon = nil;
		if ([iconView respondsToSelector:@selector(icon)]) {
			icon = ((id (*)(id, SEL))objc_msgSend)(iconView, @selector(icon));
		}
		if (icon && [icon respondsToSelector:@selector(displayName)]) {
			id name = ((id (*)(id, SEL))objc_msgSend)(icon, @selector(displayName));
			if ([name isKindOfClass:[NSString class]] && [name length]) return name;
		}
		if (icon && [icon respondsToSelector:NSSelectorFromString(@"displayNameForLocation:")]) {
			SEL sel = NSSelectorFromString(@"displayNameForLocation:");
			id name = ((id (*)(id, SEL, NSInteger))objc_msgSend)(icon, sel, 0);
			if ([name isKindOfClass:[NSString class]] && [name length]) return name;
		}
	} @catch (NSException *ex) { (void)ex; }
	return NSStringFromClass(iconView.class);
}

static BOOL MiaoInvokeIconTap(UIView *iconView) {
	NSArray *sels = @[
		@"iconTapped:",
		@"iconTouchUp:",
		@"tap:",
		@"_launchIcon",
	];
	for (NSString *name in sels) {
		SEL sel = NSSelectorFromString(name);
		if (![iconView respondsToSelector:sel]) continue;
		NSMethodSignature *sig = [iconView methodSignatureForSelector:sel];
		if (!sig) continue;
		NSInvocation *inv = [NSInvocation invocationWithMethodSignature:sig];
		inv.target = iconView;
		inv.selector = sel;
		if (sig.numberOfArguments >= 3) {
			id arg = nil;
			[inv setArgument:&arg atIndex:2];
		}
		@try {
			[inv invoke];
			return YES;
		} @catch (NSException *ex) { (void)ex; }
	}

	// Fallback: tap gesture recognizers
	for (UIGestureRecognizer *gr in iconView.gestureRecognizers) {
		NSString *gcls = NSStringFromClass(gr.class);
		if ([gcls containsString:@"Tap"] || [gcls containsString:@"SB"]) {
			@try {
				if ([gr respondsToSelector:@selector(touchesBegan:withEvent:)]) {
					// last resort: perform action targets if any
				}
				Ivar targetsIvar = class_getInstanceVariable(object_getClass(gr), "_targets");
				(void)targetsIvar;
			} @catch (NSException *ex) { (void)ex; }
		}
	}
	return NO;
}

static void MiaoTapSpringBoardUI(void) {
	CGPoint target = MiaoPoint();
	NSMutableArray<UIView *> *icons = [NSMutableArray array];
	for (UIWindow *win in MiaoAllWindows()) {
		MiaoCollectIcons(win, icons);
	}

	MiaoMarker([NSString stringWithFormat:@"icons-found %lu target=%.0f,%.0f", (unsigned long)icons.count, target.x, target.y]);

	if (icons.count == 0) {
		MiaoToast(@"Nessuna icona trovata");
		return;
	}

	UIView *best = nil;
	CGFloat bestDist = CGFLOAT_MAX;
	UIView *containing = nil;

	for (UIView *icon in icons) {
		UIWindow *win = icon.window;
		if (!win) continue;
		CGRect frameInWin = [icon convertRect:icon.bounds toView:nil];
		if (CGRectContainsPoint(frameInWin, target)) {
			containing = icon;
			break;
		}
		CGPoint c = CGPointMake(CGRectGetMidX(frameInWin), CGRectGetMidY(frameInWin));
		CGFloat dx = c.x - target.x;
		CGFloat dy = c.y - target.y;
		CGFloat d = dx * dx + dy * dy;
		if (d < bestDist) {
			bestDist = d;
			best = icon;
		}
	}

	UIView *chosen = containing ?: best;
	if (!chosen) {
		MiaoToast(@"Icone non tappabili");
		return;
	}

	NSString *name = MiaoIconName(chosen);
	BOOL ok = MiaoInvokeIconTap(chosen);
	if (ok) {
		MiaoToast([NSString stringWithFormat:@"Apro %@", name]);
		MiaoMarker([NSString stringWithFormat:@"opened %@", name]);
	} else {
		// Ultimo tentativo: UIControl
		if ([chosen isKindOfClass:[UIControl class]]) {
			[(UIControl *)chosen sendActionsForControlEvents:UIControlEventTouchUpInside];
			MiaoToast([NSString stringWithFormat:@"Control %@", name]);
		} else {
			MiaoToast([NSString stringWithFormat:@"Fail %@", name]);
			MiaoMarker([NSString stringWithFormat:@"fail invoke %@", name]);
		}
	}
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
	MiaoMarker(@"boot ok icon-scan");
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
		MiaoMarker(@"ctor icon-scan");
		[[NSNotificationCenter defaultCenter] addObserverForName:@"AVSystemController_SystemVolumeDidChangeNotification"
														  object:nil
														   queue:NSOperationQueue.mainQueue
													  usingBlock:^(__unused NSNotification *n) { MiaoVol(); }];
		dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(5 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
			MiaoBoot();
		});
	}
}
