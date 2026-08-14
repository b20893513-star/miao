#import "TouchSim.h"
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
};
enum {
	kIOHIDEventFieldDigitizerMajorRadius = (kIOHIDEventTypeDigitizer << 16) | 0x0B,
	kIOHIDEventFieldDigitizerMinorRadius = (kIOHIDEventTypeDigitizer << 16) | 0x0C,
};

static IOHIDEventRef (*p_CreateDigitizerEvent)(CFAllocatorRef, uint64_t, uint32_t, uint32_t, uint32_t, uint32_t, uint32_t, IOHIDFloat, IOHIDFloat, IOHIDFloat, IOHIDFloat, IOHIDFloat, boolean_t, boolean_t, IOOptionBits);
static IOHIDEventRef (*p_CreateDigitizerFingerEvent)(CFAllocatorRef, uint64_t, uint32_t, uint32_t, uint32_t, IOHIDFloat, IOHIDFloat, IOHIDFloat, IOHIDFloat, IOHIDFloat, boolean_t, boolean_t, IOOptionBits);
static void (*p_AppendEvent)(IOHIDEventRef, IOHIDEventRef, IOOptionBits);
static void (*p_SetFloatValue)(IOHIDEventRef, uint32_t, IOHIDFloat);
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
		p_SetSenderID = (typeof(p_SetSenderID))dlsym(iokit, "IOHIDEventSetSenderID");
		p_ClientCreate = (typeof(p_ClientCreate))dlsym(iokit, "IOHIDEventSystemClientCreate");
		p_ClientDispatch = (typeof(p_ClientDispatch))dlsym(iokit, "IOHIDEventSystemClientDispatchEvent");
		ok = p_CreateDigitizerEvent && p_CreateDigitizerFingerEvent && p_AppendEvent && p_ClientCreate && p_ClientDispatch;
	});
	return ok;
}

static void MiaoDispatchDigitizer(IOHIDFloat nx, IOHIDFloat ny, BOOL touching) {
	if (!MiaoLoadIOHID()) return;

	uint64_t time = mach_absolute_time();
	uint32_t mask = (uint32_t)(kIOHIDDigitizerEventRange | kIOHIDDigitizerEventTouch | kIOHIDDigitizerEventPosition);

	IOHIDEventRef parent = p_CreateDigitizerEvent(
		kCFAllocatorDefault, time, (uint32_t)kIOHIDDigitizerTransducerTypeHand,
		0, 0, mask, 0,
		nx, ny, 0, 0, 0,
		touching, touching, 0);
	if (!parent) return;

	IOHIDEventRef child = p_CreateDigitizerFingerEvent(
		kCFAllocatorDefault, time,
		1, 1, mask,
		nx, ny, 0, 0, 0,
		touching, touching, 0);
	if (!child) {
		CFRelease(parent);
		return;
	}

	if (p_SetFloatValue) {
		p_SetFloatValue(child, (uint32_t)kIOHIDEventFieldDigitizerMajorRadius, 0.05f);
		p_SetFloatValue(child, (uint32_t)kIOHIDEventFieldDigitizerMinorRadius, 0.05f);
	}

	p_AppendEvent(parent, child, 0);
	CFRelease(child);

	if (p_SetSenderID) {
		p_SetSenderID(parent, 0x000000010000027FULL);
	}

	static IOHIDEventSystemClientRef client = NULL;
	if (!client) client = p_ClientCreate(kCFAllocatorDefault);
	if (client) p_ClientDispatch(client, parent);

	// Soft enqueue su UIApplication se disponibile (un solo evento, non spam)
	id app = [UIApplication sharedApplication];
	SEL sel = NSSelectorFromString(@"_enqueueHIDEvent:");
	if (app && [app respondsToSelector:sel]) {
		((void (*)(id, SEL, IOHIDEventRef))objc_msgSend)(app, sel, parent);
	}

	CFRelease(parent);
}

extern "C" void MiaoPerformTapWithDuration(CGFloat x, CGFloat y, NSTimeInterval duration) {
	CGRect b = UIScreen.mainScreen.bounds;
	if (b.size.width < 1 || b.size.height < 1) {
		b = CGRectMake(0, 0, 414, 896);
	}
	// UNA sola modalita: coordinate normalizzate 0..1
	IOHIDFloat nx = (IOHIDFloat)(x / b.size.width);
	IOHIDFloat ny = (IOHIDFloat)(y / b.size.height);
	nx = MAX(0.f, MIN(1.f, nx));
	ny = MAX(0.f, MIN(1.f, ny));

	NSLog(@"[Miao] soft tap norm=(%.3f, %.3f) from %@", nx, ny, NSBundle.mainBundle.bundleIdentifier ?: @"?");
	MiaoDispatchDigitizer(nx, ny, YES);
	useconds_t us = (useconds_t)MAX(40000.0, duration * 1000000.0);
	usleep(us);
	MiaoDispatchDigitizer(nx, ny, NO);
}

extern "C" void MiaoPerformTap(CGFloat x, CGFloat y) {
	MiaoPerformTapWithDuration(x, y, 0.06);
}
