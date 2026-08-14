#import "TouchSim.h"
#import <UIKit/UIKit.h>
#import <dlfcn.h>
#import <mach/mach_time.h>
#import <unistd.h>

// Tipi IOKit (privati) — pattern pubblici stile SimulateTouch / HID helpers.
// Non è reverse di XXTouch Elite.

#ifndef IOHIDFloat
typedef float IOHIDFloat;
#endif
#ifndef boolean_t
typedef int boolean_t;
#endif
#ifndef IOOptionBits
typedef uint32_t IOOptionBits;
#endif

typedef struct __IOHIDEvent *IOHIDEventRef;
typedef struct __IOHIDEventSystemClient *IOHIDEventSystemClientRef;

enum {
	kIOHIDEventTypeDigitizer = 11,
};

enum {
	kIOHIDDigitizerTransducerTypeFinger = 0,
	kIOHIDDigitizerTransducerTypeHand = 3,
};

enum {
	kIOHIDDigitizerEventRange = 1 << 0,
	kIOHIDDigitizerEventTouch = 1 << 1,
	kIOHIDDigitizerEventPosition = 1 << 2,
};

enum {
	kIOHIDEventFieldDigitizerMajorRadius = (kIOHIDEventTypeDigitizer << 16) | 0x0B,
	kIOHIDEventFieldDigitizerMinorRadius = (kIOHIDEventTypeDigitizer << 16) | 0x0C,
};

typedef uint32_t IOHIDEventType;
typedef uint32_t IOHIDDigitizerTransducerType;
typedef uint32_t IOHIDDigitizerEventMask;
typedef uint32_t IOHIDEventField;

static IOHIDEventRef (*p_IOHIDEventCreateDigitizerEvent)(
	CFAllocatorRef, uint64_t, IOHIDDigitizerTransducerType, uint32_t, uint32_t,
	IOHIDDigitizerEventMask, uint32_t, IOHIDFloat, IOHIDFloat, IOHIDFloat,
	IOHIDFloat, IOHIDFloat, boolean_t, boolean_t, IOOptionBits) = NULL;

static IOHIDEventRef (*p_IOHIDEventCreateDigitizerFingerEvent)(
	CFAllocatorRef, uint64_t, uint32_t, uint32_t, IOHIDDigitizerEventMask,
	IOHIDFloat, IOHIDFloat, IOHIDFloat, IOHIDFloat, IOHIDFloat,
	boolean_t, boolean_t, IOOptionBits) = NULL;

static void (*p_IOHIDEventAppendEvent)(IOHIDEventRef, IOHIDEventRef, IOOptionBits) = NULL;
static void (*p_IOHIDEventSetFloatValue)(IOHIDEventRef, IOHIDEventField, IOHIDFloat) = NULL;
static void (*p_IOHIDEventSetSenderID)(IOHIDEventRef, uint64_t) = NULL;
static IOHIDEventSystemClientRef (*p_IOHIDEventSystemClientCreate)(CFAllocatorRef) = NULL;
static void (*p_IOHIDEventSystemClientDispatchEvent)(IOHIDEventSystemClientRef, IOHIDEventRef) = NULL;

static bool MiaoLoadIOHID(void) {
	static dispatch_once_t once;
	static bool ok = false;
	dispatch_once(&once, ^{
		void *iokit = dlopen("/System/Library/Frameworks/IOKit.framework/IOKit", RTLD_LAZY);
		if (!iokit) {
			NSLog(@"[Miao] dlopen IOKit failed");
			return;
		}
		p_IOHIDEventCreateDigitizerEvent = (typeof(p_IOHIDEventCreateDigitizerEvent))dlsym(iokit, "IOHIDEventCreateDigitizerEvent");
		p_IOHIDEventCreateDigitizerFingerEvent = (typeof(p_IOHIDEventCreateDigitizerFingerEvent))dlsym(iokit, "IOHIDEventCreateDigitizerFingerEvent");
		p_IOHIDEventAppendEvent = (typeof(p_IOHIDEventAppendEvent))dlsym(iokit, "IOHIDEventAppendEvent");
		p_IOHIDEventSetFloatValue = (typeof(p_IOHIDEventSetFloatValue))dlsym(iokit, "IOHIDEventSetFloatValue");
		p_IOHIDEventSetSenderID = (typeof(p_IOHIDEventSetSenderID))dlsym(iokit, "IOHIDEventSetSenderID");
		p_IOHIDEventSystemClientCreate = (typeof(p_IOHIDEventSystemClientCreate))dlsym(iokit, "IOHIDEventSystemClientCreate");
		p_IOHIDEventSystemClientDispatchEvent = (typeof(p_IOHIDEventSystemClientDispatchEvent))dlsym(iokit, "IOHIDEventSystemClientDispatchEvent");

		ok = p_IOHIDEventCreateDigitizerEvent
			&& p_IOHIDEventCreateDigitizerFingerEvent
			&& p_IOHIDEventAppendEvent
			&& p_IOHIDEventSystemClientCreate
			&& p_IOHIDEventSystemClientDispatchEvent;

		if (!ok) {
			NSLog(@"[Miao] IOHID symbols incomplete");
		}
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
	IOHIDDigitizerEventMask mask =
		(IOHIDDigitizerEventMask)(kIOHIDDigitizerEventRange | kIOHIDDigitizerEventTouch | kIOHIDDigitizerEventPosition);

	IOHIDEventRef parent = p_IOHIDEventCreateDigitizerEvent(
		kCFAllocatorDefault,
		time,
		(IOHIDDigitizerTransducerType)kIOHIDDigitizerTransducerTypeHand,
		0,
		0,
		mask,
		0,
		0, 0, 0, 0, 0,
		touching,
		touching,
		0
	);
	if (!parent) {
		NSLog(@"[Miao] CreateDigitizerEvent failed");
		return;
	}

	IOHIDEventRef child = p_IOHIDEventCreateDigitizerFingerEvent(
		kCFAllocatorDefault,
		time,
		1,
		1,
		mask,
		px, py,
		0, 0, 0,
		touching,
		touching,
		0
	);
	if (!child) {
		CFRelease(parent);
		NSLog(@"[Miao] CreateDigitizerFingerEvent failed");
		return;
	}

	if (p_IOHIDEventSetFloatValue) {
		p_IOHIDEventSetFloatValue(child, (IOHIDEventField)kIOHIDEventFieldDigitizerMajorRadius, 5.0f);
		p_IOHIDEventSetFloatValue(child, (IOHIDEventField)kIOHIDEventFieldDigitizerMinorRadius, 5.0f);
	}

	p_IOHIDEventAppendEvent(parent, child, 0);
	CFRelease(child);

	if (p_IOHIDEventSetSenderID) {
		p_IOHIDEventSetSenderID(parent, 0x000000010000027FULL);
	}

	IOHIDEventSystemClientRef client = p_IOHIDEventSystemClientCreate(kCFAllocatorDefault);
	if (!client) {
		CFRelease(parent);
		NSLog(@"[Miao] EventSystemClientCreate failed");
		return;
	}

	p_IOHIDEventSystemClientDispatchEvent(client, parent);
	CFRelease(parent);
	CFRelease(client);
}

void MiaoPerformTapWithDuration(CGFloat x, CGFloat y, NSTimeInterval duration) {
	NSLog(@"[Miao] tap (%.1f, %.1f) dur=%.3f", x, y, duration);
	MiaoDispatchDigitizer(x, y, YES);
	useconds_t us = (useconds_t)MAX(10000.0, duration * 1000000.0);
	usleep(us);
	MiaoDispatchDigitizer(x, y, NO);
}

void MiaoPerformTap(CGFloat x, CGFloat y) {
	MiaoPerformTapWithDuration(x, y, 0.05);
}
