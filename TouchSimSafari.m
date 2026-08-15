#import "TouchSimSafari.h"
#import <UIKit/UIKit.h>
#import <objc/runtime.h>
#import <objc/message.h>
#import <dlfcn.h>
#import <mach/mach_time.h>
#import <unistd.h>

typedef float IOHIDFloat;
typedef int boolean_t;
typedef uint32_t IOOptionBits;
typedef struct __IOHIDEvent *IOHIDEventRef;
typedef struct __IOHIDEventSystemClient *IOHIDEventSystemClientRef;

enum { kIOHIDEventTypeDigitizer = 11 };
enum { kIOHIDDigitizerTransducerTypeHand = 3 };
enum {
	kIOHIDDigitizerEventRange = 1 << 0,
	kIOHIDDigitizerEventTouch = 1 << 1,
	kIOHIDDigitizerEventPosition = 1 << 2,
	kIOHIDDigitizerEventIdentity = 1 << 5,
};
// iolate / IOKit iOS7+: DisplayIntegrated = base+25 = 720921
enum { kIOHIDEventFieldDigitizerDisplayIntegrated = 720921 };
enum {
	kIOHIDEventFieldDigitizerMajorRadius = (kIOHIDEventTypeDigitizer << 16) | 0x0B,
	kIOHIDEventFieldDigitizerMinorRadius = (kIOHIDEventTypeDigitizer << 16) | 0x0C,
};

static IOHIDEventRef (*p_CreateDigitizerEvent)(CFAllocatorRef, uint64_t, uint32_t, uint32_t, uint32_t, uint32_t, uint32_t, IOHIDFloat, IOHIDFloat, IOHIDFloat, IOHIDFloat, IOHIDFloat, boolean_t, boolean_t, IOOptionBits);
static IOHIDEventRef (*p_CreateDigitizerFingerEvent)(CFAllocatorRef, uint64_t, uint32_t, uint32_t, uint32_t, IOHIDFloat, IOHIDFloat, IOHIDFloat, IOHIDFloat, IOHIDFloat, boolean_t, boolean_t, IOOptionBits);
static void (*p_AppendEvent)(IOHIDEventRef, IOHIDEventRef, IOOptionBits);
static void (*p_SetFloatValue)(IOHIDEventRef, uint32_t, IOHIDFloat);
static void (*p_SetIntegerValue)(IOHIDEventRef, uint32_t, CFIndex);
static void (*p_SetSenderID)(IOHIDEventRef, uint64_t);
static void (*p_BKSSetDigitizerInfo)(IOHIDEventRef, uint32_t, uint8_t, uint8_t, CFStringRef, CFTimeInterval, float);

static bool MiaoSafariLoad(void) {
	static dispatch_once_t once;
	static bool ok = false;
	dispatch_once(&once, ^{
		void *iokit = dlopen("/System/Library/Frameworks/IOKit.framework/IOKit", RTLD_LAZY);
		if (!iokit) iokit = dlopen("/System/Library/PrivateFrameworks/IOKit.framework/IOKit", RTLD_LAZY);
		if (!iokit) return;
		p_CreateDigitizerEvent = (typeof(p_CreateDigitizerEvent))dlsym(iokit, "IOHIDEventCreateDigitizerEvent");
		p_CreateDigitizerFingerEvent = (typeof(p_CreateDigitizerFingerEvent))dlsym(iokit, "IOHIDEventCreateDigitizerFingerEvent");
		p_AppendEvent = (typeof(p_AppendEvent))dlsym(iokit, "IOHIDEventAppendEvent");
		p_SetFloatValue = (typeof(p_SetFloatValue))dlsym(iokit, "IOHIDEventSetFloatValue");
		p_SetIntegerValue = (typeof(p_SetIntegerValue))dlsym(iokit, "IOHIDEventSetIntegerValue");
		p_SetSenderID = (typeof(p_SetSenderID))dlsym(iokit, "IOHIDEventSetSenderID");

		void *bks = dlopen("/System/Library/PrivateFrameworks/BackBoardServices.framework/BackBoardServices", RTLD_LAZY);
		if (bks)
			p_BKSSetDigitizerInfo = (typeof(p_BKSSetDigitizerInfo))dlsym(bks, "BKSHIDEventSetDigitizerInfo");

		ok = p_CreateDigitizerEvent && p_CreateDigitizerFingerEvent && p_AppendEvent && p_BKSSetDigitizerInfo;
	});
	return ok;
}

static UIWindow *MiaoKeyWindow(void) {
	UIWindow *win = nil;
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations"
	win = UIApplication.sharedApplication.keyWindow;
#pragma clang diagnostic pop
	if (win) return win;
	for (UIScene *sc in UIApplication.sharedApplication.connectedScenes) {
		if (![sc isKindOfClass:[UIWindowScene class]]) continue;
		for (UIWindow *w in ((UIWindowScene *)sc).windows) {
			if (w.isKeyWindow) return w;
		}
		if (((UIWindowScene *)sc).windows.count)
			return ((UIWindowScene *)sc).windows.firstObject;
	}
	return nil;
}

static uint32_t MiaoWindowContextId(UIWindow *win) {
	if (!win) return 0;
	@try {
		id v = [win valueForKey:@"_contextId"];
		if ([v respondsToSelector:@selector(unsignedIntValue)])
			return [v unsignedIntValue];
	} @catch (NSException *ex) { (void)ex; }
	SEL sel = NSSelectorFromString(@"_contextId");
	if ([win respondsToSelector:sel]) {
		return ((uint32_t (*)(id, SEL))objc_msgSend)(win, sel);
	}
	return 0;
}

/// Coordinate FINESTRA (punti), come WebKit HIDEventGenerator — non 0..1.
static IOHIDEventRef MiaoMakeDigitizer(CGFloat x, CGFloat y, BOOL touching) {
	if (!MiaoSafariLoad()) return NULL;
	uint64_t time = mach_absolute_time();
	uint32_t mask = touching
		? (uint32_t)(kIOHIDDigitizerEventRange | kIOHIDDigitizerEventTouch | kIOHIDDigitizerEventIdentity)
		: (uint32_t)(kIOHIDDigitizerEventRange | kIOHIDDigitizerEventTouch | kIOHIDDigitizerEventPosition | kIOHIDDigitizerEventIdentity);

	IOHIDEventRef parent = p_CreateDigitizerEvent(
		kCFAllocatorDefault, time, (uint32_t)kIOHIDDigitizerTransducerTypeHand,
		0, 0, mask, 0,
		0, 0, 0, 0, 0,
		touching, touching, 0);
	if (!parent) return NULL;

	if (p_SetIntegerValue)
		p_SetIntegerValue(parent, (uint32_t)kIOHIDEventFieldDigitizerDisplayIntegrated, 1);

	IOHIDFloat fx = (IOHIDFloat)roundf((float)x);
	IOHIDFloat fy = (IOHIDFloat)roundf((float)y);

	IOHIDEventRef child = p_CreateDigitizerFingerEvent(
		kCFAllocatorDefault, time,
		2, 2, mask,
		fx, fy, 0,
		touching ? 0.f : 0.f, 0,
		touching, touching, 0);
	if (!child) {
		CFRelease(parent);
		return NULL;
	}
	if (p_SetFloatValue) {
		p_SetFloatValue(child, (uint32_t)kIOHIDEventFieldDigitizerMajorRadius, touching ? 5.f : 0.f);
		p_SetFloatValue(child, (uint32_t)kIOHIDEventFieldDigitizerMinorRadius, touching ? 5.f : 0.f);
	}
	p_AppendEvent(parent, child, 0);
	CFRelease(child);
	if (p_SetSenderID) p_SetSenderID(parent, 0x000000010000027FULL);
	return parent;
}

static BOOL MiaoEnqueue(IOHIDEventRef event) {
	if (!event || !p_BKSSetDigitizerInfo) {
		if (event) CFRelease(event);
		return NO;
	}
	UIWindow *win = MiaoKeyWindow();
	uint32_t ctx = MiaoWindowContextId(win);
	if (!ctx) {
		NSLog(@"[MiaoSafari] no contextId");
		CFRelease(event);
		return NO;
	}
	p_BKSSetDigitizerInfo(event, ctx, false, false, NULL, 0, 0);

	UIApplication *app = UIApplication.sharedApplication;
	SEL sel = NSSelectorFromString(@"_enqueueHIDEvent:");
	if (![app respondsToSelector:sel]) {
		NSLog(@"[MiaoSafari] no _enqueueHIDEvent:");
		CFRelease(event);
		return NO;
	}
	((void (*)(id, SEL, IOHIDEventRef))objc_msgSend)(app, sel, event);
	CFRelease(event);
	return YES;
}

BOOL MiaoSafariTrustedTapWindow(CGFloat x, CGFloat y) {
	if (!MiaoSafariLoad()) {
		NSLog(@"[MiaoSafari] IOHID/BKS load fail");
		return NO;
	}
	CGRect b = UIScreen.mainScreen.bounds;
	if (b.size.width < 1) b = CGRectMake(0, 0, 414, 896);
	x = MAX(2, MIN(b.size.width - 2, x));
	y = MAX(2, MIN(b.size.height - 2, y));

	NSLog(@"[MiaoSafari] trustedTap window=(%.0f,%.0f)", x, y);

	// down + up sul main runloop (come WebKitTestRunner)
	__block BOOL ok = NO;
	void (^run)(void) = ^{
		IOHIDEventRef down = MiaoMakeDigitizer(x, y, YES);
		ok = MiaoEnqueue(down);
		if (!ok) return;
		dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.07 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
			IOHIDEventRef up = MiaoMakeDigitizer(x, y, NO);
			MiaoEnqueue(up);
		});
	};
	if ([NSThread isMainThread]) run();
	else dispatch_sync(dispatch_get_main_queue(), run);
	return ok;
}
