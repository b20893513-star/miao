#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <objc/runtime.h>
#import <objc/message.h>
#import <notify.h>

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
		lab.text = [NSString stringWithFormat:@"  %@  ", text];
		[lab sizeToFit];
		CGFloat w = MAX(180, lab.bounds.size.width + 28);
		CGFloat h = MAX(40, lab.bounds.size.height + 14);
		lab.frame = CGRectMake((win.bounds.size.width - w) / 2.0, 70, w, h);
		[win addSubview:lab];
		dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.8 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
			[lab removeFromSuperview];
		});
	});
}

static CGPoint MiaoPoint(void) {
	NSDictionary *prefs = [NSDictionary dictionaryWithContentsOfFile:@"/var/mobile/Library/Preferences/com.noxlab.miao.plist"];
	CGRect b = UIScreen.mainScreen.bounds;
	CGFloat x = prefs[@"TapX"] ? [prefs[@"TapX"] doubleValue] : CGRectGetMidX(b);
	CGFloat y = prefs[@"TapY"] ? [prefs[@"TapY"] doubleValue] : (CGRectGetMidY(b) * 0.35);
	return CGPointMake(x, y);
}

static BOOL MiaoTryMsg(id obj, NSArray<NSString *> *sels) {
	for (NSString *name in sels) {
		SEL sel = NSSelectorFromString(name);
		if ([obj respondsToSelector:sel]) {
			NSMethodSignature *sig = [obj methodSignatureForSelector:sel];
			if (!sig) continue;
			NSInvocation *inv = [NSInvocation invocationWithMethodSignature:sig];
			inv.selector = sel;
			inv.target = obj;
			NSUInteger args = sig.numberOfArguments;
			// id, SEL, then optional id event/sender
			if (args >= 3) {
				id nilObj = nil;
				[inv setArgument:&nilObj atIndex:2];
			}
			@try {
				[inv invoke];
				MiaoMarker([NSString stringWithFormat:@"invoked %@ on %@", name, NSStringFromClass([obj class])]);
				return YES;
			} @catch (NSException *ex) {
				(void)ex;
			}
		}
	}
	return NO;
}

// Tap "logico" sulla Home: niente HID (quello crashava backboardd/SpringBoard)
static void MiaoTapSpringBoardUI(void) {
	CGPoint p = MiaoPoint();
	MiaoMarker([NSString stringWithFormat:@"ui-tap %.0f %.0f", p.x, p.y]);

	UIWindow *win = nil;
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations"
	win = UIApplication.sharedApplication.keyWindow;
#pragma clang diagnostic pop
	if (!win) {
		for (UIScene *scene in UIApplication.sharedApplication.connectedScenes) {
			if (![scene isKindOfClass:[UIWindowScene class]]) continue;
			for (UIWindow *w in ((UIWindowScene *)scene).windows) {
				if (w.isKeyWindow) { win = w; break; }
			}
			if (!win && ((UIWindowScene *)scene).windows.count) {
				win = ((UIWindowScene *)scene).windows.firstObject;
			}
			if (win) break;
		}
	}
	if (!win) {
		MiaoToast(@"TAP: no window");
		return;
	}

	UIView *hit = [win hitTest:p withEvent:nil];
	UIView *cur = hit;
	NSMutableString *chain = [NSMutableString string];
	while (cur) {
		[chain appendFormat:@"%@>", NSStringFromClass(cur.class)];
		NSString *cls = NSStringFromClass(cur.class);

		if ([cls containsString:@"SBIconView"] || [cls containsString:@"IconView"]) {
			if (MiaoTryMsg(cur, @[
				@"iconTapped:",
				@"iconTouchUp:",
				@"tap:",
				@"_tap:",
			])) {
				MiaoToast(@"TAP icona");
				return;
			}
		}

		if ([cur isKindOfClass:[UIControl class]]) {
			[(UIControl *)cur sendActionsForControlEvents:UIControlEventTouchUpInside];
			MiaoToast(@"TAP control");
			MiaoMarker(@"UIControl TouchUpInside");
			return;
		}

		if ([cls containsString:@"UIButton"] || [cls containsString:@"Button"]) {
			if (MiaoTryMsg(cur, @[@"sendActionsForControlEvents:", @"tap:"])) {
				MiaoToast(@"TAP button");
				return;
			}
		}

		cur = cur.superview;
	}

	MiaoMarker([NSString stringWithFormat:@"no target chain %@", chain]);
	MiaoToast(@"TAP: niente sotto");
}

static void MiaoFireTap(void) {
	MiaoToast(@"Miao TAP");
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
	MiaoMarker(@"boot ok no-hid");
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
		MiaoMarker(@"ctor springboard-ui-only");
		[[NSNotificationCenter defaultCenter] addObserverForName:@"AVSystemController_SystemVolumeDidChangeNotification"
														  object:nil
														   queue:NSOperationQueue.mainQueue
													  usingBlock:^(__unused NSNotification *n) { MiaoVol(); }];
		dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(5 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
			MiaoBoot();
		});
	}
}
