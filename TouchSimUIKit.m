#import "TouchSimUIKit.h"
#import <objc/runtime.h>
#import <objc/message.h>
#import <stdlib.h>

@interface UIApplication (MiaoPriv)
- (id)_touchesEvent;
@end

/// Chiamate a API private: se un selettore manca lo registriamo invece di crashare.
static BOOL MiaoCall(id obj, NSString *name, NSMutableString *missing, void (^invoke)(SEL sel)) {
	SEL sel = NSSelectorFromString(name);
	if (![obj respondsToSelector:sel]) {
		if (missing) [missing appendFormat:@"%@ ", name];
		return NO;
	}
	invoke(sel);
	return YES;
}

static void MiaoSetObj(id obj, NSString *name, id arg, NSMutableString *missing) {
	MiaoCall(obj, name, missing, ^(SEL sel) {
		((void (*)(id, SEL, id))objc_msgSend)(obj, sel, arg);
	});
}

static void MiaoSetInteger(id obj, NSString *name, NSInteger arg, NSMutableString *missing) {
	MiaoCall(obj, name, missing, ^(SEL sel) {
		((void (*)(id, SEL, NSInteger))objc_msgSend)(obj, sel, arg);
	});
}

static void MiaoSetBool(id obj, NSString *name, BOOL arg, NSMutableString *missing) {
	MiaoCall(obj, name, missing, ^(SEL sel) {
		((void (*)(id, SEL, BOOL))objc_msgSend)(obj, sel, arg);
	});
}

static void MiaoSetDouble(id obj, NSString *name, double arg, NSMutableString *missing) {
	MiaoCall(obj, name, missing, ^(SEL sel) {
		((void (*)(id, SEL, double))objc_msgSend)(obj, sel, arg);
	});
}

static void MiaoSetPoint(id obj, NSString *name, CGPoint p, BOOL reset, NSMutableString *missing) {
	MiaoCall(obj, name, missing, ^(SEL sel) {
		((void (*)(id, SEL, CGPoint, BOOL))objc_msgSend)(obj, sel, p, reset);
	});
}

static UIWindow *MiaoActiveWindow(void) {
	UIWindow *best = nil;
	CGFloat bestArea = 0;
	for (UIScene *sc in UIApplication.sharedApplication.connectedScenes) {
		if (![sc isKindOfClass:[UIWindowScene class]]) continue;
		for (UIWindow *w in ((UIWindowScene *)sc).windows) {
			if (w.hidden || w.alpha < 0.05) continue;
			CGFloat area = w.bounds.size.width * w.bounds.size.height;
			if (w.isKeyWindow) area *= 4;
			if (area > bestArea) {
				bestArea = area;
				best = w;
			}
		}
	}
	if (best) return best;
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations"
	return UIApplication.sharedApplication.keyWindow;
#pragma clang diagnostic pop
}

static CGFloat MiaoJitter(CGFloat amount) {
	return ((CGFloat)arc4random_uniform(2001) / 1000.0 - 1.0) * amount;
}

static NSTimeInterval MiaoNow(void) {
	return [[NSProcessInfo processInfo] systemUptime];
}

/// Configura la stessa UITouch per la fase corrente.
static void MiaoTouchPhase(UITouch *touch, UIWindow *win, UIView *view, CGPoint pt,
						   UITouchPhase phase, BOOL first, NSMutableString *missing) {
	MiaoSetDouble(touch, @"setTimestamp:", MiaoNow(), missing);
	MiaoSetInteger(touch, @"setPhase:", (NSInteger)phase, missing);
	MiaoSetPoint(touch, @"_setLocationInWindow:resetPrevious:", pt, first, missing);
	if (first) {
		MiaoSetObj(touch, @"setWindow:", win, missing);
		MiaoSetObj(touch, @"setView:", view, missing);
		MiaoSetObj(touch, @"setGestureView:", view, nil);
		MiaoSetInteger(touch, @"setTapCount:", 1, missing);
		MiaoSetInteger(touch, @"_setPathIndex:", 1, nil);
		MiaoSetInteger(touch, @"setType:", 0, nil); // UITouchTypeDirect
		MiaoSetBool(touch, @"_setIsFirstTouchForView:", YES, nil);
		MiaoSetBool(touch, @"setIsTap:", YES, nil);
		MiaoSetBool(touch, @"_setIsTapToClick:", YES, nil);
	}
}

static void MiaoSendTouch(UITouch *touch) {
	UIApplication *app = UIApplication.sharedApplication;
	SEL evSel = NSSelectorFromString(@"_touchesEvent");
	if (![app respondsToSelector:evSel]) return;
	id event = ((id (*)(id, SEL))objc_msgSend)(app, evSel);
	if (!event) return;

	SEL clearSel = NSSelectorFromString(@"_clearTouches");
	if ([event respondsToSelector:clearSel])
		((void (*)(id, SEL))objc_msgSend)(event, clearSel);

	SEL addSel = NSSelectorFromString(@"_addTouch:forDelayedDelivery:");
	if ([event respondsToSelector:addSel])
		((void (*)(id, SEL, id, BOOL))objc_msgSend)(event, addSel, touch, NO);
	else
		return;

	[app sendEvent:event];
}

BOOL MiaoUIKitHumanTap(CGPoint winPt, NSString **why) {
	if (![NSThread isMainThread]) {
		__block BOOL ok = NO;
		__block NSString *inner = nil;
		dispatch_sync(dispatch_get_main_queue(), ^{ ok = MiaoUIKitHumanTap(winPt, &inner); });
		if (why) *why = inner;
		return ok;
	}

	UIWindow *win = MiaoActiveWindow();
	if (!win) {
		if (why) *why = @"no window";
		return NO;
	}
	UIView *view = [win hitTest:winPt withEvent:nil];
	if (!view) {
		if (why) *why = @"no hitTest";
		return NO;
	}

	UITouch *touch = nil;
	SEL initInView = NSSelectorFromString(@"initInView:");
	if ([UITouch instancesRespondToSelector:initInView])
		touch = ((id (*)(id, SEL, id))objc_msgSend)([UITouch alloc], initInView, view);
	else
		touch = [[UITouch alloc] init];
	if (!touch) {
		if (why) *why = @"no UITouch";
		return NO;
	}

	NSMutableString *missing = [NSMutableString string];
	MiaoTouchPhase(touch, win, view, winPt, UITouchPhaseBegan, YES, missing);

	UIApplication *app = UIApplication.sharedApplication;
	if (![app respondsToSelector:NSSelectorFromString(@"_touchesEvent")]) {
		if (why) *why = @"no _touchesEvent";
		return NO;
	}
	id probeEvent = ((id (*)(id, SEL))objc_msgSend)(app, NSSelectorFromString(@"_touchesEvent"));
	if (![probeEvent respondsToSelector:NSSelectorFromString(@"_addTouch:forDelayedDelivery:")]) {
		if (why) *why = @"no _addTouch:";
		return NO;
	}

	NSLog(@"[MiaoUIK] tap win=(%.0f,%.0f) view=%@ missing=[%@]",
		winPt.x, winPt.y, NSStringFromClass([view class]),
		missing.length ? missing : @"-");
	if (why) *why = missing.length ? [missing copy] : @"ok";

	MiaoSendTouch(touch);

	// Un dito reale si muove di 1-2 px e resta giu' 55-130 ms. Le fasi vanno su
	// giri di runloop distinti, altrimenti i gesture recognizer non avanzano.
	NSTimeInterval hold = 0.055 + (double)arc4random_uniform(75) / 1000.0;
	NSTimeInterval step = hold / 3.0;
	CGPoint drift = CGPointMake(winPt.x + MiaoJitter(1.4), winPt.y + MiaoJitter(1.4));
	CGPoint drift2 = CGPointMake(drift.x + MiaoJitter(1.0), drift.y + MiaoJitter(1.0));

	dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(step * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
		MiaoTouchPhase(touch, win, view, drift, UITouchPhaseMoved, NO, nil);
		MiaoSendTouch(touch);

		dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(step * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
			MiaoTouchPhase(touch, win, view, drift2, UITouchPhaseMoved, NO, nil);
			MiaoSendTouch(touch);

			dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(step * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
				MiaoTouchPhase(touch, win, view, drift2, UITouchPhaseEnded, NO, nil);
				MiaoSendTouch(touch);
			});
		});
	});

	return YES;
}
