#import "TouchSimBB.h"
#import <Foundation/Foundation.h>
#import <objc/runtime.h>
#import <objc/message.h>
#import <dlfcn.h>
#import <mach/mach_time.h>
#import <unistd.h>
#import <stdlib.h>

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
enum {
	kIOHIDEventFieldDigitizerMajorRadius = (kIOHIDEventTypeDigitizer << 16) | 0x0B,
	kIOHIDEventFieldDigitizerMinorRadius = (kIOHIDEventTypeDigitizer << 16) | 0x0C,
	kIOHIDEventFieldDigitizerPressure = (kIOHIDEventTypeDigitizer << 16) | 0x0E,
};
enum { kIOHIDEventFieldDigitizerDisplayIntegrated = 720921 };
enum { kIOHIDEventFieldBuiltIn = 4 };

static IOHIDEventRef (*p_CreateDigitizerEvent)(CFAllocatorRef, uint64_t, uint32_t, uint32_t, uint32_t, uint32_t, uint32_t, IOHIDFloat, IOHIDFloat, IOHIDFloat, IOHIDFloat, IOHIDFloat, boolean_t, boolean_t, IOOptionBits);
static IOHIDEventRef (*p_CreateDigitizerFingerEvent)(CFAllocatorRef, uint64_t, uint32_t, uint32_t, uint32_t, IOHIDFloat, IOHIDFloat, IOHIDFloat, IOHIDFloat, IOHIDFloat, boolean_t, boolean_t, IOOptionBits);
static void (*p_AppendEvent)(IOHIDEventRef, IOHIDEventRef, IOOptionBits);
static void (*p_SetFloatValue)(IOHIDEventRef, uint32_t, IOHIDFloat);
static void (*p_SetIntegerValue)(IOHIDEventRef, uint32_t, CFIndex);
static void (*p_SetIntegerValueWithOptions)(IOHIDEventRef, uint32_t, CFIndex, IOOptionBits);
static void (*p_SetSenderID)(IOHIDEventRef, uint64_t);
static IOHIDEventSystemClientRef (*p_ClientCreate)(CFAllocatorRef);
static void (*p_ClientDispatch)(IOHIDEventSystemClientRef, IOHIDEventRef);
static void (*p_BKSSetDigitizerInfo)(IOHIDEventRef, uint32_t, uint8_t, uint8_t, CFStringRef, CFTimeInterval, float);

static bool MiaoLoadIOHID(void) {
	static dispatch_once_t onceToken;
	static bool ok = false;
	dispatch_once(&onceToken, ^{
		void *iokit = dlopen("/System/Library/Frameworks/IOKit.framework/IOKit", RTLD_LAZY);
		if (!iokit) iokit = dlopen("/System/Library/PrivateFrameworks/IOKit.framework/IOKit", RTLD_LAZY);
		if (!iokit) return;
		p_CreateDigitizerEvent = (typeof(p_CreateDigitizerEvent))dlsym(iokit, "IOHIDEventCreateDigitizerEvent");
		p_CreateDigitizerFingerEvent = (typeof(p_CreateDigitizerFingerEvent))dlsym(iokit, "IOHIDEventCreateDigitizerFingerEvent");
		p_AppendEvent = (typeof(p_AppendEvent))dlsym(iokit, "IOHIDEventAppendEvent");
		p_SetFloatValue = (typeof(p_SetFloatValue))dlsym(iokit, "IOHIDEventSetFloatValue");
		p_SetIntegerValue = (typeof(p_SetIntegerValue))dlsym(iokit, "IOHIDEventSetIntegerValue");
		p_SetIntegerValueWithOptions = (typeof(p_SetIntegerValueWithOptions))dlsym(iokit, "IOHIDEventSetIntegerValueWithOptions");
		p_SetSenderID = (typeof(p_SetSenderID))dlsym(iokit, "IOHIDEventSetSenderID");
		p_ClientCreate = (typeof(p_ClientCreate))dlsym(iokit, "IOHIDEventSystemClientCreate");
		p_ClientDispatch = (typeof(p_ClientDispatch))dlsym(iokit, "IOHIDEventSystemClientDispatchEvent");

		void *bks = dlopen("/System/Library/PrivateFrameworks/BackBoardServices.framework/BackBoardServices", RTLD_LAZY);
		if (bks)
			p_BKSSetDigitizerInfo = (typeof(p_BKSSetDigitizerInfo))dlsym(bks, "BKSHIDEventSetDigitizerInfo");

		ok = p_CreateDigitizerEvent && p_CreateDigitizerFingerEvent && p_AppendEvent;
	});
	return ok;
}

static void MiaoSetInt(IOHIDEventRef ev, uint32_t field, CFIndex val) {
	if (p_SetIntegerValueWithOptions)
		p_SetIntegerValueWithOptions(ev, field, val, (IOOptionBits)-268435456);
	else if (p_SetIntegerValue)
		p_SetIntegerValue(ev, field, val);
}

static void MiaoNotifyUserEvent(void) {
	Class cls = NSClassFromString(@"BKUserEventTimer");
	if (!cls) return;
	id shared = ((id (*)(id, SEL))objc_msgSend)(cls, NSSelectorFromString(@"sharedInstance"));
	if (!shared) return;
	SEL a = NSSelectorFromString(@"userEventOccurredOnDisplay:");
	SEL b = NSSelectorFromString(@"userEventOccurred");
	if ([shared respondsToSelector:a])
		((void (*)(id, SEL, id))objc_msgSend)(shared, a, nil);
	else if ([shared respondsToSelector:b])
		((void (*)(id, SEL))objc_msgSend)(shared, b);
}

/// contextId della finestra sotto il punto (Safari se in foreground).
static uint32_t MiaoContextIdAtScreenPoint(CGFloat x, CGFloat y) {
	Class wsCls = NSClassFromString(@"CAWindowServer");
	if (!wsCls) return 0;
	SEL serverSel = NSSelectorFromString(@"serverIfRunning");
	if (![wsCls respondsToSelector:serverSel]) return 0;
	id server = ((id (*)(id, SEL))objc_msgSend)(wsCls, serverSel);
	if (!server) return 0;

	id display = nil;
	SEL byName = NSSelectorFromString(@"displayWithName:");
	if ([server respondsToSelector:byName])
		display = ((id (*)(id, SEL, id))objc_msgSend)(server, byName, @"LCD");
	if (!display) {
		SEL displaysSel = NSSelectorFromString(@"displays");
		if ([server respondsToSelector:displaysSel]) {
			NSArray *ds = ((id (*)(id, SEL))objc_msgSend)(server, displaysSel);
			display = ds.firstObject;
		}
	}
	if (!display) return 0;

	SEL ctxSel = NSSelectorFromString(@"contextIdAtPosition:");
	if (![display respondsToSelector:ctxSel]) return 0;
	return ((uint32_t (*)(id, SEL, CGPoint))objc_msgSend)(display, ctxSel, CGPointMake(x, y));
}

static void MiaoSendEvent(IOHIDEventRef event, uint32_t contextId) {
	if (!event) return;
	MiaoNotifyUserEvent();

	if (contextId && p_BKSSetDigitizerInfo)
		p_BKSSetDigitizerInfo(event, contextId, false, false, NULL, 0, 0);

	Class hidCls = NSClassFromString(@"BKHIDSystemInterface");
	if (hidCls) {
		id shared = ((id (*)(id, SEL))objc_msgSend)(hidCls, NSSelectorFromString(@"sharedInstance"));
		SEL inj = NSSelectorFromString(@"injectHIDEvent:");
		if (shared && [shared respondsToSelector:inj]) {
			((void (*)(id, SEL, IOHIDEventRef))objc_msgSend)(shared, inj, event);
			CFRelease(event);
			return;
		}
	}

	static IOHIDEventSystemClientRef client = NULL;
	if (!client && p_ClientCreate) client = p_ClientCreate(kCFAllocatorDefault);
	if (client && p_ClientDispatch) p_ClientDispatch(client, event);
	CFRelease(event);
}

/// absCoords=YES → finger in points schermo; NO → normalizzate 0..1
static void MiaoDispatchDigitizer(IOHIDFloat fx, IOHIDFloat fy, BOOL down, BOOL absCoords, uint32_t contextId) {
	if (!MiaoLoadIOHID()) return;
	uint64_t time = mach_absolute_time();
	int touch = down ? 1 : 0;
	uint32_t mask = (uint32_t)(kIOHIDDigitizerEventRange | kIOHIDDigitizerEventTouch | kIOHIDDigitizerEventIdentity);
	if (!down) mask |= (uint32_t)kIOHIDDigitizerEventPosition;

	IOHIDEventRef parent = p_CreateDigitizerEvent(
		kCFAllocatorDefault, time, (uint32_t)kIOHIDDigitizerTransducerTypeHand,
		0, 0, mask, 0,
		0, 0, 0, 0, 0,
		touch, touch, 0);
	if (!parent) return;

	MiaoSetInt(parent, (uint32_t)kIOHIDEventFieldDigitizerDisplayIntegrated, 1);
	MiaoSetInt(parent, (uint32_t)kIOHIDEventFieldBuiltIn, 1);

	IOHIDFloat px = absCoords ? (IOHIDFloat)roundf((float)fx) : fx;
	IOHIDFloat py = absCoords ? (IOHIDFloat)roundf((float)fy) : fy;

	IOHIDEventRef child = p_CreateDigitizerFingerEvent(
		kCFAllocatorDefault, time,
		2, 2, mask,
		px, py, 0,
		down ? (absCoords ? 0.f : 0.8f) : 0.f, 0,
		touch, touch, 0);
	if (!child) {
		CFRelease(parent);
		return;
	}
	if (p_SetFloatValue) {
		IOHIDFloat rad = absCoords ? (down ? 5.f : 0.f) : (down ? 0.04f : 0.f);
		p_SetFloatValue(child, (uint32_t)kIOHIDEventFieldDigitizerMajorRadius, rad);
		p_SetFloatValue(child, (uint32_t)kIOHIDEventFieldDigitizerMinorRadius, rad * 0.92f);
		if (!absCoords)
			p_SetFloatValue(child, (uint32_t)kIOHIDEventFieldDigitizerPressure, down ? 0.7f : 0.f);
	}
	p_AppendEvent(parent, child, 0);
	CFRelease(child);
	if (p_SetSenderID) p_SetSenderID(parent, 0x000000010000027FULL);
	MiaoSendEvent(parent, contextId);
}

void MiaoPerformHumanTapNorm(CGFloat nx, CGFloat ny) {
	if (nx < 0.01f) nx = 0.01f;
	if (nx > 0.99f) nx = 0.99f;
	if (ny < 0.02f) ny = 0.02f;
	if (ny > 0.99f) ny = 0.99f;

	NSLog(@"[MiaoHID] tapNorm (%.3f,%.3f)", nx, ny);
	MiaoDispatchDigitizer((IOHIDFloat)nx, (IOHIDFloat)ny, YES, NO, 0);
	usleep(90000);
	MiaoDispatchDigitizer((IOHIDFloat)nx, (IOHIDFloat)ny, NO, NO, 0);
	usleep(40000);
}

void MiaoPerformHumanTapScreen(CGFloat x, CGFloat y) {
	if (!MiaoLoadIOHID()) {
		NSLog(@"[MiaoHID] IOHID load fail");
		return;
	}
	if (x < 2) x = 2;
	if (y < 2) y = 2;

	uint32_t ctx = MiaoContextIdAtScreenPoint(x, y);
	NSLog(@"[MiaoHID] tapScreen (%.0f,%.0f) ctx=%u bks=%d hid=%d",
		x, y, ctx, p_BKSSetDigitizerInfo ? 1 : 0,
		NSClassFromString(@"BKHIDSystemInterface") ? 1 : 0);

	MiaoDispatchDigitizer((IOHIDFloat)x, (IOHIDFloat)y, YES, YES, ctx);
	usleep(100000);
	MiaoDispatchDigitizer((IOHIDFloat)x, (IOHIDFloat)y, NO, YES, ctx);
	usleep(50000);
}
