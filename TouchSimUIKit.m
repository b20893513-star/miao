#import "TouchSimUIKit.h"
#import <objc/runtime.h>
#import <objc/message.h>
#import <stdlib.h>
#import <math.h>

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

/**
 Scrive un campo float/double direttamente nell'ivar. Serve per `majorRadius`:
 su iOS 16 non esiste un setter pubblico ne' privato affidabile, ma un touch con
 raggio 0 e' un touch che nessun dito reale produce.
 */
static BOOL MiaoSetFloatIvar(id obj, const char *name, double value) {
	Ivar iv = class_getInstanceVariable([obj class], name);
	if (!iv) return NO;
	const char *enc = ivar_getTypeEncoding(iv);
	if (!enc || !enc[0]) return NO;
	void *slot = (char *)(__bridge void *)obj + ivar_getOffset(iv);
	if (enc[0] == 'f') { *(float *)slot = (float)value; return YES; }
	if (enc[0] == 'd') { *(double *)slot = value; return YES; }
	return NO;
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

static double MiaoRand01(void) {
	return (double)arc4random_uniform(10001) / 10000.0;
}

/// RNG di sessione: se e' impostato, i tocchi di questo run hanno una "mano"
/// diversa (hold, raggio, drift) invece della stessa distribuzione globale.
static uint32_t gTouchRng = 0;

void MiaoUIKitSetTouchSeed(uint32_t seed) {
	gTouchRng = seed ? (seed | 1) : 0;
}

static double MiaoTouchRnd(void) {
	if (!gTouchRng) return MiaoRand01();
	gTouchRng ^= gTouchRng << 13;
	gTouchRng ^= gTouchRng >> 17;
	gTouchRng ^= gTouchRng << 5;
	return (gTouchRng & 0xffffff) / (double)0xffffff;
}

static CGFloat MiaoTouchJitter(CGFloat amount) {
	return (CGFloat)((MiaoTouchRnd() * 2.0 - 1.0) * amount);
}

static NSTimeInterval MiaoNow(void) {
	return [[NSProcessInfo processInfo] systemUptime];
}

/// Impronta del dito: un pollice appoggiato copre ~8-16 pt e respira ad ogni frame.
static void MiaoTouchRadius(UITouch *touch, CGFloat base) {
	CGFloat r = base + MiaoTouchJitter(0.8);
	if (!MiaoSetFloatIvar(touch, "_majorRadius", r))
		MiaoSetDouble(touch, @"setMajorRadius:", r, nil);
	MiaoSetFloatIvar(touch, "_majorRadiusTolerance", 3.0 + MiaoTouchRnd() * 3.0);
	MiaoSetFloatIvar(touch, "_minorRadius", r * (0.78 + MiaoTouchRnd() * 0.16));
}

/// Configura la stessa UITouch per la fase corrente.
static void MiaoTouchPhase(UITouch *touch, UIWindow *win, UIView *view, CGPoint pt,
						   UITouchPhase phase, BOOL first, CGFloat radius,
						   NSMutableString *missing) {
	MiaoSetDouble(touch, @"setTimestamp:", MiaoNow(), missing);
	MiaoSetInteger(touch, @"setPhase:", (NSInteger)phase, missing);
	MiaoSetPoint(touch, @"_setLocationInWindow:resetPrevious:", pt, first, missing);
	MiaoTouchRadius(touch, radius);
	if (first) {
		MiaoSetObj(touch, @"setWindow:", win, missing);
		MiaoSetObj(touch, @"setView:", view, missing);
		MiaoSetObj(touch, @"setGestureView:", view, nil);
		MiaoSetInteger(touch, @"setTapCount:", 1, missing);
		MiaoSetInteger(touch, @"_setPathIndex:", 1, nil);
		MiaoSetInteger(touch, @"setType:", 0, nil); // UITouchTypeDirect
		MiaoSetBool(touch, @"_setIsFirstTouchForView:", YES, nil);
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
	if (![event respondsToSelector:addSel]) return;
	((void (*)(id, SEL, id, BOOL))objc_msgSend)(event, addSel, touch, NO);

	[app sendEvent:event];
}

#pragma mark - Motore gesti

/// Tutto quello che serve per portare avanti un gesto tra un frame e il successivo.
@interface MiaoGesture : NSObject
@property (nonatomic, strong) UITouch *touch;
@property (nonatomic, strong) UIWindow *win;
@property (nonatomic, strong) UIView *view;
@property (nonatomic, strong) NSArray<NSValue *> *points;
@property (nonatomic) NSTimeInterval step;
@property (nonatomic) CGFloat radius;
@property (nonatomic, copy) void (^done)(void);
@end

@implementation MiaoGesture
@end

static BOOL MiaoTouchAPIReady(NSString **why) {
	UIApplication *app = UIApplication.sharedApplication;
	if (![app respondsToSelector:NSSelectorFromString(@"_touchesEvent")]) {
		if (why) *why = @"no _touchesEvent";
		return NO;
	}
	id ev = ((id (*)(id, SEL))objc_msgSend)(app, NSSelectorFromString(@"_touchesEvent"));
	if (![ev respondsToSelector:NSSelectorFromString(@"_addTouch:forDelayedDelivery:")]) {
		if (why) *why = @"no _addTouch:";
		return NO;
	}
	return YES;
}

static UITouch *MiaoNewTouch(UIView *view) {
	SEL initInView = NSSelectorFromString(@"initInView:");
	if ([UITouch instancesRespondToSelector:initInView])
		return ((id (*)(id, SEL, id))objc_msgSend)([UITouch alloc], initInView, view);
	return [[UITouch alloc] init];
}

/**
 Manda i punti restanti uno per giro di runloop. Le fasi devono stare su giri
 distinti: se le accodiamo tutte subito i gesture recognizer non avanzano e
 UIScrollView non calcola nessuna velocita'.
 */
static void MiaoGestureAdvance(MiaoGesture *g, NSInteger idx) {
	if (!g.points.count) return;
	/* Se la view sparisce a metà gesto (scheda chiusa, pagina ricaricata) non
	   insistiamo: un dito vero verrebbe annullato, non teletrasportato. */
	if (!g.view.window) {
		CGPoint at = g.points[MAX((NSInteger)0, MIN(idx, (NSInteger)g.points.count - 1))].CGPointValue;
		MiaoTouchPhase(g.touch, g.win, g.view, at, UITouchPhaseCancelled, NO, g.radius, nil);
		MiaoSendTouch(g.touch);
		if (g.done) g.done();
		return;
	}
	if (idx >= (NSInteger)g.points.count) {
		CGPoint last = g.points.lastObject.CGPointValue;
		MiaoTouchPhase(g.touch, g.win, g.view, last, UITouchPhaseEnded, NO, g.radius, nil);
		MiaoSendTouch(g.touch);
		if (g.done) g.done();
		return;
	}
	CGPoint p = g.points[idx].CGPointValue;
	MiaoTouchPhase(g.touch, g.win, g.view, p, UITouchPhaseMoved, NO, g.radius, nil);
	MiaoSendTouch(g.touch);

	// il digitizer non consegna a intervalli perfetti: +/-20% di scarto
	NSTimeInterval wait = g.step * (0.8 + MiaoRand01() * 0.4);
	dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(wait * NSEC_PER_SEC)),
				   dispatch_get_main_queue(), ^{
		MiaoGestureAdvance(g, idx + 1);
	});
}

static BOOL MiaoRunGesture(CGPoint start, NSArray<NSValue *> *movePoints,
						   NSTimeInterval totalTime, NSString *label, BOOL isTap,
						   NSString **why, void (^done)(void)) {
	UIWindow *win = MiaoActiveWindow();
	if (!win) {
		if (why) *why = @"no window";
		return NO;
	}
	UIView *view = [win hitTest:start withEvent:nil];
	if (!view) {
		if (why) *why = @"no hitTest";
		return NO;
	}
	if (!MiaoTouchAPIReady(why)) return NO;

	UITouch *touch = MiaoNewTouch(view);
	if (!touch) {
		if (why) *why = @"no UITouch";
		return NO;
	}

	MiaoGesture *g = [MiaoGesture new];
	g.touch = touch;
	g.win = win;
	g.view = view;
	g.points = movePoints;
	g.step = movePoints.count ? totalTime / (double)movePoints.count : totalTime;
	/* Raggio diverso per sessione: 7-16 pt, non sempre ~8.5-14.5 uguale. */
	g.radius = 7.0 + (CGFloat)MiaoTouchRnd() * 9.0;
	g.done = done;

	NSMutableString *missing = [NSMutableString string];
	MiaoTouchPhase(touch, win, view, start, UITouchPhaseBegan, YES, g.radius, missing);
	if (isTap) {
		MiaoSetBool(touch, @"setIsTap:", YES, nil);
		MiaoSetBool(touch, @"_setIsTapToClick:", YES, nil);
	}
	if (why) *why = missing.length ? [missing copy] : @"ok";
	NSLog(@"[MiaoUIK] %@ start=(%.0f,%.0f) n=%lu t=%.0fms view=%@ missing=[%@]",
		  label, start.x, start.y, (unsigned long)movePoints.count, totalTime * 1000.0,
		  NSStringFromClass([view class]), missing.length ? missing : @"-");

	MiaoSendTouch(touch);
	dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(g.step * NSEC_PER_SEC)),
				   dispatch_get_main_queue(), ^{
		MiaoGestureAdvance(g, 0);
	});
	return YES;
}

#pragma mark - Gesti pubblici

BOOL MiaoUIKitHumanTap(CGPoint winPt, NSString **why) {
	if (![NSThread isMainThread]) {
		__block BOOL ok = NO;
		__block NSString *inner = nil;
		dispatch_sync(dispatch_get_main_queue(), ^{ ok = MiaoUIKitHumanTap(winPt, &inner); });
		if (why) *why = inner;
		return ok;
	}

	/* Hold e drift cambiano con il seed: 40-180 ms, drift 0.5-3.5 pt.
	   Un tocco sempre identico e' riconoscibile quanto un delay fisso. */
	NSTimeInterval hold = 0.040 + MiaoTouchRnd() * 0.140;
	CGFloat drift = 0.5 + (CGFloat)MiaoTouchRnd() * 3.0;
	CGPoint d1 = CGPointMake(winPt.x + MiaoTouchJitter(drift), winPt.y + MiaoTouchJitter(drift));
	CGPoint d2 = CGPointMake(d1.x + MiaoTouchJitter(drift * 0.7), d1.y + MiaoTouchJitter(drift * 0.7));
	NSInteger nMove = 1 + (NSInteger)(MiaoTouchRnd() * 3); // 1-3 micro punti
	NSMutableArray *pts = [NSMutableArray array];
	CGPoint cur = d1;
	[pts addObject:[NSValue valueWithCGPoint:cur]];
	for (NSInteger i = 1; i < nMove; i++) {
		cur = CGPointMake(cur.x + MiaoTouchJitter(drift * 0.5), cur.y + MiaoTouchJitter(drift * 0.5));
		[pts addObject:[NSValue valueWithCGPoint:cur]];
	}
	if (nMove < 2) [pts addObject:[NSValue valueWithCGPoint:d2]];
	return MiaoRunGesture(winPt, pts, hold, @"tap", YES, why, nil);
}

BOOL MiaoUIKitSwipe(CGPoint from, CGPoint to, NSTimeInterval duration,
					NSString **why, void (^done)(void)) {
	if (![NSThread isMainThread]) {
		__block BOOL ok = NO;
		__block NSString *inner = nil;
		dispatch_sync(dispatch_get_main_queue(), ^{
			ok = MiaoUIKitSwipe(from, to, duration, &inner, done);
		});
		if (why) *why = inner;
		return ok;
	}

	duration = MAX(0.09, MIN(1.6, duration));
	NSInteger steps = MAX(4, (NSInteger)llround(duration / 0.016));

	CGFloat dx = to.x - from.x, dy = to.y - from.y;
	CGFloat len = sqrt(dx * dx + dy * dy);
	CGFloat px = len > 0.5 ? -dy / len : 0;   // normale al movimento
	CGFloat py = len > 0.5 ? dx / len : 0;
	CGFloat wobble = 0.7 + (CGFloat)MiaoRand01() * 2.6;
	CGFloat phase = (CGFloat)MiaoRand01() * (CGFloat)(2 * M_PI);

	NSMutableArray<NSValue *> *pts = [NSMutableArray arrayWithCapacity:(NSUInteger)steps];
	for (NSInteger i = 1; i <= steps; i++) {
		double t = (double)i / (double)steps;
		/* Profilo di velocita': parte da fermo e viene rilasciato ancora in
		   corsa. E' cosi' che nasce l'inerzia: se il dito si fermasse prima di
		   staccarsi la pagina non scorrerebbe oltre e si vedrebbe subito che
		   non e' una persona. */
		double e = pow(t, 1.32);
		CGFloat x = from.x + dx * e + px * (CGFloat)sin(phase + t * M_PI * 1.4) * wobble + MiaoJitter(0.35);
		CGFloat y = from.y + dy * e + py * (CGFloat)sin(phase + t * M_PI * 1.4) * wobble + MiaoJitter(0.35);
		[pts addObject:[NSValue valueWithCGPoint:CGPointMake(x, y)]];
	}
	return MiaoRunGesture(from, pts, duration, @"swipe", NO, why, done);
}
