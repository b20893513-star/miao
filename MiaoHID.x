#import <Foundation/Foundation.h>
#import <notify.h>
#import <unistd.h>
#import "TouchSimBB.h"

static NSString *const kHidPath = @"/var/tmp/miao-hid.txt";
static NSString *const kHidPath2 = @"/var/mobile/Library/Preferences/com.noxlab.miao.hid.plist";
static NSString *const kAlivePath = @"/var/tmp/miao-bb-alive.txt";
static NSString *const kAlivePath2 = @"/var/mobile/Library/Preferences/com.noxlab.miao.bb.plist";
static NSString *const kLogPath = @"/var/tmp/miao-bb.log";
static NSTimeInterval gLast = 0;

static void BBLog(NSString *msg) {
	NSString *line = [NSString stringWithFormat:@"%@ | %@\n", [NSDate date], msg ?: @""];
	NSFileHandle *fh = [NSFileHandle fileHandleForWritingAtPath:kLogPath];
	if (!fh) {
		[line writeToFile:kLogPath atomically:YES encoding:NSUTF8StringEncoding error:nil];
		return;
	}
	@try {
		[fh seekToEndOfFile];
		[fh writeData:[line dataUsingEncoding:NSUTF8StringEncoding]];
	} @catch (NSException *ex) { (void)ex; }
	[fh closeFile];
}

static void BBMarkAlive(void) {
	[@"1" writeToFile:kAlivePath atomically:YES encoding:NSUTF8StringEncoding error:nil];
	[@{ @"alive": @YES, @"ts": @([[NSDate date] timeIntervalSince1970]) }
		writeToFile:kAlivePath2 atomically:YES];
}

static void BBConsume(void) {
	CGFloat nx = -1, ny = -1;

	NSString *raw = [NSString stringWithContentsOfFile:kHidPath encoding:NSUTF8StringEncoding error:nil];
	if (raw.length >= 3) {
		[[NSFileManager defaultManager] removeItemAtPath:kHidPath error:nil];
		NSString *line = [[raw componentsSeparatedByCharactersInSet:[NSCharacterSet newlineCharacterSet]] firstObject];
		NSArray *p = [line componentsSeparatedByString:@","];
		if (p.count >= 2) {
			nx = [p[0] doubleValue];
			ny = [p[1] doubleValue];
		}
	}

	if (nx < 0) {
		NSDictionary *pl = [NSDictionary dictionaryWithContentsOfFile:kHidPath2];
		if (pl[@"nx"] && pl[@"ny"]) {
			nx = [pl[@"nx"] doubleValue];
			ny = [pl[@"ny"] doubleValue];
			[[NSFileManager defaultManager] removeItemAtPath:kHidPath2 error:nil];
		}
	}

	if (nx < 0 || ny < 0) return;

	NSTimeInterval now = NSDate.date.timeIntervalSince1970;
	if (now - gLast < 0.55) {
		BBLog(@"debounce");
		return;
	}
	gLast = now;

	// points assoluti → normalizza con sw/sh se presenti
	if (nx > 1.5 || ny > 1.5) {
		CGFloat w = 414, h = 896;
		NSDictionary *pl = [NSDictionary dictionaryWithContentsOfFile:kHidPath2];
		if ([pl[@"sw"] doubleValue] > 100) w = [pl[@"sw"] doubleValue];
		if ([pl[@"sh"] doubleValue] > 100) h = [pl[@"sh"] doubleValue];
		nx = nx / w;
		ny = ny / h;
	}

	BBLog([NSString stringWithFormat:@"exec norm=%.3f,%.3f", nx, ny]);
	MiaoPerformHumanTapNorm(nx, ny);
}

static void BBStart(void) {
	BBMarkAlive();
	BBLog(@"MiaoHID online");
	int token = 0;
	notify_register_dispatch("com.noxlab.miao.hidtap", &token,
		dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_HIGH, 0),
		^(__unused int t) { BBConsume(); });
	dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
		while (YES) {
			BBMarkAlive();
			BBConsume();
			usleep(300000);
		}
	});
}

%ctor {
	@autoreleasepool {
		// Nessun UIKit: safe in backboardd
		BBStart();
	}
}
