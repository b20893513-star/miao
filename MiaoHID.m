#import <Foundation/Foundation.h>
#import <notify.h>
#import <unistd.h>
#import <sys/stat.h>
#import "TouchSimBB.h"

static NSString *const kHidPath = @"/var/tmp/miao-hid.txt";
static NSString *const kHidPathDoc = @"/var/mobile/Documents/miao-hid.txt";
static NSString *const kHidPath2 = @"/var/mobile/Library/Preferences/com.noxlab.miao.hid.plist";
static NSString *const kAliveTmp = @"/var/tmp/miao-bb-alive.txt";
static NSString *const kAliveDoc = @"/var/mobile/Documents/miao-hid-alive.txt";
static NSString *const kAlivePlist = @"/var/mobile/Library/Preferences/com.noxlab.miao.bb.plist";
static NSString *const kLogPath = @"/var/tmp/miao-bb.log";
static NSString *const kLogDoc = @"/var/mobile/Documents/miao-bb.log";
static NSTimeInterval gLast = 0;
static int gAliveNotifyToken = -1;

static void BBLog(NSString *msg) {
	NSString *line = [NSString stringWithFormat:@"%@ | %@\n", [NSDate date], msg ?: @""];
	for (NSString *path in @[ kLogPath, kLogDoc ]) {
		NSFileHandle *fh = [NSFileHandle fileHandleForWritingAtPath:path];
		if (!fh) {
			[line writeToFile:path atomically:YES encoding:NSUTF8StringEncoding error:nil];
			chmod(path.fileSystemRepresentation, 0666);
			continue;
		}
		@try {
			[fh seekToEndOfFile];
			[fh writeData:[line dataUsingEncoding:NSUTF8StringEncoding]];
		} @catch (NSException *ex) { (void)ex; }
		[fh closeFile];
	}
}

static void BBMarkAlive(void) {
	NSString *body = @"bb\n";
	for (NSString *path in @[ kAliveTmp, kAliveDoc ]) {
		[body writeToFile:path atomically:YES encoding:NSUTF8StringEncoding error:nil];
		chmod(path.fileSystemRepresentation, 0666);
	}
	[@{ @"alive": @YES, @"who": @"bb", @"ts": @([[NSDate date] timeIntervalSince1970]) }
		writeToFile:kAlivePlist atomically:YES];
	chmod(kAlivePlist.fileSystemRepresentation, 0666);

	if (gAliveNotifyToken < 0)
		notify_register_check("com.noxlab.miao.hid.alive", &gAliveNotifyToken);
	if (gAliveNotifyToken >= 0)
		notify_set_state(gAliveNotifyToken, 1);
}

static void BBConsume(void) {
	CGFloat sx = -1, sy = -1, nx = -1, ny = -1, sw = 0, sh = 0;

	NSDictionary *pl = [NSDictionary dictionaryWithContentsOfFile:kHidPath2];
	if (pl[@"x"] && pl[@"y"]) {
		sx = [pl[@"x"] doubleValue];
		sy = [pl[@"y"] doubleValue];
		nx = [pl[@"nx"] doubleValue];
		ny = [pl[@"ny"] doubleValue];
		sw = [pl[@"sw"] doubleValue];
		sh = [pl[@"sh"] doubleValue];
		[[NSFileManager defaultManager] removeItemAtPath:kHidPath2 error:nil];
	}

	for (NSString *path in @[ kHidPath, kHidPathDoc ]) {
		NSString *raw = [NSString stringWithContentsOfFile:path encoding:NSUTF8StringEncoding error:nil];
		if (raw.length < 3) continue;
		[[NSFileManager defaultManager] removeItemAtPath:path error:nil];
		if (sx < 0) {
			NSString *line = [[raw componentsSeparatedByCharactersInSet:[NSCharacterSet newlineCharacterSet]] firstObject];
			NSArray *p = [line componentsSeparatedByString:@","];
			if (p.count >= 2) {
				nx = [p[0] doubleValue];
				ny = [p[1] doubleValue];
			}
		}
	}

	if (sx < 0 && nx >= 0) {
		if (sw < 100) sw = 414;
		if (sh < 100) sh = 896;
		if (nx <= 1.5) {
			sx = nx * sw;
			sy = ny * sh;
		} else {
			sx = nx;
			sy = ny;
		}
	}
	if (sx < 0) return;

	NSTimeInterval now = NSDate.date.timeIntervalSince1970;
	if (now - gLast < 0.55) {
		BBLog(@"debounce");
		return;
	}
	gLast = now;

	BBLog([NSString stringWithFormat:@"exec screen=%.0f,%.0f", sx, sy]);
	// Da backboardd: screen + contextId e' il path corretto verso Safari
	MiaoPerformHumanTapScreen(sx, sy);
	[@"ok-bb\n" writeToFile:@"/var/mobile/Documents/miao-hid-ack.txt" atomically:YES encoding:NSUTF8StringEncoding error:nil];
}

static void BBStart(void) {
	BBMarkAlive();
	BBLog(@"MiaoHID online (backboardd, no logos)");
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

__attribute__((constructor))
static void MiaoHIDCtor(void) {
	@autoreleasepool {
		BBStart();
	}
}
