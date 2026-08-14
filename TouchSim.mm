#import "TouchSim.h"
#import <UIKit/UIKit.h>
#import <objc/runtime.h>
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
};
enum {
	kIOHIDEventFieldDigitizerX = (kIOHIDEventTypeDigitizer << 16) | 0,
	kIOHIDEventFieldDigitizerY = (kIOHIDEventTypeDigitizer << 16) | 1,
	kIOHIDEventFieldDigitizerMajorRadius = (kIOHIDEventTypeDigitizer << 16) | 0x0B,
	kIOHIDEventFieldDigitizerMinorRadius = (kIOHIDEventTypeDigitizer << 16) | 0x0C,
	kIOHIDEventFieldDigitizerPressure = (kIOHIDEventTypeDigitizer << 16) | 0x0E,
};

static IOHIDEventRef (*p_CreateDigitizerEvent)(CFAllocatorRef, uint64_t, uint32_t, uint32_t, uint32_t, uint32_t, uint32_t, IOHIDFloat, IOHIDFloat, IOHIDFloat, IOHIDFloat, IOHIDFloat, boolean_t, boolean_t, IOOptionBits);
static IOHIDEventRef (*p_CreateDigitizerFingerEvent)(CFAllocatorRef, uint64_t, uint32_t, uint32_t, uint32_t, IOHIDFloat, IOHIDFloat, IOHIDFloat, IOHIDFloat, IOHIDFloat, boolean_t, boolean_t, IOOptionBits);
static void (*p_AppendEvent)(IOHIDEventRef, IOHIDEventRef, IOOptionBits);
static void (*p_SetFloatValue)(IOHIDEventRef, uint32_t, IOHIDFloat);
static void (*p_SetIntegerValue)(IOHIDEventRef, uint32_t, CFIndex);
static void (*p_SetSenderID)(IOHIDEventRef, uint64_t);
static IOHIDEventSystemClientRef (*p_ClientCreate)(CFAllocatorRef);
static void (*p_ClientDispatch)(IOHIDEventSystemClientRef, IOHIDEventRef);

static bool MiaoLoadIOHID(void) {
	static dispatch_once_t onceToken;
	static bool ok = false;
	dispatch_once(&onceToken, ^{
		void *iokit = dlopen("/System/Library/Frameworks/IOKit.framework/IOKit", RTLD_LAZY);
		if (!iokit) return;
		p_CreateDigitizerEvent = (typeof(p_CreateDigitizerEvent))dlsym(iokit, "IOHIDEventCreateDigitizerEvent");
		p_CreateDigitizerFingerEvent = (typeof(p_CreateDigitizerFingerEvent))dlsym(iokit, "IOHIDEventCreateDigitizerFingerEvent");
		p_AppendEvent = (typeof(p_AppendEvent))dlsym(iokit, "IOHIDEventAppendEvent");
		p_SetFloatValue = (typeof(p_SetFloatValue))dlsym(iokit, "IOHIDEventSetFloatValue");
		p_SetIntegerValue = (typeof(p_SetIntegerValue))dlsym(iokit, "IOHIDEventSetIntegerValue");
		p_SetSenderID = (typeof(p_SetSenderID))dlsym(iokit, "IOHIDEventSetSenderID");
		p_ClientCreate = (typeof(p_ClientCreate))dlsym(iokit, "IOHIDEventSystemClientCreate");
		p_ClientDispatch = (typeof(p_ClientDispatch))dlsym(iokit, "IOHIDEventSystemClientDispatchEvent");
		ok = p_CreateDigitizerEvent && p_CreateDigitizerFingerEvent && p_AppendEvent && p_ClientCreate && p_ClientDispatch;
	});
	return ok;
}

static void MiaoEnqueueOnUIApp(IOHIDEventRef event) {
	Class cls = NSClassFromString(@"UIApplication");
	id app = [cls sharedApplication];
	if (!app) return;
	SEL sel = NSSelectorFromString(@"_enqueueHIDEvent:");
	if ([app respondsToSelector:sel]) {
		void (*fn)(id, SEL, IOHIDEventRef) = (void (*)(id, SEL, IOHIDEventRef))objc_msgSend;
		fn(app, sel, event);
	}
}

static void MiaoDispatchOne(IOHIDFloat x, IOHIDFloat y, BOOL touching, uint64_t sender) {
	if (!MiaoLoadIOHID()) return;

	uint64_t time = mach_absolute_time();
	uint32_t mask = (uint32_t)(kIOHIDDigitizerEventRange | kIOHIDDigitizerEventTouch | kIOHIDDigitizerEventPosition);

	IOHIDEventRef parent = p_CreateDigitizerEvent(
		kCFAllocatorDefault, time, (uint32_t)kIOHIDDigitizerTransducerTypeHand,
		1 /*transducerIndex*/, 1 /*identity*/, mask, 0 /*button*/,
		x, y, 0, 0, 0,
		touching, touching, 0);
	if (!parent) return;

	IOHIDEventRef child = p_CreateDigitizerFingerEvent(
		kCFAllocatorDefault, time,
		1 /*index*/, 2 /*identity*/, mask,
		x, y, 0.0f, 0.0f, touching ? 1.0f : 0.0f,
		touching, touching, 0);
	if (!child) {
		CFRelease(parent);
		return;
	}

	if (p_SetFloatValue) {
		p_SetFloatValue(child, kIOHIDEventFieldDigitizerMajorRadius, 0.04f);
		p_SetFloatValue(child, kIOHIDEventFieldDigitizerMinorRadius, 0.04f);
		p_SetFloatValue(child, kIOHIDEventFieldDigitizerPressure, touching ? 0.5f : 0.0f);
		p_SetFloatValue(parent, kIOHIDEventFieldDigitizerX, x);
		p_SetFloatValue(parent, kIOHIDEventFieldDigitizerY, y);
	}

	p_AppendEvent(parent, child, 0);
	CFRelease(child);

	if (p_SetSenderID) p_SetSenderID(parent, sender);

	static IOHIDEventSystemClientRef client = NULL;
	if (!client && p_ClientCreate) client = p_ClientCreate(kCFAllocatorDefault);
	if (client && p_ClientDispatch) p_ClientDispatch(client, parent);

	MiaoEnqueueOnUIApp(parent);
	CFRelease(parent);
}

static void MiaoFireModes(CGFloat px, CGFloat py, BOOL touching) {
	CGRect bounds = UIScreen.mainScreen.bounds;
	CGFloat scale = UIScreen.mainScreen.scale;
	if (bounds.size.width < 1 || bounds.size.height < 1) {
		bounds = CGRectMake(0, 0, 414, 896);
		scale = 3;
	}

	// Mode A: normalizzate 0..1 (spesso richiesto su iOS 15+)
	IOHIDFloat nx = (IOHIDFloat)(px / bounds.size.width);
	IOHIDFloat ny = (IOHIDFloat)(py / bounds.size.height);
	// Mode B: points
	IOHIDFloat ptX = (IOHIDFloat)px;
	IOHIDFloat ptY = (IOHIDFloat)py;
	// Mode C: pixels
	IOHIDFloat pixX = (IOHIDFloat)(px * scale);
	IOHIDFloat pixY = (IOHIDFloat)(py * scale);

	uint64_t senders[] = {
		0x000000010000027FULL,
		0x8000000800000277ULL,
		0x0000000000000000ULL,
	};

	for (int s = 0; s < 3; s++) {
		MiaoDispatchOne(nx, ny, touching, senders[s]);
		MiaoDispatchOne(ptX, ptY, touching, senders[s]);
		MiaoDispatchOne(pixX, pixY, touching, senders[s]);
	}
}

extern "C" void MiaoPerformTapWithDuration(CGFloat x, CGFloat y, NSTimeInterval duration) {
	NSLog(@"[Miao] HID tap (%.1f, %.1f) in %@", x, y, NSBundle.mainBundle.bundleIdentifier ?: @"?");
	MiaoFireModes(x, y, YES);
	useconds_t us = (useconds_t)MAX(30000.0, duration * 1000000.0);
	usleep(us);
	MiaoFireModes(x, y, NO);
}

extern "C" void MiaoPerformTap(CGFloat x, CGFloat y) {
	MiaoPerformTapWithDuration(x, y, 0.08);
}
