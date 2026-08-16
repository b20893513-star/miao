#import "MiaoReport.h"
#import <fcntl.h>
#import <unistd.h>
#import <stdlib.h>
#import <math.h>

NSString *const kMiaoEventsPath = @"/var/mobile/Documents/miao-events.jsonl";

/// Oltre questa soglia il file viene tagliato tenendo la coda: il pannello
/// guarda le ultime sessioni, non l'archivio storico.
static const unsigned long long kMiaoEventsMaxBytes = 400 * 1024;

@implementation MiaoStepInfo
@end

@implementation MiaoRunReport
- (instancetype)init {
	if ((self = [super init])) _steps = [NSMutableArray array];
	return self;
}
- (NSTimeInterval)durationMs {
	if (self.end <= 0 || self.start <= 0) return 0;
	return (self.end - self.start) * 1000.0;
}
- (NSInteger)failedCount {
	NSInteger n = 0;
	for (MiaoStepInfo *s in self.steps) if (!s.ok) n++;
	return n;
}
@end

#pragma mark - Scrittura

static NSString *gSid = nil;
static uint32_t gSeed = 0;
static NSTimeInterval gLastEventAt = 0;

static void MiaoEventsRotate(void) {
	NSFileManager *fm = [NSFileManager defaultManager];
	NSDictionary *attr = [fm attributesOfItemAtPath:kMiaoEventsPath error:nil];
	unsigned long long size = [attr fileSize];
	if (size <= kMiaoEventsMaxBytes) return;

	NSData *data = [NSData dataWithContentsOfFile:kMiaoEventsPath];
	if (data.length <= kMiaoEventsMaxBytes / 2) return;
	NSData *tail = [data subdataWithRange:NSMakeRange(data.length - kMiaoEventsMaxBytes / 2,
													 kMiaoEventsMaxBytes / 2)];
	// parti dalla prima riga intera, altrimenti la prima resta troncata a meta'
	NSRange nl = [tail rangeOfData:[@"\n" dataUsingEncoding:NSUTF8StringEncoding]
						   options:0 range:NSMakeRange(0, tail.length)];
	if (nl.location != NSNotFound && nl.location + 1 < tail.length)
		tail = [tail subdataWithRange:NSMakeRange(nl.location + 1, tail.length - nl.location - 1)];
	[tail writeToFile:kMiaoEventsPath atomically:YES];
}

static void MiaoEventWrite(NSDictionary *event) {
	NSMutableDictionary *d = [event mutableCopy];
	d[@"t"] = @([[NSDate date] timeIntervalSince1970]);
	if (gSid.length) d[@"sid"] = gSid;

	NSData *json = [NSJSONSerialization dataWithJSONObject:d options:0 error:nil];
	if (!json.length) return;
	NSMutableData *line = [json mutableCopy];
	[line appendBytes:"\n" length:1];

	/* O_APPEND con una sola write: Safari e SpringBoard scrivono sullo stesso
	   file e non vogliamo righe intrecciate. */
	int fd = open(kMiaoEventsPath.fileSystemRepresentation, O_WRONLY | O_APPEND | O_CREAT, 0644);
	if (fd < 0) return;
	write(fd, line.bytes, line.length);
	close(fd);
}

NSString *MiaoReportBegin(NSString *kind, uint32_t seed) {
	MiaoEventsRotate();
	gSeed = seed ?: arc4random();
	gSid = [NSString stringWithFormat:@"%08x", arc4random()];
	gLastEventAt = [[NSDate date] timeIntervalSince1970];
	MiaoEventWrite(@{ @"ev": @"begin",
					  @"kind": kind ?: @"run",
					  @"seed": @(gSeed) });
	return gSid;
}

void MiaoReportStep(NSString *name, BOOL ok, NSString *detail) {
	if (!gSid.length) return;
	NSTimeInterval now = [[NSDate date] timeIntervalSince1970];
	NSTimeInterval ms = gLastEventAt > 0 ? (now - gLastEventAt) * 1000.0 : 0;
	gLastEventAt = now;
	MiaoEventWrite(@{ @"ev": @"step",
					  @"step": name ?: @"?",
					  @"ok": @(ok ? 1 : 0),
					  @"ms": @((NSInteger)llround(ms)),
					  @"detail": detail ?: @"" });
}

void MiaoReportEnd(BOOL ok, NSString *verdict) {
	if (!gSid.length) return;
	MiaoEventWrite(@{ @"ev": @"end",
					  @"ok": @(ok ? 1 : 0),
					  @"verdict": verdict ?: @"" });
	gSid = nil;
	gSeed = 0;
	gLastEventAt = 0;
}

NSString *MiaoReportSid(void) {
	return gSid;
}

uint32_t MiaoReportSeed(void) {
	return gSeed;
}

#pragma mark - Lettura

static NSString *MiaoStr(NSDictionary *d, NSString *k) {
	id v = d[k];
	if ([v isKindOfClass:[NSString class]]) return v;
	if ([v isKindOfClass:[NSNumber class]]) return [v stringValue];
	return nil;
}

NSArray<MiaoRunReport *> *MiaoReportRead(NSInteger maxSessions) {
	NSString *raw = [NSString stringWithContentsOfFile:kMiaoEventsPath
											  encoding:NSUTF8StringEncoding error:nil];
	if (!raw.length) return @[];

	NSMutableDictionary<NSString *, MiaoRunReport *> *bySid = [NSMutableDictionary dictionary];
	NSMutableArray<MiaoRunReport *> *order = [NSMutableArray array];

	for (NSString *line in [raw componentsSeparatedByString:@"\n"]) {
		if (line.length < 6) continue;
		NSData *d = [line dataUsingEncoding:NSUTF8StringEncoding];
		NSDictionary *ev = [NSJSONSerialization JSONObjectWithData:d options:0 error:nil];
		if (![ev isKindOfClass:[NSDictionary class]]) continue;

		NSString *sid = MiaoStr(ev, @"sid");
		if (!sid.length) continue;
		NSString *kind = MiaoStr(ev, @"ev");
		NSTimeInterval t = [ev[@"t"] doubleValue];

		MiaoRunReport *r = bySid[sid];
		if (!r) {
			r = [MiaoRunReport new];
			r.sid = sid;
			r.start = t;
			bySid[sid] = r;
			[order addObject:r];
		}

		if ([kind isEqualToString:@"begin"]) {
			r.kind = MiaoStr(ev, @"kind") ?: @"run";
			r.seed = (uint32_t)[ev[@"seed"] unsignedLongValue];
			r.start = t;
		} else if ([kind isEqualToString:@"step"]) {
			MiaoStepInfo *s = [MiaoStepInfo new];
			s.name = MiaoStr(ev, @"step") ?: @"?";
			s.ok = [ev[@"ok"] boolValue];
			s.ms = [ev[@"ms"] doubleValue];
			s.detail = MiaoStr(ev, @"detail") ?: @"";
			s.at = t;
			[r.steps addObject:s];
		} else if ([kind isEqualToString:@"end"]) {
			r.end = t;
			r.ok = [ev[@"ok"] boolValue];
			r.verdict = MiaoStr(ev, @"verdict") ?: @"";
		}
	}

	NSArray *sorted = [order sortedArrayUsingComparator:^NSComparisonResult(MiaoRunReport *a, MiaoRunReport *b) {
		if (a.start == b.start) return NSOrderedSame;
		return a.start > b.start ? NSOrderedAscending : NSOrderedDescending;
	}];
	if (maxSessions > 0 && (NSInteger)sorted.count > maxSessions)
		sorted = [sorted subarrayWithRange:NSMakeRange(0, (NSUInteger)maxSessions)];
	return sorted;
}

void MiaoReportClear(void) {
	[@"" writeToFile:kMiaoEventsPath atomically:YES encoding:NSUTF8StringEncoding error:nil];
}
