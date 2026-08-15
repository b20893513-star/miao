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

// IOHIDEventFieldBase(kIOHIDEventTypeDigitizer) = 11 << 16 = 720896, poi in ordine:
// 0 X, 1 Y, 2 Z, 3 ButtonMask, 4 Type, 5 Index, 6 Identity, 7 EventMask, 8 Range,
// 9 Touch, 10 Pressure, 11 AuxPressure, 12 Twist, 13 TiltX, 14 TiltY, 15 Altitude,
// 16 Azimuth, 17 Quality, 18 Density, 19 Irregularity, 20 MajorRadius, 21 MinorRadius,
// 22 Collection, 23 CollectionChord, 24 ChildEventMask, 25 IsDisplayIntegrated
#define MIAO_DIG_FIELD(off) ((uint32_t)((kIOHIDEventTypeDigitizer << 16) | (off)))
enum {
	kMiaoFieldEventMask = MIAO_DIG_FIELD(7),
	kMiaoFieldRange = MIAO_DIG_FIELD(8),
	kMiaoFieldTouch = MIAO_DIG_FIELD(9),
	kMiaoFieldPressure = MIAO_DIG_FIELD(10),
	kMiaoFieldMajorRadius = MIAO_DIG_FIELD(20),
	kMiaoFieldMinorRadius = MIAO_DIG_FIELD(21),
	kMiaoFieldIsDisplayIntegrated = MIAO_DIG_FIELD(25),
};
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

		ok = p_CreateDigitizerEvent && p_CreateDigitizerFingerEvent && p_AppendEvent
			&& p_ClientCreate && p_ClientDispatch;
	});
	return ok;
}

/// SimulateTouch usa options -268435456 per i campi digitizer su iOS7+
static void MiaoSetInt(IOHIDEventRef ev, uint32_t field, CFIndex val) {
	if (p_SetIntegerValueWithOptions)
		p_SetIntegerValueWithOptions(ev, field, val, (IOOptionBits)-268435456);
	else if (p_SetIntegerValue)
		p_SetIntegerValue(ev, field, val);
}

static void MiaoNotifyUserEvent(void) {
	Class cls = NSClassFromString(@"BKUserEventTimer");
	if (!cls) return;
	SEL sharedSel = NSSelectorFromString(@"sharedInstance");
	if (![cls respondsToSelector:sharedSel]) return;
	id shared = ((id (*)(id, SEL))objc_msgSend)(cls, sharedSel);
	if (!shared) return;
	SEL onDisplay = NSSelectorFromString(@"userEventOccurredOnDisplay:");
	SEL plain = NSSelectorFromString(@"userEventOccurred");
	if ([shared respondsToSelector:onDisplay])
		((void (*)(id, SEL, id))objc_msgSend)(shared, onDisplay, nil);
	else if ([shared respondsToSelector:plain])
		((void (*)(id, SEL))objc_msgSend)(shared, plain);
}

static id MiaoLCDDisplay(void) {
	Class wsCls = NSClassFromString(@"CAWindowServer");
	if (!wsCls) return nil;
	SEL serverSel = NSSelectorFromString(@"serverIfRunning");
	if (![wsCls respondsToSelector:serverSel]) return nil;
	id server = ((id (*)(id, SEL))objc_msgSend)(wsCls, serverSel);
	if (!server) return nil;

	SEL byName = NSSelectorFromString(@"displayWithName:");
	if ([server respondsToSelector:byName]) {
		id d = ((id (*)(id, SEL, id))objc_msgSend)(server, byName, @"LCD");
		if (d) return d;
	}
	SEL displaysSel = NSSelectorFromString(@"displays");
	if ([server respondsToSelector:displaysSel]) {
		NSArray *ds = ((id (*)(id, SEL))objc_msgSend)(server, displaysSel);
		return ds.firstObject;
	}
	return nil;
}

/// Dimensione display in points (bounds CAWindowServer e' in pixel).
static CGSize MiaoDisplaySizePoints(void) {
	id display = MiaoLCDDisplay();
	if (display) {
		SEL boundsSel = NSSelectorFromString(@"bounds");
		if ([display respondsToSelector:boundsSel]) {
			CGRect b = ((CGRect (*)(id, SEL))objc_msgSend)(display, boundsSel);
			CGFloat w = MIN(b.size.width, b.size.height);
			CGFloat h = MAX(b.size.width, b.size.height);
			CGFloat scale = 1.0;
			if (w == 1242 || w == 1080 || w == 1170 || w == 1284 || w == 1179 || w == 1290) scale = 3.0;
			else if (w == 640 || w == 750 || w == 828 || w == 1536) scale = 2.0;
			w /= scale;
			h /= scale;
			if (w > 100 && h > 100) return CGSizeMake(w, h);
		}
	}
	return CGSizeMake(414, 896);
}

static uint32_t MiaoContextIdAtScreenPoint(CGFloat x, CGFloat y) {
	id display = MiaoLCDDisplay();
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
		SEL sharedSel = NSSelectorFromString(@"sharedInstance");
		id shared = [hidCls respondsToSelector:sharedSel]
			? ((id (*)(id, SEL))objc_msgSend)(hidCls, sharedSel) : nil;
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

/// Coordinate finger NORMALIZZATE 0..1 (come SimulateTouch: rX = x/width*scale).
static void MiaoDispatchDigitizer(IOHIDFloat nx, IOHIDFloat ny, BOOL down, uint32_t contextId) {
	if (!MiaoLoadIOHID()) return;

	uint64_t time = mach_absolute_time();
	int touch = down ? 1 : 0;
	uint32_t childMask = (uint32_t)(kIOHIDDigitizerEventRange | kIOHIDDigitizerEventTouch);
	uint32_t handMask = childMask | (uint32_t)kIOHIDDigitizerEventIdentity;

	IOHIDEventRef parent = p_CreateDigitizerEvent(
		kCFAllocatorDefault, time, (uint32_t)kIOHIDDigitizerTransducerTypeHand,
		0, 1, 0, 0,
		0, 0, 0, 0, 0,
		0, 0, 0);
	if (!parent) return;

	MiaoSetInt(parent, (uint32_t)kMiaoFieldIsDisplayIntegrated, 1);
	MiaoSetInt(parent, (uint32_t)kIOHIDEventFieldBuiltIn, 1);

	IOHIDEventRef child = p_CreateDigitizerFingerEvent(
		kCFAllocatorDefault, time,
		1, 2, childMask,
		nx, ny, 0,
		down ? 0.7f : 0.f, 0,
		touch, touch, 0);
	if (!child) {
		CFRelease(parent);
		return;
	}
	if (p_SetFloatValue) {
		p_SetFloatValue(child, (uint32_t)kMiaoFieldMajorRadius, down ? 5.f : 0.f);
		p_SetFloatValue(child, (uint32_t)kMiaoFieldMinorRadius, down ? 4.6f : 0.f);
		p_SetFloatValue(child, (uint32_t)kMiaoFieldPressure, down ? 0.7f : 0.f);
	}
	p_AppendEvent(parent, child, 0);
	CFRelease(child);

	// Campi hand richiesti da iOS7+ (SimulateTouch)
	MiaoSetInt(parent, (uint32_t)kMiaoFieldEventMask, handMask);
	MiaoSetInt(parent, (uint32_t)kMiaoFieldRange, touch);
	MiaoSetInt(parent, (uint32_t)kMiaoFieldTouch, touch);

	if (p_SetSenderID) p_SetSenderID(parent, 0x000000010000027FULL);
	MiaoSendEvent(parent, contextId);
}

static void MiaoTapNorm(CGFloat nx, CGFloat ny, uint32_t ctx) {
	if (nx < 0.005) nx = 0.005;
	if (nx > 0.995) nx = 0.995;
	if (ny < 0.005) ny = 0.005;
	if (ny > 0.995) ny = 0.995;

	MiaoDispatchDigitizer((IOHIDFloat)nx, (IOHIDFloat)ny, YES, ctx);
	usleep(90000);
	MiaoDispatchDigitizer((IOHIDFloat)nx, (IOHIDFloat)ny, NO, ctx);
	usleep(40000);
}

void MiaoPerformHumanTapNorm(CGFloat nx, CGFloat ny) {
	NSLog(@"[MiaoHID] tapNorm (%.3f,%.3f)", nx, ny);
	MiaoTapNorm(nx, ny, 0);
}

void MiaoPerformHumanTapScreen(CGFloat x, CGFloat y) {
	if (!MiaoLoadIOHID()) {
		NSLog(@"[MiaoHID] IOHID load fail");
		return;
	}
	CGSize scr = MiaoDisplaySizePoints();
	if (x < 1) x = 1;
	if (y < 1) y = 1;
	if (x > scr.width - 1) x = scr.width - 1;
	if (y > scr.height - 1) y = scr.height - 1;

	uint32_t ctx = MiaoContextIdAtScreenPoint(x, y);
	NSLog(@"[MiaoHID] tapScreen (%.0f,%.0f) scr=%.0fx%.0f ctx=%u inject=%d bks=%d",
		x, y, scr.width, scr.height, ctx,
		NSClassFromString(@"BKHIDSystemInterface") ? 1 : 0,
		p_BKSSetDigitizerInfo ? 1 : 0);

	MiaoTapNorm(x / scr.width, y / scr.height, ctx);
}
