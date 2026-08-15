#import "TouchSimBB.h"
#import <Foundation/Foundation.h>
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
		if (!iokit) iokit = dlopen("/System/Library/PrivateFrameworks/IOKit.framework/IOKit", RTLD_LAZY);
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

static IOHIDEventSystemClientRef MiaoHIDClient(void) {
	static IOHIDEventSystemClientRef client = NULL;
	static dispatch_once_t once;
	dispatch_once(&once, ^{
		if (MiaoLoadIOHID()) client = p_ClientCreate(kCFAllocatorDefault);
	});
	return client;
}

static void MiaoDispatchDigitizer(IOHIDFloat nx, IOHIDFloat ny, BOOL touching, IOHIDFloat pressure) {
	if (!MiaoLoadIOHID()) return;
	uint64_t time = mach_absolute_time();
	uint32_t mask = (uint32_t)(kIOHIDDigitizerEventRange | kIOHIDDigitizerEventTouch | kIOHIDDigitizerEventPosition | kIOHIDDigitizerEventIdentity);

	IOHIDEventRef parent = p_CreateDigitizerEvent(
		kCFAllocatorDefault, time, (uint32_t)kIOHIDDigitizerTransducerTypeHand,
		1, 1, mask, 0, nx, ny, 0, 0, 0, touching, touching, 0);
	if (!parent) return;

	IOHIDEventRef child = p_CreateDigitizerFingerEvent(
		kCFAllocatorDefault, time, 1, 1, mask, nx, ny, 0, 0, 0, touching, touching, 0);
	if (!child) {
		CFRelease(parent);
		return;
	}
	if (p_SetFloatValue) {
		IOHIDFloat radius = touching ? 0.045f + (pressure * 0.02f) : 0.02f;
		p_SetFloatValue(child, (uint32_t)kIOHIDEventFieldDigitizerMajorRadius, radius);
		p_SetFloatValue(child, (uint32_t)kIOHIDEventFieldDigitizerMinorRadius, radius * 0.92f);
		p_SetFloatValue(child, (uint32_t)kIOHIDEventFieldDigitizerPressure, touching ? pressure : 0.f);
	}
	p_AppendEvent(parent, child, 0);
	CFRelease(child);
	if (p_SetSenderID) p_SetSenderID(parent, 0x800000000000027FULL);
	IOHIDEventSystemClientRef client = MiaoHIDClient();
	if (client) p_ClientDispatch(client, parent);
	CFRelease(parent);
}

void MiaoPerformHumanTapNorm(CGFloat nx, CGFloat ny) {
	if (nx < 0.01f) nx = 0.01f;
	if (nx > 0.99f) nx = 0.99f;
	if (ny < 0.02f) ny = 0.02f;
	if (ny > 0.99f) ny = 0.99f;

	IOHIDFloat x = (IOHIDFloat)nx;
	IOHIDFloat y = (IOHIDFloat)ny;
	IOHIDFloat x0 = x + (((int)arc4random_uniform(5) - 2) * 0.002f);
	IOHIDFloat y0 = y + (((int)arc4random_uniform(5) - 2) * 0.002f);
	if (x0 < 0.01f) x0 = 0.01f;
	if (x0 > 0.99f) x0 = 0.99f;
	if (y0 < 0.02f) y0 = 0.02f;
	if (y0 > 0.99f) y0 = 0.99f;

	NSLog(@"[MiaoHID] humanTapNorm (%.3f,%.3f)", nx, ny);

	MiaoDispatchDigitizer(x0, y0, YES, 0.28f);
	usleep(20000 + arc4random_uniform(15000));
	MiaoDispatchDigitizer(x, y, YES, 0.78f);
	usleep(40000 + arc4random_uniform(30000));
	MiaoDispatchDigitizer(x + 0.0015f, y + 0.0010f, YES, 0.88f);
	usleep(28000 + arc4random_uniform(22000));
	MiaoDispatchDigitizer(x - 0.0010f, y + 0.0005f, YES, 0.72f);
	usleep(35000 + arc4random_uniform(35000));
	MiaoDispatchDigitizer(x, y, NO, 0.f);
	usleep(25000 + arc4random_uniform(20000));
}
