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
		ok = p_CreateDigitizerEvent && p_CreateDigitizerFingerEvent && p_AppendEvent && p_ClientCreate && p_ClientDispatch;
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

static void MiaoSendEvent(IOHIDEventRef event) {
	if (!event) return;
	MiaoNotifyUserEvent();

	// Preferisci inject nativo backboardd se c'e'
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
	if (!client && MiaoLoadIOHID()) client = p_ClientCreate(kCFAllocatorDefault);
	if (client && p_ClientDispatch) p_ClientDispatch(client, event);
	CFRelease(event);
}

/// down=YES touch begin; down=NO lift. Coords normalizzate 0..1 (stile SimulateTouch).
static void MiaoDispatchDigitizer(IOHIDFloat nx, IOHIDFloat ny, BOOL down) {
	if (!MiaoLoadIOHID()) return;
	uint64_t time = mach_absolute_time();
	int touch = down ? 1 : 0;
	uint32_t mask = (uint32_t)(kIOHIDDigitizerEventRange | kIOHIDDigitizerEventTouch | kIOHIDDigitizerEventIdentity);
	if (!down) mask |= (uint32_t)kIOHIDDigitizerEventPosition;

	// Parent a 0,0 — le coords stanno sul finger (SimulateTouch)
	IOHIDEventRef parent = p_CreateDigitizerEvent(
		kCFAllocatorDefault, time, (uint32_t)kIOHIDDigitizerTransducerTypeHand,
		0, 1, mask, 0,
		0, 0, 0, 0, 0,
		touch, touch, 0);
	if (!parent) return;

	MiaoSetInt(parent, (uint32_t)kIOHIDEventFieldDigitizerDisplayIntegrated, 1);
	MiaoSetInt(parent, (uint32_t)kIOHIDEventFieldBuiltIn, 1);
	IOHIDEventRef child = p_CreateDigitizerFingerEvent(
		kCFAllocatorDefault, time,
		3, 2, mask,
		nx, ny, 0,
		down ? 0.8f : 0.f, 0,
		touch, touch, 0);
	if (!child) {
		CFRelease(parent);
		return;
	}
	if (p_SetFloatValue) {
		p_SetFloatValue(child, (uint32_t)kIOHIDEventFieldDigitizerMajorRadius, down ? 0.04f : 0.f);
		p_SetFloatValue(child, (uint32_t)kIOHIDEventFieldDigitizerMinorRadius, down ? 0.036f : 0.f);
		p_SetFloatValue(child, (uint32_t)kIOHIDEventFieldDigitizerPressure, down ? 0.7f : 0.f);
	}
	p_AppendEvent(parent, child, 0);
	CFRelease(child);
	if (p_SetSenderID) p_SetSenderID(parent, 0x000000010000027FULL);
	MiaoSendEvent(parent);
}

void MiaoPerformHumanTapNorm(CGFloat nx, CGFloat ny) {
	if (nx < 0.01f) nx = 0.01f;
	if (nx > 0.99f) nx = 0.99f;
	if (ny < 0.02f) ny = 0.02f;
	if (ny > 0.99f) ny = 0.99f;

	NSLog(@"[MiaoHID] tapNorm (%.3f,%.3f)", nx, ny);

	// Un solo down→up pulito (meno jitter = meno miss)
	MiaoDispatchDigitizer((IOHIDFloat)nx, (IOHIDFloat)ny, YES);
	usleep(90000);
	MiaoDispatchDigitizer((IOHIDFloat)nx, (IOHIDFloat)ny, NO);
	usleep(40000);
}
