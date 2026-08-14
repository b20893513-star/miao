#import "TouchSim.h"
#import <UIKit/UIKit.h>
#import <CoreFoundation/CoreFoundation.h>
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
		if (!iokit) {
			NSLog(@"[Miao] dlopen IOKit failed");
			return;
		}
		p_CreateDigitizerEvent = (IOHIDEventRef (*)(CFAllocatorRef, uint64_t, uint32_t, uint32_t, uint32_t, uint32_t, uint32_t, IOHIDFloat, IOHIDFloat, IOHIDFloat, IOHIDFloat, IOHIDFloat, boolean_t, boolean_t, IOOptionBits))dlsym(iokit, "IOHIDEventCreateDigitizerEvent");
		p_CreateDigitizerFingerEvent = (IOHIDEventRef (*)(CFAllocatorRef, uint64_t, uint32_t, uint32_t, uint32_t, IOHIDFloat, IOHIDFloat, IOHIDFloat, IOHIDFloat, IOHIDFloat, boolean_t, boolean_t, IOOptionBits))dlsym(iokit, "IOHIDEventCreateDigitizerFingerEvent");
		p_AppendEvent = (void (*)(IOHIDEventRef, IOHIDEventRef, IOOptionBits))dlsym(iokit, "IOHIDEventAppendEvent");
		p_SetFloatValue = (void (*)(IOHIDEventRef, uint32_t, IOHIDFloat))dlsym(iokit, "IOHIDEventSetFloatValue");
		p_SetSenderID = (void (*)(IOHIDEventRef, uint64_t))dlsym(iokit, "IOHIDEventSetSenderID");
		p_ClientCreate = (IOHIDEventSystemClientRef (*)(CFAllocatorRef))dlsym(iokit, "IOHIDEventSystemClientCreate");
		p_ClientDispatch = (void (*)(IOHIDEventSystemClientRef, IOHIDEventRef))dlsym(iokit, "IOHIDEventSystemClientDispatchEvent");
		ok = p_CreateDigitizerEvent && p_CreateDigitizerFingerEvent && p_AppendEvent && p_ClientCreate && p_ClientDispatch;
		if (!ok) NSLog(@"[Miao] IOHID symbols incomplete");
	});
	return ok;
}

static void MiaoDispatchDigitizer(CGFloat x, CGFloat y, BOOL touching) {
	if (!MiaoLoadIOHID()) {
		NSLog(@"[Miao] IOHID unavailable — tap skipped");
		return;
	}

	CGFloat scale = UIScreen.mainScreen.scale;
	IOHIDFloat px = (IOHIDFloat)(x * scale);
	IOHIDFloat py = (IOHIDFloat)(y * scale);
	uint64_t time = mach_absolute_time();
	uint32_t mask = (uint32_t)(kIOHIDDigitizerEventRange | kIOHIDDigitizerEventTouch | kIOHIDDigitizerEventPosition);

	IOHIDEventRef parent = p_CreateDigitizerEvent(
		kCFAllocatorDefault, time, (uint32_t)kIOHIDDigitizerTransducerTypeHand,
		0, 0, mask, 0, 0, 0, 0, 0, 0, touching, touching, 0);
	if (!parent) {
		NSLog(@"[Miao] CreateDigitizerEvent failed");
		return;
	}

	IOHIDEventRef child = p_CreateDigitizerFingerEvent(
		kCFAllocatorDefault, time, 1, 1, mask, px, py, 0, 0, 0, touching, touching, 0);
	if (!child) {
		CFRelease(parent);
		NSLog(@"[Miao] CreateDigitizerFingerEvent failed");
		return;
	}

	if (p_SetFloatValue) {
		p_SetFloatValue(child, (uint32_t)kIOHIDEventFieldDigitizerMajorRadius, 5.0f);
		p_SetFloatValue(child, (uint32_t)kIOHIDEventFieldDigitizerMinorRadius, 5.0f);
	}

	p_AppendEvent(parent, child, 0);
	CFRelease(child);

	if (p_SetSenderID) {
		p_SetSenderID(parent, 0x000000010000027FULL);
	}

	IOHIDEventSystemClientRef client = p_ClientCreate(kCFAllocatorDefault);
	if (!client) {
		CFRelease(parent);
		NSLog(@"[Miao] EventSystemClientCreate failed");
		return;
	}

	p_ClientDispatch(client, parent);
	CFRelease(parent);
	CFRelease(client);
}

extern "C" void MiaoPerformTapWithDuration(CGFloat x, CGFloat y, NSTimeInterval duration) {
	NSLog(@"[Miao] tap (%.1f, %.1f) dur=%.3f", x, y, duration);
	MiaoDispatchDigitizer(x, y, YES);
	useconds_t us = (useconds_t)MAX(10000.0, duration * 1000000.0);
	usleep(us);
	MiaoDispatchDigitizer(x, y, NO);
}

extern "C" void MiaoPerformTap(CGFloat x, CGFloat y) {
	MiaoPerformTapWithDuration(x, y, 0.05);
}
