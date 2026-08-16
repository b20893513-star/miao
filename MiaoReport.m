#import "MiaoReport.h"
#import <fcntl.h>
#import <unistd.h>
#import <stdlib.h>
#import <math.h>
#import <errno.h>
#import <string.h>
#import <sys/stat.h>

NSString *const kMiaoEventsPath = @"/var/mobile/Documents/miao-events.jsonl";

/// Fallback: Preferences e' spesso raggiungibile anche quando Documents no,
/// e resta sotto /var/mobile (stesso utente del tweak).
static NSString *const kMiaoEventsFallback =
	@"/var/mobile/Library/Preferences/com.noxlab.miao.events.jsonl";

/// Path rootless Dopamine (se esiste /var/jb).
static NSString *const kMiaoEventsJB =
	@"/var/jb/var/mobile/Library/Miao/events.jsonl";

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

@implementation MiaoReportDiag
@end

#pragma mark - Stato scrittura

static NSString *gSid = nil;
static uint32_t gSeed = 0;
static NSTimeInterval gLastEventAt = 0;
static NSString *gLastWriteError = @"";
static NSString *gActiveWritePath = nil;

NSString *MiaoReportLastWriteError(void) {
	return gLastWriteError ?: @"";
}

static NSArray<NSString *> *MiaoEventPaths(void) {
	NSMutableArray *a = [NSMutableArray arrayWithObjects:kMiaoEventsPath, kMiaoEventsFallback, nil];
	if ([[NSFileManager defaultManager] fileExistsAtPath:@"/var/jb"]) {
		[a addObject:kMiaoEventsJB];
	}
	return a;
}

static void MiaoEnsureParent(NSString *path) {
	NSString *dir = [path stringByDeletingLastPathComponent];
	[[NSFileManager defaultManager] createDirectoryAtPath:dir
							  withIntermediateDirectories:YES
											   attributes:nil
													error:nil];
}

void MiaoReportEnsure(void) {
	for (NSString *path in MiaoEventPaths()) {
		MiaoEnsureParent(path);
		if (![[NSFileManager defaultManager] fileExistsAtPath:path]) {
			[@"" writeToFile:path atomically:YES encoding:NSUTF8StringEncoding error:nil];
		}
		chmod(path.fileSystemRepresentation, 0666);
		NSString *dir = [path stringByDeletingLastPathComponent];
		chmod(dir.fileSystemRepresentation, 0777);
	}
}

static void MiaoEventsRotatePath(NSString *path) {
	NSFileManager *fm = [NSFileManager defaultManager];
	NSDictionary *attr = [fm attributesOfItemAtPath:path error:nil];
	unsigned long long size = [attr fileSize];
	if (size <= kMiaoEventsMaxBytes) return;

	NSData *data = [NSData dataWithContentsOfFile:path];
	if (data.length <= kMiaoEventsMaxBytes / 2) return;
	NSData *tail = [data subdataWithRange:NSMakeRange(data.length - kMiaoEventsMaxBytes / 2,
													 kMiaoEventsMaxBytes / 2)];
	NSRange nl = [tail rangeOfData:[@"\n" dataUsingEncoding:NSUTF8StringEncoding]
						   options:0 range:NSMakeRange(0, tail.length)];
	if (nl.location != NSNotFound && nl.location + 1 < tail.length)
		tail = [tail subdataWithRange:NSMakeRange(nl.location + 1, tail.length - nl.location - 1)];
	[tail writeToFile:path atomically:YES];
	chmod(path.fileSystemRepresentation, 0666);
}

static BOOL MiaoEventWriteTo(NSString *path, NSData *line, NSString **errOut) {
	MiaoEnsureParent(path);
	int fd = open(path.fileSystemRepresentation, O_WRONLY | O_APPEND | O_CREAT, 0666);
	if (fd < 0) {
		if (errOut) *errOut = [NSString stringWithFormat:@"open %@: %s", path, strerror(errno)];
		return NO;
	}
	fchmod(fd, 0666);
	ssize_t n = write(fd, line.bytes, line.length);
	int werr = errno;
	close(fd);
	if (n < 0 || (size_t)n != line.length) {
		if (errOut) *errOut = [NSString stringWithFormat:@"write %@: %s", path, strerror(werr)];
		return NO;
	}
	return YES;
}

static void MiaoEventWrite(NSDictionary *event) {
	MiaoReportEnsure();
	NSMutableDictionary *d = [event mutableCopy];
	d[@"t"] = @([[NSDate date] timeIntervalSince1970]);
	if (gSid.length) d[@"sid"] = gSid;

	NSData *json = [NSJSONSerialization dataWithJSONObject:d options:0 error:nil];
	if (!json.length) {
		gLastWriteError = @"json serialize failed";
		return;
	}
	NSMutableData *line = [json mutableCopy];
	[line appendBytes:"\n" length:1];

	NSMutableArray *errs = [NSMutableArray array];
	BOOL wrote = NO;
	for (NSString *path in MiaoEventPaths()) {
		MiaoEventsRotatePath(path);
		NSString *err = nil;
		if (MiaoEventWriteTo(path, line, &err)) {
			wrote = YES;
			gActiveWritePath = path;
		} else if (err.length) {
			[errs addObject:err];
		}
	}
	gLastWriteError = wrote ? @"" : [errs componentsJoinedByString:@" | "];
	/* Mirror su Documents anche un fingerprint di errore, cosi' SSH lo vede. */
	if (!wrote && gLastWriteError.length) {
		NSString *errPath = @"/var/mobile/Documents/miao-events.err";
		NSString *body = [NSString stringWithFormat:@"%@\n%@\n",
			[NSDate date], gLastWriteError];
		[body writeToFile:errPath atomically:YES encoding:NSUTF8StringEncoding error:nil];
		chmod(errPath.fileSystemRepresentation, 0666);
	}
}

NSString *MiaoReportBegin(NSString *kind, uint32_t seed) {
	MiaoReportEnsure();
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

static NSString *MiaoBestReadablePath(void) {
	NSString *best = nil;
	unsigned long long bestSize = 0;
	for (NSString *path in MiaoEventPaths()) {
		NSDictionary *attr = [[NSFileManager defaultManager] attributesOfItemAtPath:path error:nil];
		unsigned long long sz = [attr fileSize];
		NSString *raw = [NSString stringWithContentsOfFile:path encoding:NSUTF8StringEncoding error:nil];
		if (raw != nil && sz >= bestSize) {
			best = path;
			bestSize = sz;
		}
	}
	return best ?: kMiaoEventsPath;
}

static NSArray<MiaoRunReport *> *MiaoReportParse(NSString *raw, NSInteger maxSessions) {
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

NSArray<MiaoRunReport *> *MiaoReportRead(NSInteger maxSessions) {
	NSString *path = MiaoBestReadablePath();
	NSError *err = nil;
	NSString *raw = [NSString stringWithContentsOfFile:path encoding:NSUTF8StringEncoding error:&err];
	if (!raw.length) {
		/* prova l'altro path se il "migliore" e' vuoto */
		for (NSString *p in MiaoEventPaths()) {
			if ([p isEqualToString:path]) continue;
			raw = [NSString stringWithContentsOfFile:p encoding:NSUTF8StringEncoding error:nil];
			if (raw.length) break;
		}
	}
	return MiaoReportParse(raw, maxSessions);
}

MiaoReportDiag *MiaoReportDiagnose(void) {
	MiaoReportDiag *d = [MiaoReportDiag new];
	d.primaryPath = kMiaoEventsPath;
	d.fallbackPath = kMiaoEventsFallback;
	d.activePath = MiaoBestReadablePath();
	d.lastError = MiaoReportLastWriteError();

	NSError *rerr = nil;
	NSString *raw = [NSString stringWithContentsOfFile:d.activePath
											  encoding:NSUTF8StringEncoding error:&rerr];
	d.canRead = (raw != nil);
	d.bytes = [[[NSFileManager defaultManager] attributesOfItemAtPath:d.activePath error:nil] fileSize];
	d.lineCount = 0;
	if (raw.length) {
		for (NSString *line in [raw componentsSeparatedByString:@"\n"])
			if (line.length > 5) d.lineCount++;
	}
	d.sessionCount = (NSInteger)MiaoReportParse(raw, 1000).count;

	/* prova scrittura su un file dedicato: non sporcare il log eventi */
	NSString *probePath = @"/var/mobile/Documents/miao-panel-write-test.txt";
	NSString *werr = nil;
	NSData *pdata = [[NSString stringWithFormat:@"ok %.0f\n",
		[[NSDate date] timeIntervalSince1970]] dataUsingEncoding:NSUTF8StringEncoding];
	int fd = open(probePath.fileSystemRepresentation, O_WRONLY | O_CREAT | O_TRUNC, 0666);
	if (fd >= 0) {
		ssize_t n = write(fd, pdata.bytes, pdata.length);
		close(fd);
		chmod(probePath.fileSystemRepresentation, 0666);
		d.canWrite = (n > 0);
	} else {
		d.canWrite = MiaoEventWriteTo(kMiaoEventsFallback, pdata, &werr);
		if (!d.canWrite && werr.length) d.lastError = werr;
		else if (!d.canWrite) d.lastError = [NSString stringWithFormat:@"open probe: %s", strerror(errno)];
	}

	if (!d.canRead) {
		d.summary = [NSString stringWithFormat:
			@"Lettura negata (sandbox?). path=%@ err=%@",
			d.activePath, rerr.localizedDescription ?: @"?"];
	} else if (d.sessionCount == 0 && d.bytes == 0) {
		d.summary = @"File vuoto: nessun run ha ancora scritto eventi. Avvia 1 sessione.";
	} else if (d.sessionCount == 0) {
		d.summary = [NSString stringWithFormat:
			@"File %llu byte / %ld righe ma 0 sessioni parsate. Formato?",
			d.bytes, (long)d.lineCount];
	} else {
		d.summary = [NSString stringWithFormat:
			@"OK: %ld sessioni, %llu byte (%@)",
			(long)d.sessionCount, d.bytes,
			[d.activePath lastPathComponent]];
	}
	return d;
}

void MiaoReportClear(void) {
	MiaoReportEnsure();
	for (NSString *path in MiaoEventPaths()) {
		[@"" writeToFile:path atomically:YES encoding:NSUTF8StringEncoding error:nil];
		chmod(path.fileSystemRepresentation, 0666);
	}
}
