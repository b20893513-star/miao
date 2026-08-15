#import "TouchSim.h"
#import <UIKit/UIKit.h>
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
		1, 1, mask, 0,
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
		IOHIDFloat radius = touching ? 0.04f + (pressure * 0.02f) : 0.02f;
		p_SetFloatValue(child, (uint32_t)kIOHIDEventFieldDigitizerMajorRadius, radius);
		p_SetFloatValue(child, (uint32_t)kIOHIDEventFieldDigitizerMinorRadius, radius * 0.9f);
		p_SetFloatValue(child, (uint32_t)kIOHIDEventFieldDigitizerPressure, touching ? pressure : 0.f);
	}

	p_AppendEvent(parent, child, 0);
	CFRelease(child);

	if (p_SetSenderID) {
		// Sender tipico touch digitizer
		p_SetSenderID(parent, 0x800000000000027FULL);
	}

	IOHIDEventSystemClientRef client = MiaoHIDClient();
	if (client) p_ClientDispatch(client, parent);

	CFRelease(parent);
}

static void MiaoNorm(CGFloat x, CGFloat y, IOHIDFloat *nx, IOHIDFloat *ny) {
	CGRect b = UIScreen.mainScreen.bounds;
	if (b.size.width < 1 || b.size.height < 1) b = CGRectMake(0, 0, 414, 896);
	*nx = (IOHIDFloat)(x / b.size.width);
	*ny = (IOHIDFloat)(y / b.size.height);
	*nx = MAX(0.02f, MIN(0.98f, *nx));
	*ny = MAX(0.04f, MIN(0.98f, *ny));
}

void MiaoPerformTapWithDuration(CGFloat x, CGFloat y, NSTimeInterval duration) {
	IOHIDFloat nx, ny;
	MiaoNorm(x, y, &nx, &ny);
	NSLog(@"[Miao] tap norm=(%.3f, %.3f) %@", nx, ny, NSBundle.mainBundle.bundleIdentifier ?: @"?");
	MiaoDispatchDigitizer(nx, ny, YES, 0.6f);
	useconds_t us = (useconds_t)MAX(50000.0, duration * 1000000.0);
	usleep(us);
	MiaoDispatchDigitizer(nx, ny, NO, 0.f);
}

void MiaoPerformTap(CGFloat x, CGFloat y) {
	MiaoPerformTapWithDuration(x, y, 0.08);
}

/// Gesto umano: avvicinamento, down, 2 micro-move, up con pressione variabile.
void MiaoPerformHumanTap(CGFloat x, CGFloat y) {
	NSString *bid = NSBundle.mainBundle.bundleIdentifier ?: @"";
	if (![bid isEqualToString:@"com.apple.mobilesafari"]) {
		NSLog(@"[Miao] HumanTap RIFIUTATO fuori Safari (%@)", bid);
		return;
	}

	CGRect b = UIScreen.mainScreen.bounds;
	if (b.size.width < 1) b = CGRectMake(0, 0, 414, 896);

	// Jitter naturale ┬▒2ÔÇô5 pt
	CGFloat jx = (CGFloat)(arc4random_uniform(7)) - 3.f;
	CGFloat jy = (CGFloat)(arc4random_uniform(7)) - 3.f;
	CGFloat tx = MAX(10, MIN(b.size.width - 10, x + jx));
	CGFloat ty = MAX(50, MIN(b.size.height - 10, y + jy));

	IOHIDFloat nx, ny;
	MiaoNorm(tx, ty, &nx, &ny);

	// Punto di partenza leggermente offset (dito che arriva)
	IOHIDFloat nx0 = MAX(0.02f, MIN(0.98f, nx + (((int)arc4random_uniform(5) - 2) * 0.002f)));
	IOHIDFloat ny0 = MAX(0.04f, MIN(0.98f, ny + (((int)arc4random_uniform(5) - 2) * 0.002f)));

	NSLog(@"[Miao] humanTap (%.0f,%.0f) norm=(%.3f,%.3f)", tx, ty, nx, ny);

	// Hover/contact approach
	MiaoDispatchDigitizer(nx0, ny0, YES, 0.25f);
	usleep(18000 + arc4random_uniform(12000));

	// Press pi├╣ forte sul target
	MiaoDispatchDigitizer(nx, ny, YES, 0.75f);
	usleep(35000 + arc4random_uniform(25000));

	// Micro-move 1 (tremolio dito)
	IOHIDFloat nx1 = MAX(0.02f, MIN(0.98f, nx + 0.0015f));
	IOHIDFloat ny1 = MAX(0.04f, MIN(0.98f, ny + 0.0010f));
	MiaoDispatchDigitizer(nx1, ny1, YES, 0.85f);
	usleep(25000 + arc4random_uniform(20000));

	// Micro-move 2
	IOHIDFloat nx2 = MAX(0.02f, MIN(0.98f, nx - 0.0010f));
	IOHIDFloat ny2 = MAX(0.04f, MIN(0.98f, ny + 0.0005f));
	MiaoDispatchDigitizer(nx2, ny2, YES, 0.70f);
	usleep(30000 + arc4random_uniform(30000));

	// Lift
	MiaoDispatchDigitizer(nx2, ny2, NO, 0.f);
	usleep(20000 + arc4random_uniform(15000));
}
