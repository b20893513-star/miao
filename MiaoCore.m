#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <objc/runtime.h>
#import <objc/message.h>
#import <notify.h>
#import <unistd.h>
#import <sys/stat.h>
#import "MiaoCore.h"
#import "TouchSimSafari.h"
#import "TouchSimBB.h"
#import "TouchSimUIKit.h"
#import "MiaoAX.h"
#import "MiaoReport.h"

static NSInteger gVolCount = 0;
static NSTimeInterval gVolWindowStart = 0;
static NSTimeInterval gLastVol = 0;
static BOOL gBootDone = NO;
static BOOL gSessionBusy = NO;
static BOOL gSafariPollStarted = NO;

static NSString *const kPrefPath = @"/var/mobile/Library/Preferences/com.noxlab.miao.plist";
static NSString *const kHomeDefault = @"https://noxreel.uk/";
static NSString *const kCmdPath = @"/var/mobile/Documents/miao-cmd.txt";
/// Comandi per SpringBoard (pannello): separati da quelli di Safari, che
/// consuma il suo file con un poll e li cancellerebbe.
static NSString *const kSbCmdPath = @"/var/mobile/Documents/miao-sbcmd.txt";
/// Mood forzato dal pannello (0-4). Assente = persona dal seed.
static NSString *const kMoodPath = @"/var/mobile/Documents/miao-mood.txt";
static NSString *const kMoodPathFallback =
	@"/var/mobile/Library/Preferences/com.noxlab.miao.mood.txt";
static NSString *const kAckPath = @"/var/mobile/Documents/miao-ack.txt";
static NSString *const kLogPath = @"/var/mobile/Documents/miao-loaded.txt";
static NSString *const kHidPath = @"/var/tmp/miao-hid.txt";
static NSString *const kHidPathDoc = @"/var/mobile/Documents/miao-hid.txt";
static NSString *const kHidPlist = @"/var/mobile/Library/Preferences/com.noxlab.miao.hid.plist";
static NSString *const kBbAlivePath = @"/var/tmp/miao-bb-alive.txt";
static NSString *const kHidAliveDoc = @"/var/mobile/Documents/miao-hid-alive.txt";
static NSString *const kBbAlivePlist = @"/var/mobile/Library/Preferences/com.noxlab.miao.bb.plist";
static BOOL gHidWorkerStarted = NO;
static NSTimeInterval gLastHidExec = 0;
BOOL MiaoIsBackboardd(void);
BOOL MiaoIsSafari(void);
BOOL MiaoIsSB(void);

#pragma mark - Log / Toast

void MiaoLog(NSString *note) {
	NSString *line = [NSString stringWithFormat:@"%@ | %@\n", [NSDate date], note ?: @""];
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

static __weak UILabel *gToast = nil;

static void MiaoToast(NSString *text) {
	if (MiaoIsBackboardd()) return; // niente UIKit toast in backboardd
	dispatch_async(dispatch_get_main_queue(), ^{
		UIWindow *win = nil;
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations"
		win = UIApplication.sharedApplication.keyWindow;
		if (!win) win = UIApplication.sharedApplication.windows.firstObject;
#pragma clang diagnostic pop
		if (!win) {
			for (UIScene *sc in UIApplication.sharedApplication.connectedScenes) {
				if (![sc isKindOfClass:[UIWindowScene class]]) continue;
				for (UIWindow *w in ((UIWindowScene *)sc).windows) {
					if (w.isKeyWindow) { win = w; break; }
				}
				if (!win && ((UIWindowScene *)sc).windows.count)
					win = ((UIWindowScene *)sc).windows.firstObject;
				if (win) break;
			}
		}
		if (!win) return;
		[gToast removeFromSuperview];
		UILabel *lab = [[UILabel alloc] initWithFrame:CGRectZero];
		// marcato cosi' la ricerca dei controlli nativi non trova i nostri toast
		lab.tag = kMiaoAXIgnoreTag;
		lab.isAccessibilityElement = NO;
		lab.backgroundColor = [[UIColor blackColor] colorWithAlphaComponent:0.88];
		lab.textColor = UIColor.whiteColor;
		lab.font = [UIFont boldSystemFontOfSize:14];
		lab.textAlignment = NSTextAlignmentCenter;
		lab.layer.cornerRadius = 10;
		lab.clipsToBounds = YES;
		lab.numberOfLines = 3;
		lab.text = [NSString stringWithFormat:@"  %@  ", text];
		[lab sizeToFit];
		CGFloat w = MAX(230, lab.bounds.size.width + 24);
		CGFloat h = MAX(42, lab.bounds.size.height + 12);
		lab.frame = CGRectMake((win.bounds.size.width - w) / 2.0, 52, w, h);
		[win addSubview:lab];
		gToast = lab;
		dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(2.6 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
			if (gToast == lab) [lab removeFromSuperview];
		});
	});
}

static void MiaoAck(NSString *msg) {
	NSString *line = [NSString stringWithFormat:@"%@ | %@\n", [NSDate date], msg ?: @""];
	[line writeToFile:kAckPath atomically:YES encoding:NSUTF8StringEncoding error:nil];
	MiaoLog([NSString stringWithFormat:@"ack %@", msg]);
}

#pragma mark - Prefs / process

static NSDictionary *MiaoPrefs(void) {
	return [NSDictionary dictionaryWithContentsOfFile:kPrefPath] ?: @{};
}

static NSString *MiaoHomeURL(void) {
	NSString *u = MiaoPrefs()[@"HomeURL"];
	return ([u isKindOfClass:[NSString class]] && u.length > 4) ? u : kHomeDefault;
}

static NSTimeInterval MiaoWatchSec(void) {
	double s = MiaoPrefs()[@"WaitSeconds"] ? [MiaoPrefs()[@"WaitSeconds"] doubleValue] : 14.0;
	return MAX(8.0, MIN(120.0, s));
}

/**
 Modalita' diagnostica. Da spenta la sonda JS non viene nemmeno installata:
 un listener e una variabile lasciati sulla pagina sono l'impronta piu' facile
 da leggere per il sito.
 */
static BOOL MiaoDebug(void) {
	return [MiaoPrefs()[@"Debug"] boolValue];
}

/// Quanti click sul sito fa il loop ads.
static NSInteger MiaoLoopTaps(void) {
	NSInteger n = MiaoPrefs()[@"LoopTaps"] ? [MiaoPrefs()[@"LoopTaps"] integerValue] : 5;
	return MAX(1, MIN(50, n));
}

/// Host del sito: serve a distinguere le nostre schede da quelle aperte dagli ads.
static NSString *MiaoSiteHost(void) {
	NSString *h = [NSURL URLWithString:MiaoHomeURL()].host.lowercaseString;
	if (!h.length) return @"noxreel";
	return [h hasPrefix:@"www."] ? [h substringFromIndex:4] : h;
}

/**
 Il confronto va fatto sull'host, non sulla stringa intera.

 Le URL di redirect degli ads portano quasi sempre il dominio del publisher nei
 parametri (`.../click.php?...&ref=noxreel.uk`): con un `containsString` quelle
 pagine risultavano "il sito", e da li' in poi ogni decisione era sbagliata —
 nessun popunder contato, tap non bloccati, JS eseguito nella pagina dell'ad.
 */
static BOOL MiaoIsSiteURL(NSString *url) {
	if (!url.length) return NO;
	NSString *h = [NSURL URLWithString:url].host.lowercaseString;
	if (!h.length) return NO;
	if ([h hasPrefix:@"www."]) h = [h substringFromIndex:4];
	NSString *site = MiaoSiteHost();
	return [h isEqualToString:site] || [h hasSuffix:[@"." stringByAppendingString:site]];
}

/**
 Ritardi e scelte che cambiano a ogni sessione.

 Stessi base/spread a ogni passo = firma robotica. Qui il seed del report fa da
 persona: un run e' curioso (scrolla di piu', video piu' in basso, resta
 sull'ad), un altro e' frettoloso ma non istantaneo, un altro e' normale.
 Mood 3 = click tutte le ads; 4 = visione video lunga + scrub.
 */
static uint32_t gRng = 0;
static NSInteger gMood = 1; // 0 curioso, 1 casual, 2 mirato, 3 clickall, 4 videolungo
/// Scritto da SpringBoard quando il pannello forza una persona (-1 = auto).
static NSInteger gForcedMood = -1;

static double MiaoRng(void) {
	if (!gRng) gRng = arc4random() | 1;
	gRng ^= gRng << 13;
	gRng ^= gRng >> 17;
	gRng ^= gRng << 5;
	return (gRng & 0xffffff) / (double)0xffffff;
}

static NSString *MiaoMoodName(NSInteger m) {
	switch (m) {
		case 0: return @"curious";
		case 2: return @"focused";
		case 3: return @"clickall";
		case 4: return @"videolong";
		default: return @"casual";
	}
}

static NSInteger MiaoParseMoodToken(NSString *tok) {
	if (!tok.length) return -1;
	NSString *t = tok.lowercaseString;
	if ([t hasPrefix:@"cur"] || [t isEqualToString:@"0"]) return 0;
	if ([t hasPrefix:@"cas"] || [t isEqualToString:@"1"]) return 1;
	if ([t hasPrefix:@"foc"] || [t hasPrefix:@"mir"] || [t isEqualToString:@"2"]) return 2;
	if ([t hasPrefix:@"click"] || [t isEqualToString:@"3"]) return 3;
	if ([t hasPrefix:@"video"] || [t hasPrefix:@"lung"] || [t isEqualToString:@"4"]) return 4;
	return -1;
}

static void MiaoMoodWrite(NSInteger mood) {
	for (NSString *path in @[ kMoodPath, kMoodPathFallback ]) {
		if (mood < 0) {
			[[NSFileManager defaultManager] removeItemAtPath:path error:nil];
			continue;
		}
		NSString *dir = [path stringByDeletingLastPathComponent];
		[[NSFileManager defaultManager] createDirectoryAtPath:dir
								  withIntermediateDirectories:YES attributes:nil error:nil];
		[[NSString stringWithFormat:@"%ld\n%@", (long)mood, MiaoMoodName(mood)]
			writeToFile:path atomically:YES encoding:NSUTF8StringEncoding error:nil];
	}
}

static NSInteger MiaoMoodRead(void) {
	for (NSString *path in @[ kMoodPath, kMoodPathFallback ]) {
		NSString *raw = [NSString stringWithContentsOfFile:path
												 encoding:NSUTF8StringEncoding error:nil];
		if (!raw.length) continue;
		NSString *line = [[raw componentsSeparatedByCharactersInSet:
			[NSCharacterSet newlineCharacterSet]] firstObject] ?: @"";
		line = [line stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceCharacterSet]];
		if (!line.length) continue;
		unichar c = [line characterAtIndex:0];
		if ([[NSCharacterSet decimalDigitCharacterSet] characterIsMember:c]) {
			NSInteger n = [line integerValue];
			if (n >= 0 && n <= 4) return n;
		}
		NSInteger named = MiaoParseMoodToken(line);
		if (named >= 0) return named;
	}
	return -1;
}

static void MiaoPersonaBegin(void) {
	uint32_t s = MiaoReportSeed();
	if (!s) s = arc4random();
	gRng = s | 1;
	NSInteger forced = MiaoMoodRead();
	if (forced < 0) forced = gForcedMood;
	if (forced >= 0 && forced <= 4) gMood = forced;
	else gMood = (NSInteger)(s % 3);
	/* Tocchi con una "mano" diversa per seed+mood: hold, raggio, drift. */
	MiaoUIKitSetTouchSeed(s ^ ((uint32_t)(gMood + 1) * 0x9E3779B9u));
	MiaoLog([NSString stringWithFormat:@"persona mood=%ld (%@) seed=%08x forced=%ld",
		(long)gMood, MiaoMoodName(gMood), s, (long)forced]);
}

/// Uniforme in [lo, hi].
static NSTimeInterval MiaoBetween(NSTimeInterval lo, NSTimeInterval hi) {
	if (hi <= lo) return lo;
	return lo + MiaoRng() * (hi - lo);
}

/**
 Pausa umana: non e' base+uniforme. Ha una coda lunga (a volte resta fermo a
 "guardare") e ogni tanto una distrazione di 1-4 s. Senza coda le chiusure ads
 sembrano a orologio.
 */
static NSTimeInterval MiaoHumanDelay(NSTimeInterval base, NSTimeInterval spread) {
	double u = MiaoRng();
	/* skew: piu' spesso vicino a base, a volte molto di piu' */
	double skew = u * u; // favorisce valori piccoli di u → pause medie, coda lunga se invertiamo
	NSTimeInterval t = base * (0.75 + MiaoRng() * 0.55) + spread * (0.35 + skew * 0.9);
	if (MiaoRng() < 0.14) t += MiaoBetween(1.1, 3.8); // si ferma a leggere / pensa
	if (gMood == 0 || gMood == 4) t *= 1.25; // curioso / video lungo
	else if (gMood == 2) t *= 0.92;          // mirato: un filo piu' svelto
	else if (gMood == 3) t *= 1.15;          // clickall: resta a cercare CTA
	return MAX(0.15, t);
}

/// Tempo da stare sull'ad prima di chiudere: sempre irregolare, mai sotto i ~4 s.
static NSTimeInterval MiaoAdDwell(void) {
	NSTimeInterval t;
	if (gMood == 0) t = MiaoBetween(6.0, 12.0);
	else if (gMood == 2) t = MiaoBetween(5.0, 8.5);
	else if (gMood == 3) t = MiaoBetween(8.0, 16.0);
	else if (gMood == 4) t = MiaoBetween(3.0, 5.5);
	else t = MiaoBetween(5.5, 10.0);
	if (MiaoRng() < 0.2) t += MiaoBetween(2.0, 5.0);
	return t;
}

static NSInteger MiaoCycles(void) {
	NSInteger n = MiaoPrefs()[@"Cycles"] ? [MiaoPrefs()[@"Cycles"] integerValue] : 1;
	return MAX(1, MIN(10, n));
}

BOOL MiaoIsSB(void) {
	return [NSBundle.mainBundle.bundleIdentifier isEqualToString:@"com.apple.springboard"];
}

BOOL MiaoIsSafari(void) {
	return [NSBundle.mainBundle.bundleIdentifier isEqualToString:@"com.apple.mobilesafari"];
}

BOOL MiaoIsBackboardd(void) {
	NSString *bid = NSBundle.mainBundle.bundleIdentifier ?: @"";
	// a volte backboardd ha path vuoto / executable name
	if ([bid isEqualToString:@"com.apple.backboardd"]) return YES;
	NSString *exe = NSProcessInfo.processInfo.arguments.firstObject ?: @"";
	return [exe.lastPathComponent isEqualToString:@"backboardd"];
}

#pragma mark - Open

static void MiaoOpenURL(NSString *urlStr) {
	NSURL *url = [NSURL URLWithString:urlStr];
	if (!url) return;
	MiaoLog([NSString stringWithFormat:@"openURL %@", urlStr]);
	[[UIApplication sharedApplication] openURL:url options:@{} completionHandler:nil];
}

static void MiaoOpenSafari(void) {
	Class wsCls = NSClassFromString(@"LSApplicationWorkspace");
	id ws = wsCls ? ((id (*)(id, SEL))objc_msgSend)(wsCls, NSSelectorFromString(@"defaultWorkspace")) : nil;
	SEL sel = NSSelectorFromString(@"openApplicationWithBundleID:");
	if (ws && [ws respondsToSelector:sel]) {
		((BOOL (*)(id, SEL, id))objc_msgSend)(ws, sel, @"com.apple.mobilesafari");
	}
}

#pragma mark - Cmd bus

static void MiaoSendCmd(NSString *cmd) {
	NSString *body = [NSString stringWithFormat:@"%@\n%.0f", cmd, [[NSDate date] timeIntervalSince1970]];
	[body writeToFile:kCmdPath atomically:YES encoding:NSUTF8StringEncoding error:nil];
	MiaoLog([NSString stringWithFormat:@"cmd %@", cmd]);
	notify_post([[NSString stringWithFormat:@"com.noxlab.miao.%@", cmd] UTF8String]);
}

#pragma mark - WKWebView / JS

static NSArray *MiaoWindows(void) {
	NSMutableArray *a = [NSMutableArray array];
	for (UIScene *sc in UIApplication.sharedApplication.connectedScenes) {
		if ([sc isKindOfClass:[UIWindowScene class]])
			[a addObjectsFromArray:((UIWindowScene *)sc).windows];
	}
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations"
	if (!a.count) [a addObjectsFromArray:UIApplication.sharedApplication.windows];
#pragma clang diagnostic pop
	return a;
}

static void MiaoFindWK(UIView *v, NSMutableArray *out) {
	if ([v isKindOfClass:NSClassFromString(@"WKWebView")]) [out addObject:v];
	for (UIView *s in v.subviews) MiaoFindWK(s, out);
}

static NSString *MiaoWebViewURL(id wk) {
	SEL sel = NSSelectorFromString(@"URL");
	if (![wk respondsToSelector:sel]) return @"";
	id u = ((id (*)(id, SEL))objc_msgSend)(wk, sel);
	if ([u isKindOfClass:[NSURL class]]) return [(NSURL *)u absoluteString] ?: @"";
	if ([u isKindOfClass:[NSString class]]) return u;
	return @"";
}

static NSArray *MiaoAllWebViews(void) {
	NSMutableArray *all = [NSMutableArray array];
	for (UIWindow *w in MiaoWindows()) MiaoFindWK(w, all);
	return all;
}

static BOOL MiaoWKVisible(UIView *v) {
	if (!v.window || v.hidden || v.alpha < 0.05) return NO;
	if (v.bounds.size.width < 50 || v.bounds.size.height < 50) return NO;
	for (UIView *p = v.superview; p; p = p.superview) {
		if (p.hidden || p.alpha < 0.05) return NO;
	}
	/* Nella panoramica schede le webview ci sono ancora, ma come miniature
	   scalate. Senza questo controllo crederemmo di essere sulla pagina e
	   tapperemmo sulla griglia: il rect convertito tiene conto della scala. */
	UIWindow *win = v.window;
	CGRect shown = CGRectIntersection([v convertRect:v.bounds toView:win], win.bounds);
	if (CGRectIsNull(shown)) return NO;
	CGFloat winArea = win.bounds.size.width * win.bounds.size.height;
	if (winArea > 1 && (shown.size.width * shown.size.height) / winArea < 0.5) return NO;
	return YES;
}

/// La webview davvero davanti agli occhi: dopo un popunder e' quella dell'ad.
static id MiaoFrontWebView(void) {
	id front = nil;
	CGFloat best = 0;
	for (UIView *v in MiaoAllWebViews()) {
		if (!MiaoWKVisible(v)) continue;
		CGFloat area = v.bounds.size.width * v.bounds.size.height;
		if (area > best) {
			best = area;
			front = v;
		}
	}
	return front;
}

/// La webview del sito, anche se la sua scheda e' in secondo piano.
static id MiaoSiteWebView(void) {
	id hidden = nil;
	for (UIView *v in MiaoAllWebViews()) {
		if (!MiaoIsSiteURL(MiaoWebViewURL(v))) continue;
		if (MiaoWKVisible(v)) return v;
		if (!hidden) hidden = v;
	}
	return hidden;
}

/**
 L'invariante che mancava: si puo' tappare solo se la webview del sito e'
 ANCHE quella in primo piano. Se leggiamo le coordinate dalla pagina del sito
 mentre a schermo c'e' l'ad, il touch atterra sull'ad e la sonda non lo vede
 mai: e' esattamente il `NO TOUCH` dopo l'apertura del popunder.
 */
static BOOL MiaoSiteIsFront(void) {
	id front = MiaoFrontWebView();
	return front && MiaoIsSiteURL(MiaoWebViewURL(front));
}

static id MiaoBestWebView(void) {
	id pick = MiaoSiteWebView() ?: MiaoFrontWebView();
	if (!pick) pick = MiaoAllWebViews().lastObject;
	return pick;
}

/// Stato reale di Safari: quante webview, quali URL, quale davanti.
static NSString *MiaoWebState(void) {
	NSMutableString *s = [NSMutableString string];
	NSArray *all = MiaoAllWebViews();
	id front = MiaoFrontWebView();
	[s appendFormat:@"wk=%lu front=%@ siteFront=%d",
		(unsigned long)all.count, MiaoWebViewURL(front), MiaoSiteIsFront()];
	for (UIView *v in all) {
		[s appendFormat:@"\n  %@ vis=%d %.0fx%.0f %@",
			(v == front) ? @"*" : @"-", MiaoWKVisible(v),
			v.bounds.size.width, v.bounds.size.height, MiaoWebViewURL(v)];
	}
	return s;
}

static void MiaoJSIn(id wk, NSString *js, void (^done)(NSString *)) {
	if (!wk) {
		MiaoLog(@"js no wk");
		if (done) done(nil);
		return;
	}
	SEL sel = @selector(evaluateJavaScript:completionHandler:);
	if (![wk respondsToSelector:sel]) {
		if (done) done(nil);
		return;
	}
	((void (*)(id, SEL, id, id))objc_msgSend)(wk, sel, js, ^(id result, NSError *err) {
		NSString *s = [result isKindOfClass:[NSString class]] ? result : (result ? [result description] : nil);
		if (err) MiaoLog([NSString stringWithFormat:@"js err %@", err.localizedDescription]);
		MiaoLog([NSString stringWithFormat:@"js %@", s ?: @"nil"]);
		if (done) done(s);
	});
}

/// Per agire sul sito: la sua webview, anche se la scheda e' in secondo piano.
static void MiaoJS(NSString *js, void (^done)(NSString *)) {
	MiaoJSIn(MiaoBestWebView(), js, done);
}

/**
 Per sapere dove siamo: la pagina che si vede adesso.

 Chiedere "che path e'?" alla webview del sito mentre a schermo c'e' un ad e' il
 modo di credersi sul video quando si e' altrove: il path del sito non cambia,
 quindi la risposta e' sempre quella che ci aspettiamo e non ci accorgiamo di
 niente.
 */
static void MiaoJSFront(NSString *js, void (^done)(NSString *)) {
	MiaoJSIn(MiaoFrontWebView() ?: MiaoBestWebView(), js, done);
}

/// La pagina davanti non e' il sito. Vale anche quando l'URL non e' ancora
/// committed: i popunder passano per about:blank prima del redirect, e in quella
/// finestra di tempo contare per URL dice "nessun ad" mentre l'ad e' a schermo.
static BOOL MiaoForeignFront(void) {
	id front = MiaoFrontWebView();
	return front && !MiaoIsSiteURL(MiaoWebViewURL(front));
}

/// Riporta la pagina del sito in primo piano (definita dopo le API schede).
static void MiaoEnsureSiteFront(void (^done)(BOOL ok));
/// Attende che la pagina davanti sia caricata e usabile (definita col flusso run).
static void MiaoWaitReady(NSInteger tries, void (^done)(BOOL ok));
/// TRUE se Safari e' in Mostra pannelli / panoramica schede.
static BOOL MiaoInTabOverview(void);
/// Esce dalla panoramica e torna alla pagina piena.
static void MiaoEnsureBrowsing(void (^done)(BOOL ok));

static CGPoint MiaoParseXY(NSString *s) {
	if (s.length < 3) return CGPointZero;
	NSString *head = [[s componentsSeparatedByString:@"|"] firstObject];
	NSArray *p = [head componentsSeparatedByString:@","];
	if (p.count < 2) return CGPointZero;
	return CGPointMake([p[0] doubleValue], [p[1] doubleValue]);
}

static BOOL MiaoHidAlive(void) {
	for (NSString *path in @[ kHidAliveDoc, kBbAlivePath ]) {
		if ([[NSFileManager defaultManager] fileExistsAtPath:path]) return YES;
	}
	NSDictionary *pl = [NSDictionary dictionaryWithContentsOfFile:kBbAlivePlist];
	if ([pl[@"alive"] boolValue]) {
		NSTimeInterval ts = [pl[@"ts"] doubleValue];
		if ([[NSDate date] timeIntervalSince1970] - ts < 45.0) return YES;
	}
	int token = 0;
	uint64_t state = 0;
	if (notify_register_check("com.noxlab.miao.hid.alive", &token) == NOTIFY_STATUS_OK) {
		notify_get_state(token, &state);
		if (state != 0) return YES;
	}
	return NO;
}

static NSString *MiaoHidWho(void) {
	NSString *s = [NSString stringWithContentsOfFile:kHidAliveDoc encoding:NSUTF8StringEncoding error:nil];
	if (!s.length) s = [NSString stringWithContentsOfFile:kBbAlivePath encoding:NSUTF8StringEncoding error:nil];
	s = [s stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
	if ([s hasPrefix:@"sb"] || [s isEqualToString:@"sb"]) return @"sb";
	if ([s hasPrefix:@"bb"] || [s isEqualToString:@"bb"]) return @"bb";
	NSDictionary *pl = [NSDictionary dictionaryWithContentsOfFile:kBbAlivePlist];
	NSString *who = [pl[@"who"] description];
	if (who.length) return who;
	return MiaoIsSB() ? @"sb" : @"on";
}

/**
 getBoundingClientRect (viewport WK) → punti FINESTRA Safari.
 Il tap UIKit vuole coordinate finestra; solo il fallback HID vuole lo schermo.
 */
static CGPoint MiaoViewportToWindowIn(UIView *wk, CGPoint vp) {
	if (!wk) return vp;
	UIWindow *win = wk.window;
	CGPoint p = win ? [wk convertPoint:vp toView:win] : [wk convertPoint:vp toView:nil];
	CGRect fr = win ? [wk convertRect:wk.bounds toView:win] : wk.bounds;
	MiaoLog([NSString stringWithFormat:@"wkframe=%.0f,%.0f %.0fx%.0f vp=%.0f,%.0f -> win=%.0f,%.0f",
		fr.origin.x, fr.origin.y, fr.size.width, fr.size.height, vp.x, vp.y, p.x, p.y]);
	return p;
}

static CGPoint MiaoViewportToWindow(CGPoint vp) {
	return MiaoViewportToWindowIn(MiaoBestWebView(), vp);
}

/// Punti finestra → schermo (serve solo all'HID worker).
static CGPoint MiaoWindowToScreen(CGPoint p) {
	UIView *wk = MiaoFrontWebView() ?: MiaoBestWebView();
	UIWindow *win = wk.window;
	if (!win) return p;
	return [win convertPoint:p toWindow:nil];
}

#pragma mark - Scroll a gesti

static double MiaoRnd(void) {
	return MiaoRng();
}

static CGFloat MiaoNudge(CGFloat amount) {
	return (CGFloat)((MiaoRnd() * 2.0 - 1.0) * amount);
}

/**
 Zona della pagina dove e' sicuro appoggiare il dito, in coordinate finestra:
 dentro la webview ma lontano dai bordi laterali (uno swipe dal bordo e' il
 gesto "indietro") e dalle barre di Safari.

 Usa SOLO la webview piena a schermo. Se prendessimo BestWebView (il sito anche
 come miniatura nella panoramica), lo swipe muoverebbe la griglia schede:
 e' esattamente "tiravo su e giu' i pannelli" dopo la chiusura ads.
 */
static BOOL MiaoContentArea(CGRect *out) {
	UIView *wk = MiaoFrontWebView();
	if (!wk || !MiaoWKVisible(wk)) return NO;
	UIWindow *win = wk.window;
	if (!win) return NO;
	CGRect fr = CGRectIntersection([wk convertRect:wk.bounds toView:win], win.bounds);
	if (CGRectIsNull(fr) || fr.size.height < 200 || fr.size.width < 120) return NO;
	/* scarta le miniature della panoramica anche se passano WKVisible per un pelo */
	CGFloat winArea = win.bounds.size.width * win.bounds.size.height;
	if (winArea > 1 && (fr.size.width * fr.size.height) / winArea < 0.55) return NO;
	CGFloat side = MAX(30, fr.size.width * 0.09);
	fr = CGRectMake(fr.origin.x + side, fr.origin.y + 70,
					fr.size.width - side * 2, fr.size.height - 130);
	if (fr.size.height < 110) return NO;
	*out = fr;
	return YES;
}

/**
 Zone in punti FINESTRA per iPhone 11 Pro Max (414x896) e simili.

 NoxReel mobile:
   header sticky ~52pt, padding 16, player 16:9 full-width.
 VAST/HTML skip: barra sotto il video, pulsante BIANCO a DESTRA
   ("Skip 10s" / "Skip →"), ~120x44, padding 14 dal bordo.
 Play / "Tocca per avviare": centro del player.
 Fullscreen nativo iOS: icona in basso a DESTRA della barra controlli.
 Done fullscreen: in alto a SINISTRA.
 Thumb home: card full-width sotto "In tendenza".
 Niente querySelector: il dito va dove sta il pulsante.
 */
static CGRect MiaoWinWebRect(void) {
	UIView *wk = MiaoFrontWebView();
	if (!wk || !wk.window) return UIScreen.mainScreen.bounds;
	CGRect fr = [wk convertRect:wk.bounds toView:wk.window];
	if (CGRectIsNull(fr) || fr.size.width < 80) return UIScreen.mainScreen.bounds;
	return fr;
}

static CGPoint MiaoJitterPt(CGPoint p, CGFloat j) {
	return CGPointMake(p.x + (CGFloat)(MiaoRng() * 2.0 - 1.0) * j,
					   p.y + (CGFloat)(MiaoRng() * 2.0 - 1.0) * j);
}

static CGRect MiaoPlayerRect(void) {
	CGRect w = MiaoWinWebRect();
	CGFloat inset = 12;
	CGFloat top = w.origin.y + 52 + 16; /* header + py-4 */
	CGFloat pw = MAX(160, w.size.width - inset * 2);
	CGFloat ph = pw * 9.0 / 16.0;
	return CGRectMake(w.origin.x + inset, top, pw, ph);
}

static CGPoint MiaoPtSkip(void) {
	CGRect p = MiaoPlayerRect();
	return MiaoJitterPt(CGPointMake(CGRectGetMaxX(p) - 58, CGRectGetMaxY(p) - 28), 9);
}

static CGPoint MiaoPtPlay(void) {
	CGRect p = MiaoPlayerRect();
	return MiaoJitterPt(CGPointMake(CGRectGetMidX(p), CGRectGetMidY(p) - 6), 14);
}

/// Lontano dal play centrale: un tap li' mette in pausa il <video controls>.
static CGPoint MiaoPtShowControls(void) {
	CGRect p = MiaoPlayerRect();
	return MiaoJitterPt(CGPointMake(CGRectGetMidX(p) + 56, CGRectGetMidY(p) + 22), 8);
}

static CGPoint MiaoPtFullscreen(void) {
	CGRect p = MiaoPlayerRect();
	return MiaoJitterPt(CGPointMake(CGRectGetMaxX(p) - 26, CGRectGetMaxY(p) - 16), 5);
}

static CGPoint MiaoPtDoneFS(void) {
	CGRect b = UIScreen.mainScreen.bounds;
	return MiaoJitterPt(CGPointMake(38, MAX(48, b.origin.y + 52)), 5);
}

/// Quadrato Schede di Safari: basso destra, sopra l'home indicator.
static CGPoint MiaoPtTabs(void) {
	CGRect b = UIScreen.mainScreen.bounds;
	return MiaoJitterPt(CGPointMake(b.size.width - 40, b.size.height - 52), 6);
}

/// Card visibile: 0 = prima in alto, 1 = quella sotto.
/// Home mobile: ad top + chip + "In tendenza" + thumb 16:9.
/// Il curioso prima andava troppo in basso (dopo lo scroll) e toccava
/// il titolo / i link sort, non il video.
static CGPoint MiaoPtThumb(NSInteger which) {
	CGRect area;
	if (!MiaoContentArea(&area)) {
		CGRect w = MiaoWinWebRect();
		CGFloat y = w.origin.y + 210 + (which > 0 ? 230 : 0);
		return MiaoJitterPt(CGPointMake(CGRectGetMidX(w), y), 10);
	}
	CGFloat y = area.origin.y + 96 + (CGFloat)(MiaoRng() * 28);
	if (which > 0) y += 210 + (CGFloat)(MiaoRng() * 24);
	if (y > CGRectGetMaxY(area) - 40) y = CGRectGetMaxY(area) - 50;
	return MiaoJitterPt(CGPointMake(CGRectGetMidX(area), y), 10);
}

static CGPoint MiaoPtAdCenter(void) {
	CGRect w = MiaoWinWebRect();
	return MiaoJitterPt(CGPointMake(CGRectGetMidX(w), w.origin.y + w.size.height * 0.42), 22);
}

static BOOL MiaoFrontIsVideo(void) {
	NSString *u = MiaoWebViewURL(MiaoFrontWebView());
	return MiaoIsSiteURL(u) && [u.lowercaseString containsString:@"/video/"];
}

static BOOL MiaoClassLooksLikeVideoFS(NSString *n) {
	if (!n.length) return NO;
	n = n.lowercaseString;
	if ([n containsString:@"fullscreen"] || [n containsString:@"full_screen"]) return YES;
	if ([n containsString:@"avfullscreen"]) return YES;
	if ([n containsString:@"avplayerviewcontroller"]) return YES;
	if ([n containsString:@"webavplayer"]) return YES;
	return NO;
}

static BOOL MiaoViewTreeHasFS(UIView *v, NSInteger depth) {
	if (!v || depth > 14) return NO;
	if (MiaoClassLooksLikeVideoFS(NSStringFromClass(v.class))) return YES;
	id nr = v.nextResponder;
	if (nr && MiaoClassLooksLikeVideoFS(NSStringFromClass([nr class]))) return YES;
	for (UIView *c in v.subviews) {
		if (MiaoViewTreeHasFS(c, depth + 1)) return YES;
	}
	return NO;
}

/// Player nativo iOS a tutto schermo (AV/WebKit), senza leggere il DOM.
static BOOL MiaoInNativeVideoFS(void) {
	for (UIScene *sc in UIApplication.sharedApplication.connectedScenes) {
		if (![sc isKindOfClass:[UIWindowScene class]]) continue;
		for (UIWindow *w in ((UIWindowScene *)sc).windows) {
			if (w.hidden || w.alpha < 0.05) continue;
			if (MiaoClassLooksLikeVideoFS(NSStringFromClass(w.class))) return YES;
			UIViewController *root = w.rootViewController;
			if (root && MiaoClassLooksLikeVideoFS(NSStringFromClass(root.class))) return YES;
			UIViewController *pres = root.presentedViewController;
			if (pres && MiaoClassLooksLikeVideoFS(NSStringFromClass(pres.class))) return YES;
			if (MiaoViewTreeHasFS(w, 0)) return YES;
		}
	}
	return NO;
}

static BOOL MiaoTrustedTapScreen(CGPoint pt, NSString *label);

static BOOL MiaoTapPt(CGPoint pt, NSString *label) {
	return MiaoTrustedTapScreen(pt, label);
}

/**
 Scorre la pagina con uno swipe vero. `dy > 0` = scendi.

 Distanza grande → flick veloce (il dito si stacca in corsa e l'inerzia fa il
 resto); distanza piccola → trascinamento lento e preciso. E' la differenza tra
 "cerco qualcosa piu' in basso" e "sistemo la posizione", e insieme danno la
 quantita' di inerzia giusta: `window.scrollBy` non ne produce nessuna.
 */
static void MiaoGestureScroll(CGFloat dy, void (^done)(void)) {
	if (MiaoInTabOverview()) {
		MiaoLog(@"scroll rifiutato: Mostra pannelli");
		if (done) done();
		return;
	}
	CGRect area;
	if (fabs(dy) < 10 || !MiaoContentArea(&area)) {
		MiaoLog([NSString stringWithFormat:
			@"scroll saltato (dy=%.0f, overview=%d, front=%@)",
			dy, MiaoInTabOverview() ? 1 : 0, MiaoWebViewURL(MiaoFrontWebView())]);
		if (done) done();
		return;
	}

	BOOL flick = fabs(dy) > 380;
	CGFloat travel = flick ? fabs(dy) * 0.42 : fabs(dy) * 0.92;
	travel = MAX(45, MIN(area.size.height * 0.78, travel));
	NSTimeInterval dur = flick ? (0.13 + travel / 2600.0 + MiaoRnd() * 0.07)
							   : (0.34 + travel / 900.0 + MiaoRnd() * 0.18);

	CGFloat x = area.origin.x + area.size.width * (0.28 + MiaoRnd() * 0.44);
	CGFloat top = area.origin.y;
	CGFloat bot = CGRectGetMaxY(area);
	CGFloat startY;
	if (dy > 0) {
		// il pollice parte in basso e sale
		CGFloat lo = top + travel;
		startY = lo + MAX(0, bot - lo) * (0.5 + MiaoRnd() * 0.5);
	} else {
		CGFloat hi = bot - travel;
		startY = top + MAX(0, hi - top) * (MiaoRnd() * 0.5);
	}
	CGPoint from = CGPointMake(x, startY);
	CGPoint to = CGPointMake(x + MiaoNudge(7), dy > 0 ? startY - travel : startY + travel);

	NSString *why = nil;
	BOOL ok = MiaoUIKitSwipe(from, to, dur, &why, ^{
		MiaoAfter(0.45 + MiaoRnd() * 0.35, ^{ if (done) done(); });
	});
	MiaoLog([NSString stringWithFormat:@"scroll dy=%.0f travel=%.0f dur=%.0fms %@ (%@)",
		dy, travel, dur * 1000.0, flick ? @"flick" : @"drag", why ?: @"-"]);
	if (!ok) {
		MiaoAck([NSString stringWithFormat:@"scroll gesto fallito: %@", why ?: @"?"]);
		if (done) done();
	}
}

/// Chiede HID (coords schermo → normalizzate). Scrive tmp + Documents (Safari legge entrambi).
static void MiaoRequestHidTapScreen(CGPoint pt) {
	id dis = MiaoPrefs()[@"DisableBackboardHID"];
	if (dis && [dis boolValue]) {
		MiaoLog(@"HID disabled by prefs");
		return;
	}
	CGRect b = UIScreen.mainScreen.bounds;
	if (b.size.width < 1) b = CGRectMake(0, 0, 414, 896);
	pt.x = MAX(8, MIN(b.size.width - 8, pt.x));
	pt.y = MAX(40, MIN(b.size.height - 8, pt.y));
	CGFloat nx = pt.x / b.size.width;
	CGFloat ny = pt.y / b.size.height;
	NSString *body = [NSString stringWithFormat:@"%.5f,%.5f\n%.0f", nx, ny, [[NSDate date] timeIntervalSince1970]];
	for (NSString *path in @[ kHidPath, kHidPathDoc ]) {
		[body writeToFile:path atomically:YES encoding:NSUTF8StringEncoding error:nil];
		chmod(path.fileSystemRepresentation, 0666);
	}
	[@{
		@"nx": @(nx),
		@"ny": @(ny),
		@"x": @(pt.x),
		@"y": @(pt.y),
		@"sw": @(b.size.width),
		@"sh": @(b.size.height),
		@"ts": @([[NSDate date] timeIntervalSince1970])
	} writeToFile:kHidPlist atomically:YES];
	chmod(kHidPlist.fileSystemRepresentation, 0666);
	notify_post("com.noxlab.miao.hidtap");
	MiaoLog([NSString stringWithFormat:@"hid-req pt=%.0f,%.0f norm=%.3f,%.3f alive=%d who=%@",
		pt.x, pt.y, nx, ny, MiaoHidAlive() ? 1 : 0, MiaoHidWho()]);
}

/**
 `pt` in coordinate finestra (in Safari a schermo pieno coincidono con lo schermo).

 Ordine: tap UIKit dentro Safari (unico che raggiunge davvero WebKit), poi HID
 come fallback. L'HID resta perche' serve fuori da Safari, ma da SpringBoard non
 arriva al web content: il server HID e' backboardd, non noi.
 */
static BOOL MiaoTrustedTapScreen(CGPoint pt, NSString *label) {
	CGRect b = UIScreen.mainScreen.bounds;
	if (b.size.width < 1) b = CGRectMake(0, 0, 414, 896);
	pt.x = MAX(2, MIN(b.size.width - 2, pt.x));
	pt.y = MAX(2, MIN(b.size.height - 2, pt.y));
	MiaoLog([NSString stringWithFormat:@"tap %@ win=%.0f,%.0f", label ?: @"", pt.x, pt.y]);

	if (MiaoIsSafari()) {
		NSString *why = nil;
		if (MiaoUIKitHumanTap(pt, &why)) {
			MiaoLog([NSString stringWithFormat:@"uikit tap ok (%@)", why ?: @"-"]);
			MiaoToast([NSString stringWithFormat:@"UIK %.0f,%.0f", pt.x, pt.y]);
			return YES;
		}
		MiaoAck([NSString stringWithFormat:@"uikit tap fail: %@", why ?: @"?"]);
	}

	MiaoRequestHidTapScreen(MiaoWindowToScreen(pt));

	id prefer = MiaoPrefs()[@"PreferSafariEnqueue"];
	if (prefer && [prefer boolValue] && MiaoIsSafari()) {
		MiaoSafariTrustedTapWindow(pt.x, pt.y);
	}

	BOOL alive = MiaoHidAlive();
	if (alive) {
		MiaoToast([NSString stringWithFormat:@"HID-%@ %.0f,%.0f", MiaoHidWho(), pt.x, pt.y]);
	} else {
		MiaoToast(@"HID OFF (no worker)");
	}
	return alive;
}

#pragma mark - Calibrazione tap (sonda JS)

/**
 La conversione viewport→schermo puo' sbagliare (inset barra Safari, zoom, webview
 piu' alta del viewport visibile). Invece di indovinare: piazziamo un listener JS,
 tappiamo un punto noto e leggiamo dove il touch e' arrivato davvero.
 Il delta misurato diventa la correzione, e "nessun touch" dimostra che l'HID non
 raggiunge il contenuto web.
 */
static NSString *const kCalPath = @"/var/mobile/Documents/miao-cal.plist";
static CGFloat gCalDX = 0;
static CGFloat gCalDY = 0;
static BOOL gCalLoaded = NO;

static void MiaoCalLoad(void) {
	if (gCalLoaded) return;
	gCalLoaded = YES;
	NSDictionary *pl = [NSDictionary dictionaryWithContentsOfFile:kCalPath];
	if (!pl) return;
	gCalDX = [pl[@"dx"] doubleValue];
	gCalDY = [pl[@"dy"] doubleValue];
	MiaoLog([NSString stringWithFormat:@"cal load dx=%.0f dy=%.0f", gCalDX, gCalDY]);
}

static void MiaoCalSave(CGFloat dx, CGFloat dy) {
	gCalDX = dx;
	gCalDY = dy;
	gCalLoaded = YES;
	[@{ @"dx": @(dx), @"dy": @(dy), @"ts": @([[NSDate date] timeIntervalSince1970]) }
		writeToFile:kCalPath atomically:YES];
	chmod(kCalPath.fileSystemRepresentation, 0666);
}

/**
 La sonda serve solo a misurare, quindi lascia meno tracce possibili: nome della
 proprieta' casuale per sessione (niente `__miao*` da cercare), listener tenuti
 in un riferimento e rimossi, proprieta' cancellata alla fine.
 */
static NSString *gProbeKey = nil;
/// La calibrazione e' una misura esplicita: la sonda serve anche a Debug spento,
/// ma solo per la durata della misura e con pulizia subito dopo.
static BOOL gProbeForce = NO;

static BOOL MiaoProbeWanted(void) {
	return MiaoDebug() || gProbeForce;
}

static NSString *MiaoProbeKey(void) {
	if (!gProbeKey) gProbeKey = [NSString stringWithFormat:@"_%08x", arc4random()];
	return gProbeKey;
}

static NSString *MiaoProbeInstallJS(void) {
	return [NSString stringWithFormat:
		@"(function(){var k='%@';"
		@"if(window[k]&&window[k].h){window[k].v=null;return 'READY';}"
		@"var s={v:null};"
		@"s.h=function(e){try{"
		@"var t=(e.touches&&e.touches[0])||(e.changedTouches&&e.changedTouches[0])||e;"
		@"s.v={x:Math.round(t.clientX),y:Math.round(t.clientY),"
		@"tr:(e.isTrusted?1:0),ty:e.type,t:Date.now()};"
		@"}catch(err){}};"
		@"document.addEventListener('touchstart',s.h,true);"
		@"document.addEventListener('mousedown',s.h,true);"
		@"document.addEventListener('click',s.h,true);"
		@"window[k]=s;return 'OK';})()", MiaoProbeKey()];
}

static NSString *MiaoProbeReadJS(void) {
	return [NSString stringWithFormat:
		@"(function(){var s=window['%@'];if(!s) return 'NOPROBE';"
		@"var t=s.v;return t?(t.x+','+t.y+'|'+t.tr+'|'+t.ty):'NONE';})()", MiaoProbeKey()];
}

static NSString *MiaoProbeCleanJS(void) {
	return [NSString stringWithFormat:
		@"(function(){var k='%@',s=window[k];if(!s) return 'NONE';"
		@"try{document.removeEventListener('touchstart',s.h,true);"
		@"document.removeEventListener('mousedown',s.h,true);"
		@"document.removeEventListener('click',s.h,true);}catch(e){}"
		@"try{delete window[k];}catch(e){window[k]=undefined;}"
		@"return 'CLEAN';})()", MiaoProbeKey()];
}

static void MiaoInstallProbe(void (^done)(void)) {
	if (!MiaoProbeWanted()) {
		if (done) done();
		return;
	}
	MiaoJS(MiaoProbeInstallJS(), ^(NSString *r) {
		MiaoLog([NSString stringWithFormat:@"probe %@", r ?: @"nil"]);
		if (done) done();
	});
}

/// Rimuove listener e variabile: dopo questa la pagina e' come l'abbiamo trovata.
static void MiaoCleanProbe(void (^done)(void)) {
	if (!gProbeKey) {
		if (done) done();
		return;
	}
	MiaoJS(MiaoProbeCleanJS(), ^(NSString *r) {
		MiaoLog([NSString stringWithFormat:@"probe clean %@", r ?: @"nil"]);
		if (done) done();
	});
}

static void MiaoCalibRun(void);

/// Legge dove e' atterrato l'ultimo touch: CGPointZero se nessuno.
static void MiaoReadProbe(void (^done)(CGPoint landed, BOOL trusted, NSString *raw)) {
	if (!MiaoProbeWanted()) {
		done(CGPointZero, NO, @"OFF (Debug=0)");
		return;
	}
	MiaoJS(MiaoProbeReadJS(), ^(NSString *r) {
		if (!r.length || [r hasPrefix:@"NONE"] || [r hasPrefix:@"NOPROBE"]) {
			done(CGPointZero, NO, r ?: @"NONE");
			return;
		}
		NSArray *p = [r componentsSeparatedByString:@"|"];
		CGPoint q = MiaoParseXY(p.firstObject);
		BOOL tr = p.count > 1 && [p[1] isEqualToString:@"1"];
		done(q, tr, r);
	});
}

/// Path principale: coords viewport DOM → finestra (+ correzione) → tap.
/// Solo sulla pagina del SITO: se a schermo c'e' altro, non tappiamo.
static BOOL MiaoTrustedTapViewport(CGPoint vp, NSString *label) {
	if (vp.x < 1 && vp.y < 1) return NO;

	id src = MiaoBestWebView();
	if (MiaoIsSafari() && src && src != MiaoFrontWebView()) {
		MiaoAck([NSString stringWithFormat:@"tap annullato, sito non in primo piano\n%@", MiaoWebState()]);
		MiaoToast(@"Tap NO: ad davanti");
		return NO;
	}

	MiaoCalLoad();
	CGPoint win = MiaoViewportToWindowIn(src ?: MiaoFrontWebView(), vp);
	win.x += gCalDX;
	win.y += gCalDY;
	MiaoLog([NSString stringWithFormat:@"tap %@ vp=%.0f,%.0f win=%.0f,%.0f cal=%.0f,%.0f",
		label ?: @"", vp.x, vp.y, win.x, win.y, gCalDX, gCalDY]);
	return MiaoTrustedTapScreen(win, label);
}

/**
 Tap sulla pagina che si vede adesso (anche l'ad).

 Serve per i click sul creativo: le coordinate arrivano dalla webview in primo
 piano, e il check "sito davanti" non deve bloccarle — altrimenti sull'ad non
 si tocca mai niente e Relay non vede alcun click, solo un'apertura di scheda.
 */
static BOOL MiaoTrustedTapFront(CGPoint vp, NSString *label) {
	if (vp.x < 1 && vp.y < 1) return NO;
	UIView *front = MiaoFrontWebView();
	if (!front || !MiaoWKVisible(front)) {
		MiaoAck([NSString stringWithFormat:@"tap front: nessuna pagina piena\n%@", MiaoWebState()]);
		return NO;
	}
	MiaoCalLoad();
	CGPoint win = MiaoViewportToWindowIn(front, vp);
	win.x += gCalDX;
	win.y += gCalDY;
	MiaoLog([NSString stringWithFormat:@"tap-front %@ vp=%.0f,%.0f win=%.0f,%.0f url=%@",
		label ?: @"", vp.x, vp.y, win.x, win.y, MiaoWebViewURL(front)]);
	return MiaoTrustedTapScreen(win, label);
}

/**
 Tappa un punto senza link e confronta richiesto vs atterrato.
 Toast: `CAL ok d=dx,dy` oppure `CAL NO TOUCH` (= HID non arriva alla pagina).
 */
static void MiaoActCalib(void) {
	MiaoToast(@"Calib...");
	gProbeForce = YES;
	MiaoEnsureSiteFront(^(BOOL front) {
		if (!front) {
			gProbeForce = NO;
			MiaoAck([NSString stringWithFormat:@"calib annullata, sito non davanti\n%@", MiaoWebState()]);
			MiaoToast(@"CAL: ad davanti");
			return;
		}
		/* Su un DOM ancora vuoto la sonda viene installata su un documento che
		   il load sostituisce subito dopo: il touch arriva, ma il listener non
		   c'e' piu' e la misura risulta "nessun touch". */
		MiaoWaitReady(0, ^(BOOL ready) {
			if (!ready) {
				gProbeForce = NO;
				MiaoAck(@"calib annullata, pagina non pronta");
				MiaoToast(@"CAL: pagina non pronta");
				return;
			}
			MiaoCalibRun();
		});
	});
}

static void MiaoCalibRun(void) {
	NSString *jsSafe =
		@"(function(){"
		@"var W=window.innerWidth,H=window.innerHeight;"
		@"var ys=[0.5,0.4,0.6,0.3,0.7],xs=[0.5,0.22,0.78];"
		@"for(var i=0;i<ys.length;i++)for(var j=0;j<xs.length;j++){"
		@"  var x=Math.round(W*xs[j]),y=Math.round(H*ys[i]);"
		@"  var el=document.elementFromPoint(x,y);"
		@"  if(!el) continue;"
		@"  if(el.closest&&el.closest('a,button,video,iframe,[role=button],[onclick]')) continue;"
		@"  return x+','+y+'|'+W+','+H+'|'+el.tagName;"
		@"}"
		@"return Math.round(W*0.5)+','+Math.round(H*0.5)+'|'+W+','+H+'|FALLBACK';"
		@"})()";

	MiaoInstallProbe(^{
		MiaoJS(jsSafe, ^(NSString *r) {
			if (!r.length) {
				gProbeForce = NO;
				MiaoToast(@"Calib no point");
				return;
			}
			NSArray *parts = [r componentsSeparatedByString:@"|"];
			CGPoint vp = MiaoParseXY(parts.firstObject);
			if (vp.x < 1 && vp.y < 1) {
				gProbeForce = NO;
				MiaoToast(@"Calib no point");
				return;
			}
			MiaoAck([NSString stringWithFormat:@"calib target %@", r]);

			// tap SENZA correzione: vogliamo misurare l'errore grezzo
			CGPoint win = MiaoViewportToWindow(vp);
			MiaoTrustedTapScreen(win, @"calib");

			MiaoAfter(1.3, ^{
				MiaoReadProbe(^(CGPoint landed, BOOL trusted, NSString *raw) {
					void (^finish)(void) = ^{
						gProbeForce = NO;
						if (!MiaoDebug()) MiaoCleanProbe(nil);
					};
					if (landed.x < 1 && landed.y < 1) {
						MiaoAck([NSString stringWithFormat:
							@"calib NO TOUCH — il touch non e' arrivato a questa pagina\n%@", MiaoWebState()]);
						MiaoToast(@"CAL NO TOUCH");
						finish();
						return;
					}
					CGFloat dx = vp.x - landed.x;
					CGFloat dy = vp.y - landed.y;
					MiaoCalSave(dx, dy);
					MiaoAck([NSString stringWithFormat:@"calib ok raw=%@ want=%.0f,%.0f got=%.0f,%.0f d=%.0f,%.0f tr=%d",
						raw, vp.x, vp.y, landed.x, landed.y, dx, dy, trusted ? 1 : 0]);
					MiaoToast([NSString stringWithFormat:@"CAL ok d=%.0f,%.0f tr%d", dx, dy, trusted ? 1 : 0]);
					finish();
				});
			});
		});
	});
}

void MiaoStartBackboardd(void) {
	MiaoLog(@"MiaoStartBackboardd noop");
}

/// HID worker in SpringBoard: su Dopamine backboardd spesso NON viene iniettato.
/// SB invece carica Miao.dylib → qui eseguiamo i tap.
void MiaoStartHidWorker(void) {
	if (gHidWorkerStarted) return;
	if (!MiaoIsSB()) return;
	gHidWorkerStarted = YES;

	void (^mark)(void) = ^{
		NSString *body = @"sb\n";
		for (NSString *path in @[ kHidAliveDoc, kBbAlivePath ]) {
			[body writeToFile:path atomically:YES encoding:NSUTF8StringEncoding error:nil];
			chmod(path.fileSystemRepresentation, 0666);
		}
		[@{ @"alive": @YES, @"who": @"sb", @"ts": @([[NSDate date] timeIntervalSince1970]) }
			writeToFile:kBbAlivePlist atomically:YES];
		chmod(kBbAlivePlist.fileSystemRepresentation, 0666);
		int tok = 0;
		if (notify_register_check("com.noxlab.miao.hid.alive", &tok) == NOTIFY_STATUS_OK)
			notify_set_state(tok, 1);
	};

	void (^consume)(void) = ^{
		CGFloat sx = -1, sy = -1, nx = -1, ny = -1;

		// Preferisci punti schermo dal plist (path SB → Safari)
		NSDictionary *pl = [NSDictionary dictionaryWithContentsOfFile:kHidPlist];
		if (pl[@"x"] && pl[@"y"]) {
			sx = [pl[@"x"] doubleValue];
			sy = [pl[@"y"] doubleValue];
			nx = [pl[@"nx"] doubleValue];
			ny = [pl[@"ny"] doubleValue];
			[[NSFileManager defaultManager] removeItemAtPath:kHidPlist error:nil];
		}

		for (NSString *path in @[ kHidPath, kHidPathDoc ]) {
			NSString *raw = [NSString stringWithContentsOfFile:path encoding:NSUTF8StringEncoding error:nil];
			if (raw.length < 3) continue;
			[[NSFileManager defaultManager] removeItemAtPath:path error:nil];
			if (sx >= 0) break; // gia' abbiamo screen pts
			NSString *line = [[raw componentsSeparatedByCharactersInSet:[NSCharacterSet newlineCharacterSet]] firstObject];
			NSArray *p = [line componentsSeparatedByString:@","];
			if (p.count >= 2) {
				nx = [p[0] doubleValue];
				ny = [p[1] doubleValue];
			}
			break;
		}

		if (sx < 0 && nx >= 0) {
			CGFloat sw = [pl[@"sw"] doubleValue];
			CGFloat sh = [pl[@"sh"] doubleValue];
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
		if (now - gLastHidExec < 0.55) return;
		gLastHidExec = now;

		MiaoLog([NSString stringWithFormat:@"SB-HID screen %.0f,%.0f", sx, sy]);
		dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_HIGH, 0), ^{
			MiaoPerformHumanTapScreen(sx, sy);
			[@"ok-sb\n" writeToFile:@"/var/mobile/Documents/miao-hid-ack.txt" atomically:YES encoding:NSUTF8StringEncoding error:nil];
		});
	};

	mark();
	MiaoLog(@"HID worker online (SpringBoard)");
	MiaoToast(@"HID worker SB ON");

	int token = 0;
	notify_register_dispatch("com.noxlab.miao.hidtap", &token,
		dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_HIGH, 0),
		^(__unused int t) { consume(); });

	dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
		while (YES) {
			mark();
			consume();
			usleep(350000);
		}
	});
}

#pragma mark - Safari actions (human)

/// La pagina che si vede e' caricata e contiene almeno un video utilizzabile.
static void MiaoActReady(void (^done)(BOOL ok)) {
	MiaoJSFront(@"(function(){return document.readyState+'|'"
				@"+document.querySelectorAll('a[href*=\"/video/\"]').length;})()", ^(NSString *r) {
		NSArray *p = [r componentsSeparatedByString:@"|"];
		NSString *state = p.count ? p.firstObject : @"";
		NSInteger n = p.count > 1 ? [p[1] integerValue] : 0;
		BOOL loaded = [state isEqualToString:@"complete"] || [state isEqualToString:@"interactive"];
		if (done) done(loaded && n > 0);
	});
}

/**
 Elenco dei link video utilizzabili: `idx:top,idx:top,...|H|scrollY`.

 Il target viaggia come indice nel DOM, non come variabile appesa alla pagina:
 `window.__miaoTarget` era un'impronta che bastava leggere per riconoscerci.
 */
static NSString *const kMiaoJSThumbList =
	@"(function(){"
	@"var as=document.querySelectorAll('a[href*=\"/video/\"]');"
	@"var ok=[];"
	@"for(var i=0;i<as.length;i++){"
	@"  var r=as[i].getBoundingClientRect();"
	@"  if(r.width>=40&&r.height>=40) ok.push(i+':'+Math.round(r.top));"
	@"}"
	@"return ok.join(',')+'|'+window.innerHeight+'|'+Math.round(window.scrollY);"
	@"})()";

/// Stato del thumb `idx`: `top|x,y|HIT|MISS|OFF|href|W,H`, oppure `GONE`.
static NSString *MiaoJSThumbAt(NSInteger idx) {
	return [NSString stringWithFormat:
		@"(function(){"
		@"var as=document.querySelectorAll('a[href*=\"/video/\"]');"
		@"var a=as[%ld];"
		@"if(!a) return 'GONE';"
		@"var r=a.getBoundingClientRect();"
		@"var W=window.innerWidth,H=window.innerHeight;"
		@"var frac=r.height>0?Math.max(0,Math.min(r.bottom,H)-Math.max(r.top,0))/r.height:0;"
		// punto casuale nella zona centrale: un dito non centra mai il pixel esatto
		@"var fx=0.5+(Math.random()-0.5)*0.56, fy=0.5+(Math.random()-0.5)*0.5;"
		@"var x=Math.round(r.left+r.width*fx), y=Math.round(r.top+r.height*fy);"
		@"var hit='OFF';"
		@"if(frac>0.7&&y>6&&y<H-6){"
		@"  x=Math.max(3,Math.min(W-3,x));"
		@"  var el=document.elementFromPoint(x,y);"
		@"  hit=(el&&el.closest&&el.closest('a[href*=\"/video/\"]')===a)?'HIT':'MISS';"
		@"}"
		@"return Math.round(r.top)+'|'+x+','+y+'|'+hit+'|'+(a.href||'')+'|'+W+','+H;"
		@"})()", (long)idx];
}

/// Sceglie un video a caso tra quelli raggiungibili, con preferenza diversa
/// a seconda della persona della sessione (non sempre il primo vicino).
static void MiaoPickThumb(void (^done)(NSInteger idx)) {
	MiaoJS(kMiaoJSThumbList, ^(NSString *r) {
		NSArray *parts = [r componentsSeparatedByString:@"|"];
		NSString *list = parts.count ? parts.firstObject : @"";
		if (!list.length) {
			done(-1);
			return;
		}
		CGFloat H = parts.count > 1 ? [parts[1] doubleValue] : 0;
		if (H < 120) H = 700;

		NSMutableArray *near = [NSMutableArray array];
		NSMutableArray *mid = [NSMutableArray array];
		NSMutableArray *far = [NSMutableArray array];
		NSMutableArray *all = [NSMutableArray array];
		for (NSString *pair in [list componentsSeparatedByString:@","]) {
			NSArray *kv = [pair componentsSeparatedByString:@":"];
			if (kv.count < 2) continue;
			[all addObject:kv[0]];
			CGFloat top = [kv[1] doubleValue];
			if (top > -H * 0.4 && top < H * 0.85) [near addObject:kv[0]];
			else if (top >= H * 0.85 && top < H * 1.8) [mid addObject:kv[0]];
			else if (top >= H * 1.8 && top < H * 3.2) [far addObject:kv[0]];
		}

		NSArray *pool = nil;
		if (gMood == 0 || gMood == 4) {
			/* curioso / video lungo: un po' piu' in basso, ma non oltre 2 schermate */
			pool = mid.count ? mid : near;
			if (MiaoRng() < 0.25 && far.count) pool = far;
			if (MiaoRng() < 0.3 && near.count) pool = near;
		} else if (gMood == 2) {
			/* mirato: prende qualcosa di gia' in vista */
			pool = near.count ? near : (mid.count ? mid : all);
			if (MiaoRng() < 0.2 && mid.count) pool = mid;
		} else {
			/* casual / clickall: mescola le fasce vicine */
			double u = MiaoRng();
			if (u < 0.55) pool = near.count ? near : all;
			else if (u < 0.9) pool = mid.count ? mid : (near.count ? near : all);
			else pool = far.count ? far : (mid.count ? mid : all);
		}
		if (!pool.count) pool = all;
		if (!pool.count) {
			done(-1);
			return;
		}
		NSString *pick = pool[(NSUInteger)(MiaoRng() * pool.count) % pool.count];
		MiaoLog([NSString stringWithFormat:@"thumb pick %@ mood=%ld near=%lu mid=%lu far=%lu",
			pick, (long)gMood, (unsigned long)near.count, (unsigned long)mid.count, (unsigned long)far.count]);
		done([pick integerValue]);
	});
}

/// Porta il video scelto sotto gli occhi con swipe veri, correggendo il tiro.
static void MiaoScrollToThumb(NSInteger idx, NSInteger tries, void (^done)(BOOL ok, NSString *raw)) {
	MiaoJS(MiaoJSThumbAt(idx), ^(NSString *r) {
		if (!r.length || [r hasPrefix:@"GONE"]) {
			done(NO, r ?: @"nil");
			return;
		}
		NSArray *p = [r componentsSeparatedByString:@"|"];
		CGFloat top = [p.firstObject doubleValue];
		NSString *hit = p.count > 2 ? p[2] : @"OFF";
		CGFloat H = 700;
		if (p.count > 4) {
			NSArray *wh = [p[4] componentsSeparatedByString:@","];
			if (wh.count > 1 && [wh[1] doubleValue] > 120) H = [wh[1] doubleValue];
		}

		// dove si tiene quello che si sta guardando: poco sopra la meta'
		CGFloat dy = top - H * 0.34;
		BOOL visible = ![hit isEqualToString:@"OFF"];
		if (visible && fabs(dy) < H * 0.24) {
			done(YES, r);
			return;
		}
		if (tries >= 4) {
			done(visible, r);
			return;
		}
		MiaoGestureScroll(dy, ^{
			MiaoAfter(MiaoHumanDelay(0.2, 0.5), ^{ MiaoScrollToThumb(idx, tries + 1, done); });
		});
	});
}

/// Rilegge il punto del video scelto e lo tappa con un touch reale.
static void MiaoTapThumb(NSInteger idx, NSString *label, void (^done)(BOOL tapped)) {
	MiaoJS(MiaoJSThumbAt(idx), ^(NSString *r) {
		NSArray *p = [r componentsSeparatedByString:@"|"];
		CGPoint vp = p.count > 1 ? MiaoParseXY(p[1]) : CGPointZero;
		NSString *hit = p.count > 2 ? p[2] : @"?";
		if (!r.length || [r hasPrefix:@"GONE"] || [hit isEqualToString:@"OFF"] ||
			(vp.x < 1 && vp.y < 1)) {
			MiaoAck([NSString stringWithFormat:@"%@: punto non valido (%@)", label, r ?: @"nil"]);
			if (done) done(NO);
			return;
		}
		if (![hit isEqualToString:@"HIT"])
			MiaoAck([NSString stringWithFormat:@"%@: elementFromPoint %@, tento comunque", label, hit]);
		MiaoAck([NSString stringWithFormat:@"%@ %@", label, r]);
		BOOL ok = MiaoTrustedTapViewport(vp, label);
		if (done) done(ok);
	});
}

static void MiaoActClickVideo(void) {
	MiaoToast(@"Thumb...");
	MiaoPickThumb(^(NSInteger idx) {
		if (idx < 0) {
			MiaoAck(@"click: nessun thumb");
			MiaoToast(@"Nessun thumb");
			return;
		}
		MiaoInstallProbe(nil);
		MiaoScrollToThumb(idx, 0, ^(BOOL ok, NSString *raw) {
			if (!ok) {
				MiaoAck([NSString stringWithFormat:@"click: thumb %ld non raggiunto (%@)", (long)idx, raw]);
				MiaoToast(@"Thumb non raggiunto");
				return;
			}
			// prima di toccare, una persona guarda: la pausa e' parte del gesto
			MiaoAfter(MiaoHumanDelay(0.45, 0.9), ^{
				MiaoTapThumb(idx, @"thumb", ^(BOOL tapped) {
					if (!tapped) {
						MiaoToast(@"Tap non fatto");
						return;
					}
					MiaoAfter(MiaoHumanDelay(2.4, 1.2), ^{
						MiaoJS(@"(function(){return location.pathname;})()", ^(NSString *path) {
							if (path && [path containsString:@"/video/"]) {
								MiaoAck(@"click: navigato");
								MiaoToast(@"Video OK");
								return;
							}
							MiaoReadProbe(^(CGPoint landed, BOOL trusted, NSString *rawProbe) {
								if (landed.x < 1 && landed.y < 1) {
									MiaoAck([NSString stringWithFormat:
										@"click: nessuna navigazione, sonda %@\n%@", rawProbe, MiaoWebState()]);
									MiaoToast(@"Miss");
								} else {
									MiaoAck([NSString stringWithFormat:@"click: touch a %@ ma nessuna navigazione", rawProbe]);
									MiaoToast([NSString stringWithFormat:@"Miss @%.0f,%.0f tr%d",
										landed.x, landed.y, trusted ? 1 : 0]);
								}
							});
						});
					});
				});
			});
		});
	});
}

/**
 Trova lo skip e dice se e' cliccabile: `READY|x,y|testo`, `WAIT|x,y|testo`,
 `NONE`. Il punto e' casuale dentro il pulsante. Cerca anche negli iframe
 same-origin, dove i VAST mettono i loro controlli.
 */
static NSString *const kMiaoJSFindSkip =
	@"(function(){"
	@"function txt(el){return ((el&&(el.innerText||el.textContent))||'').trim();}"
	@"function isSkip(el){return /skip|salta/i.test(txt(el))&&txt(el).length<40;}"
	@"function vis(el){var r=el.getBoundingClientRect();"
	@"  return r.width>8&&r.height>8&&r.bottom>0&&r.top<window.innerHeight;}"
	@"function ready(el){"
	@"  if(el.disabled) return false;"
	@"  if(el.getAttribute&&el.getAttribute('disabled')!==null) return false;"
	@"  if(/disabled/i.test(el.className||'')) return false;"
	@"  try{var cs=getComputedStyle(el);"
	@"    if(cs.pointerEvents==='none') return false;"
	@"    if(parseFloat(cs.opacity||'1')<0.35) return false;"
	@"  }catch(e){}"
	// un countdown ancora in corso mostra un numero: "Salta tra 5"
	@"  if(/\\d/.test(txt(el))) return false;"
	@"  return true;"
	@"}"
	@"function scan(root,ox,oy){"
	@"  if(!root||!root.querySelectorAll) return null;"
	@"  var nodes=[].slice.call(root.querySelectorAll('button,a,[role=button],div,span'));"
	@"  for(var i=0;i<nodes.length;i++){"
	@"    var el=nodes[i];"
	@"    if(!isSkip(el)||!vis(el)) continue;"
	@"    var r=el.getBoundingClientRect();"
	// nemmeno sullo skip il dito cade sul pixel centrale
	@"    var fx=0.5+(Math.random()-0.5)*0.5, fy=0.5+(Math.random()-0.5)*0.5;"
	@"    var x=Math.round(ox+r.left+r.width*fx), y=Math.round(oy+r.top+r.height*fy);"
	@"    return (ready(el)?'READY|':'WAIT|')+x+','+y+'|'+txt(el).slice(0,24);"
	@"  }"
	@"  return null;"
	@"}"
	@"var res=scan(document,0,0);"
	@"if(res) return res;"
	@"var ifr=document.querySelectorAll('iframe');"
	@"for(var i=0;i<ifr.length;i++){"
	@"  try{"
	@"    var d=ifr[i].contentDocument||(ifr[i].contentWindow&&ifr[i].contentWindow.document);"
	@"    var fr=ifr[i].getBoundingClientRect();"
	@"    var r2=scan(d,fr.left,fr.top);"
	@"    if(r2) return r2;"
	@"  }catch(e){}"
	@"}"
	@"return 'NONE';"
	@"})()";

/**
 Skip a mano: si cerca il pulsante e lo si tocca. Niente `el.click()` ne'
 `removeAttribute('disabled')`: quelli sono comandi che arrivano dal nulla, e su
 un player pubblicitario e' esattamente il segnale che non deve esserci.
 */
static void MiaoActSkip(void) {
	MiaoToast(@"Skip...");
	BOOL ok = MiaoTapPt(MiaoPtSkip(), @"skip");
	MiaoToast(ok ? @"Skip" : @"Skip NO");
}

/**
 Trova un target cliccabile sulla pagina IN PRIMO PIANO (landing ads / creativo)
 e lo tocca con un dito reale. Senza questo il popunder si apre e si chiude ma
 nessun click arriva al tag: Relay conta 0.
 */
static NSString *const kMiaoJSFindAdTarget =
	@"(function(){"
	@"function visible(el){"
	@"  if(!el) return false;"
	@"  var r=el.getBoundingClientRect();"
	@"  return r.width>18&&r.height>18&&r.bottom>8&&r.top<window.innerHeight-8;"
	@"}"
	@"function pack(el,tag){"
	@"  if(!el||!visible(el)) return null;"
	@"  var r=el.getBoundingClientRect();"
	@"  var fx=0.5+(Math.random()-0.5)*0.45, fy=0.5+(Math.random()-0.5)*0.45;"
	@"  var h=el.getAttribute('real-href')||el.href||el.getAttribute('href')||el.getAttribute('data-href')||'';"
	@"  return tag+'|'+Math.round(r.left+r.width*fx)+','+Math.round(r.top+r.height*fy)+'|'+(h||'').toString().slice(0,100);"
	@"}"
	@"var sels=["
	@"  'a.exo-native-widget-item[real-href]',"
	@"  'a[real-href*=\"click\"]',"
	@"  'a[href*=\"click.php\"]',"
	@"  'a[href*=\"/click\"]',"
	@"  'a[href*=\"out.php\"]',"
	@"  'a[href*=\"redirect\"]',"
	@"  '[data-click-url]',"
	@"  'a[href^=\"http\"]:not([href*=\"noxreel\"])',"
	@"  'button',"
	@"  '[role=button]',"
	@"  'a[href]'"
	@"];"
	@"for(var s=0;s<sels.length;s++){"
	@"  var nodes=[].slice.call(document.querySelectorAll(sels[s]));"
	@"  for(var i=0;i<nodes.length;i++){"
	@"    var el=nodes[i];"
	@"    var t=((el.innerText||el.getAttribute('aria-label')||'')+'').toLowerCase();"
	@"    if(/skip|salta|close|chiudi|accept cookie|accetta/.test(t)) continue;"
	@"    var h=(el.getAttribute('real-href')||el.href||el.getAttribute('href')||'').toLowerCase();"
	@"    if(/noxreel\\.uk/.test(h)&&!/click|out|go|redirect|relay/.test(h)) continue;"
	@"    var r=pack(el, sels[s].slice(0,12));"
	@"    if(r) return r;"
	@"  }"
	@"}"
	@"var ctaRe=/learn\\s*more|visit|scopri|visita|continua|click\\s*here|vai|annuncio|advertiser|download|install|play|guarda/i;"
	@"var btns=[].slice.call(document.querySelectorAll('a,button,[role=button],div[onclick]'));"
	@"for(var j=0;j<btns.length;j++){"
	@"  if(ctaRe.test((btns[j].innerText||btns[j].getAttribute('aria-label')||'')+'')){"
	@"    var r2=pack(btns[j],'CTA');"
	@"    if(r2) return r2;"
	@"  }"
	@"}"
	/* ultimo tentativo: area centrale del body (creativo a tutto schermo) */
	@"var W=window.innerWidth,H=window.innerHeight;"
	@"var x=Math.round(W*(0.35+Math.random()*0.3)), y=Math.round(H*(0.35+Math.random()*0.3));"
	@"var el=document.elementFromPoint(x,y);"
	@"if(el){"
	@"  var hit=el.closest&&el.closest('a,button,[role=button],[onclick],img');"
	@"  if(hit){var r3=pack(hit,'HIT'); if(r3) return r3;}"
	@"}"
	@"return 'NONE';"
	@"})()";

/// Click sul creativo (CTA / link) sulla pagina ads in primo piano.
static void MiaoStepResult(NSString *name, BOOL ok, NSString *detail);

static void MiaoTapAdOnFront(void (^done)(BOOL ok, NSString *detail)) {
	if (!MiaoForeignFront()) {
		if (done) done(NO, @"sito davanti, niente creativo");
		return;
	}
	MiaoJSFront(kMiaoJSFindAdTarget, ^(NSString *result) {
		if (!result.length || [result hasPrefix:@"NONE"]) {
			MiaoAck([NSString stringWithFormat:@"ad-click: nessun target\n%@", MiaoWebState()]);
			if (done) done(NO, @"nessun target cliccabile");
			return;
		}
		NSArray *parts = [result componentsSeparatedByString:@"|"];
		NSString *tag = parts.firstObject ?: @"AD";
		CGPoint vp = parts.count >= 2 ? MiaoParseXY(parts[1]) : CGPointZero;
		MiaoAck([NSString stringWithFormat:@"ad-click %@", result]);
		if (vp.x < 1) {
			if (done) done(NO, result);
			return;
		}
		/* esitazione umana sul creativo prima del tap */
		MiaoAfter(MiaoBetween(0.4, 1.4), ^{
			BOOL ok = MiaoTrustedTapFront(vp, [NSString stringWithFormat:@"ad-%@", tag]);
			MiaoToast(ok ? [NSString stringWithFormat:@"Ads tap %@", tag]
						 : @"Ads tap NO");
			if (done) done(ok, result);
		});
	});
}

/// Piu' tap sul creativo (persona clickall): ogni volta rilegge i target sulla pagina.
static void MiaoTapAdsBurst(NSInteger left, NSInteger doneOk, void (^done)(NSInteger okCount)) {
	if (left <= 0 || !MiaoForeignFront()) {
		if (done) done(doneOk);
		return;
	}
	MiaoTapAdOnFront(^(BOOL ok, NSString *detail) {
		MiaoStepResult(@"ad-click", ok, detail ?: @"");
		NSInteger next = doneOk + (ok ? 1 : 0);
		MiaoAfter(MiaoBetween(1.4, 3.2), ^{
			MiaoTapAdsBurst(left - 1, next, done);
		});
	});
}

/// Click ads manuale (comando): stessa strada del run, sulla pagina davanti.
static void MiaoActClickAd(void) {
	MiaoToast(@"Click ads...");
	BOOL ok = MiaoTapPt(MiaoPtAdCenter(), @"ad-centro");
	MiaoToast(ok ? @"Ads tap" : @"Ads tap NO");
}

/**
 Il tempo passato sulla pagina, fatto di gesti e non di comandi: un paio di
 scroll lenti con pause in mezzo, come chi guarda un video e intanto sbircia i
 consigliati. Niente `v.currentTime` o `v.play()`: quelli sono comandi che una
 persona non puo' dare, e sul player si vedono subito.
 */
static void MiaoWatchStep(NSInteger left, NSInteger total) {
	if (left <= 0) {
		MiaoJS(@"(function(){return location.pathname;})()", ^(NSString *p) {
			MiaoAck([NSString stringWithFormat:@"visione: %ld scroll su %@", (long)total, p ?: @"?"]);
		});
		return;
	}
	// per lo piu' si scende, a volte si torna un po' su a rivedere
	CGFloat dy = (arc4random_uniform(100) < 22)
		? -(120 + (CGFloat)arc4random_uniform(160))
		: (200 + (CGFloat)arc4random_uniform(320));
	MiaoGestureScroll(dy, ^{
		MiaoAfter(MiaoHumanDelay(1.6, 3.4), ^{ MiaoWatchStep(left - 1, total); });
	});
}

static void MiaoActHumanWatch(void) {
	MiaoToast(@"Guardo...");
	NSInteger n = 1 + (NSInteger)arc4random_uniform(3);
	MiaoWatchStep(n, n);
}

static void MiaoActWhere(void (^done)(NSString *path)) {
	MiaoJS(@"(function(){return location.pathname+'|'+location.href;})()", ^(NSString *r) {
		if (done) done(r ?: @"");
	});
}

#pragma mark - Close ads tabs

static id MiaoBrowser(void) {
	Class c = NSClassFromString(@"BrowserController") ?: NSClassFromString(@"_SFBrowserController");
	if (!c) return nil;
	for (NSString *s in @[ @"sharedBrowserController", @"sharedInstance" ]) {
		SEL sel = NSSelectorFromString(s);
		if ([c respondsToSelector:sel]) {
			@try { return ((id (*)(id, SEL))objc_msgSend)(c, sel); }
			@catch (NSException *ex) { (void)ex; }
		}
	}
	return nil;
}

static NSString *MiaoTabURL(id tab) {
	for (NSString *k in @[ @"URLString", @"URL", @"committedURL", @"urlString" ]) {
		@try {
			id v = [tab valueForKey:k];
			if ([v isKindOfClass:[NSURL class]]) return [(NSURL *)v absoluteString];
			if ([v isKindOfClass:[NSString class]] && [v length]) return v;
		} @catch (NSException *ex) { (void)ex; }
	}
	return @"";
}

static NSArray *MiaoTabList(id bc) {
	if (!bc) return @[];
	id tc = nil;
	@try { tc = [bc valueForKey:@"tabController"]; } @catch (NSException *ex) { (void)ex; }
	id src = tc ?: bc;
	for (NSString *k in @[ @"tabDocuments", @"tabs", @"allTabDocuments" ]) {
		@try {
			id a = [src valueForKey:k];
			if ([a isKindOfClass:[NSArray class]]) return a;
		} @catch (NSException *ex) { (void)ex; }
	}
	return @[];
}

static BOOL MiaoCloseTab(id bc, id tab) {
	for (NSString *m in @[ @"closeTabDocument:animated:", @"closeTab:" ]) {
		SEL sel = NSSelectorFromString(m);
		if (![bc respondsToSelector:sel]) continue;
		@try {
			if ([m containsString:@"animated"])
				((void (*)(id, SEL, id, BOOL))objc_msgSend)(bc, sel, tab, YES);
			else
				((void (*)(id, SEL, id))objc_msgSend)(bc, sel, tab);
			return YES;
		} @catch (NSException *ex) { (void)ex; }
	}
	id tc = nil;
	@try { tc = [bc valueForKey:@"tabController"]; } @catch (NSException *ex) { (void)ex; }
	SEL sel = NSSelectorFromString(@"closeTabDocument:animated:");
	if (tc && [tc respondsToSelector:sel]) {
		@try {
			((void (*)(id, SEL, id, BOOL))objc_msgSend)(tc, sel, tab, YES);
			return YES;
		} @catch (NSException *ex) { (void)ex; }
	}
	return NO;
}

/// Rende attiva una scheda: le firme cambiano tra versioni di Safari.
static BOOL MiaoSelectTab(id bc, id tab) {
	if (!bc || !tab) return NO;
	id tc = nil;
	@try { tc = [bc valueForKey:@"tabController"]; } @catch (NSException *ex) { (void)ex; }

	for (id target in @[ bc, tc ?: bc ]) {
		for (NSString *m in @[ @"setActiveTabDocument:animated:",
							   @"_setActiveTabDocument:animated:",
							   @"setActiveTabDocument:",
							   @"selectTabDocument:",
							   @"selectTab:" ]) {
			SEL sel = NSSelectorFromString(m);
			if (![target respondsToSelector:sel]) continue;
			@try {
				if ([m containsString:@"animated"])
					((void (*)(id, SEL, id, BOOL))objc_msgSend)(target, sel, tab, NO);
				else
					((void (*)(id, SEL, id))objc_msgSend)(target, sel, tab);
				MiaoLog([NSString stringWithFormat:@"selectTab via %@", m]);
				return YES;
			} @catch (NSException *ex) { (void)ex; }
		}
	}
	return NO;
}

/// Riporta Safari sulla scheda del sito (dopo che l'ad ha rubato il primo piano).
static BOOL MiaoSelectSiteTab(void) {
	id bc = MiaoBrowser();
	for (id tab in MiaoTabList(bc)) {
		if (!MiaoIsSiteURL(MiaoTabURL(tab))) continue;
		if (MiaoSelectTab(bc, tab)) {
			MiaoLog(@"back to site tab");
			return YES;
		}
	}
	MiaoLog(@"site tab not found");
	return NO;
}

/// Chiude le schede che non sono del sito (quelle aperte dagli ads).
static NSInteger MiaoCloseNonNoxTabs(void) {
	id bc = MiaoBrowser();
	NSArray *tabs = MiaoTabList(bc);
	NSInteger closed = 0;
	for (id tab in [tabs reverseObjectEnumerator]) {
		NSString *u = MiaoTabURL(tab);
		MiaoLog([NSString stringWithFormat:@"tab %@", u.length ? u : @"(empty)"]);
		// una scheda ancora senza URL puo' essere l'ad in caricamento: non toccarla
		if (MiaoIsSiteURL(u) || !u.length) continue;
		if (MiaoCloseTab(bc, tab)) closed++;
	}
	if (closed > 0) MiaoSelectSiteTab();
	MiaoAck([NSString stringWithFormat:@"closeads %ld of %lu", (long)closed, (unsigned long)tabs.count]);
	return closed;
}

/**
 Chiude le pagine ads chiamando `window.close()` dentro la loro stessa webview.
 Non dipende dalle API private delle schede (che su iOS 16 non rispondono) e
 funziona perche' quelle pagine sono state aperte da uno script.
 */
static void MiaoCloseAdWebViews(void (^done)(NSInteger closed)) {
	NSMutableArray *ads = [NSMutableArray array];
	for (UIView *v in MiaoAllWebViews()) {
		NSString *u = MiaoWebViewURL(v);
		if (u.length && !MiaoIsSiteURL(u)) [ads addObject:v];
	}
	if (!ads.count) {
		if (done) done(0);
		return;
	}

	__block BOOL finished = NO;
	__block NSInteger left = (NSInteger)ads.count;
	NSInteger total = (NSInteger)ads.count;
	void (^finish)(void) = ^{
		if (finished) return;
		finished = YES;
		if (done) done(total);
	};

	for (id wk in ads) {
		MiaoLog([NSString stringWithFormat:@"window.close %@", MiaoWebViewURL(wk)]);
		MiaoJSIn(wk, @"(function(){try{window.close();}catch(e){}return 'closing';})()", ^(NSString *r) {
			(void)r;
			if (--left <= 0) finish();
		});
	}
	// se una webview muore prima del callback non lo riceviamo piu'
	MiaoAfter(1.5, finish);
}

/**
 Quante pagine estranee al sito sono aperte. Conta le webview, non le schede: la
 lista schede arriva da API private che possono tornare vuote, le webview le
 vediamo sempre nella gerarchia.

 Una webview senza URL conta solo se e' visibile. Cosi' prendiamo il popunder
 nei primi secondi, quando l'URL non e' ancora committed, senza contare le
 webview di servizio di Safari (start page, preview) che stanno sempre in giro.
 */
static NSInteger MiaoForeignTabCount(void) {
	id site = MiaoSiteWebView();
	NSInteger n = 0;
	for (UIView *v in MiaoAllWebViews()) {
		if (v == site) continue;
		NSString *u = MiaoWebViewURL(v);
		if (u.length) {
			if (!MiaoIsSiteURL(u)) n++;
		} else if (MiaoWKVisible(v)) {
			n++;
		}
	}
	return n;
}

#pragma mark - UI nativa di Safari

/* Le etichette cambiano con la lingua del device: proviamo italiano e inglese,
   e in coda gli identifier interni. Se non troviamo nulla il log riporta il
   dump completo, cosi' si aggiunge il nome giusto invece di indovinare. */

static NSArray<NSString *> *MiaoNamesTabs(void) {
	return @[ @"Schede", @"Tabs", @"Mostra tutte le schede", @"Show All Tabs",
			  @"Panoramica schede", @"Tab Overview", @"TabsButton",
			  @"Mostra pannelli", @"Mostra panoramica schede", @"Pannelli" ];
}

static NSArray<NSString *> *MiaoNamesClose(void) {
	return @[ @"Chiudi scheda", @"Close Tab", @"Chiudi", @"Close", @"CloseTabButton",
			  @"Chiudi questa scheda", @"Close This Tab", @"Elimina scheda" ];
}

static NSArray<NSString *> *MiaoNamesBack(void) {
	return @[ @"Indietro", @"Back", @"BackButton" ];
}

static NSArray<NSString *> *MiaoNamesDone(void) {
	return @[ @"Fine", @"Done", @"Chiudi panoramica", @"Close Overview" ];
}

static BOOL MiaoWKCoversScreen(UIView *v, CGFloat frac) {
	if (!v.window) return NO;
	CGRect shown = CGRectIntersection([v convertRect:v.bounds toView:v.window], v.window.bounds);
	if (CGRectIsNull(shown) || shown.size.width < 80 || shown.size.height < 80) return NO;
	CGFloat winArea = v.window.bounds.size.width * v.window.bounds.size.height;
	if (winArea < 1) return NO;
	return (shown.size.width * shown.size.height) / winArea >= frac;
}

static BOOL MiaoHasFullPageWebView(void) {
	for (UIView *v in MiaoAllWebViews()) {
		if (v.hidden || v.alpha < 0.05) continue;
		if (MiaoWKCoversScreen(v, 0.72)) return YES;
	}
	return NO;
}

static NSInteger MiaoBigCardCount(void) {
	NSInteger big = 0;
	for (MiaoAXNode *n in MiaoAXNodes()) {
		if (n.frame.size.width >= 90 && n.frame.size.height >= 110) big++;
	}
	return big;
}

/**
 Siamo nella panoramica schede ("Mostra pannelli"), non sulla pagina.

 Non basta "c'e' una webview": dopo Schede→X resta una miniatura grande del
 sito, FrontWebView diventa non-nil e il run scrollava i pannelli.
 Fine da solo non basta: il player nativo iOS ha lo stesso pulsante.
 */
static BOOL MiaoInTabOverview(void) {
	if (MiaoInNativeVideoFS()) return NO;
	BOOL fine = MiaoAXFind(MiaoNamesDone()) != nil;
	BOOL full = MiaoHasFullPageWebView();
	NSInteger cards = MiaoBigCardCount();
	if (fine && !full) return YES;
	if (!full && cards >= 2) return YES;
	if (fine && cards >= 2) return YES;
	return NO;
}

/// Titolo della pagina del sito: nella griglia le schede si chiamano cosi'.
static NSString *gSiteTitle = nil;

static void MiaoRememberSiteTitle(void) {
	MiaoJSIn(MiaoSiteWebView(), @"(function(){return document.title||'';})()", ^(NSString *t) {
		t = [t stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
		if (t.length >= 4) gSiteTitle = [t substringToIndex:MIN((NSUInteger)14, t.length)];
	});
}

static NSArray<NSString *> *MiaoSiteCardNames(void) {
	NSMutableArray *a = [NSMutableArray arrayWithObject:MiaoSiteHost()];
	if (gSiteTitle.length) [a addObject:gSiteTitle];
	return a;
}

/// Tap su un controllo nativo, in un punto qualsiasi dentro di esso.
static BOOL MiaoTapNode(MiaoAXNode *n, NSString *label) {
	if (!n) return NO;
	CGRect f = n.frame;
	CGPoint p = CGPointMake(CGRectGetMidX(f) + MiaoNudge(MIN(7, f.size.width * 0.2)),
							CGRectGetMidY(f) + MiaoNudge(MIN(7, f.size.height * 0.2)));
	NSString *why = nil;
	BOOL ok = MiaoUIKitHumanTap(p, &why);
	MiaoLog([NSString stringWithFormat:@"tap nativo %@ %@ -> %@ (%@)",
		label, ok ? @"ok" : @"FAIL", n, why ?: @"-"]);
	if (!ok) MiaoAck([NSString stringWithFormat:@"tap nativo %@ fallito: %@", label, why ?: @"?"]);
	return ok;
}

/// La miniatura della nostra scheda nella griglia (grande, non un pulsantino).
static MiaoAXNode *MiaoSiteCard(void) {
	MiaoAXNode *best = nil;
	for (MiaoAXNode *n in MiaoAXFindAll(MiaoSiteCardNames())) {
		if (n.frame.size.width < 90 || n.frame.size.height < 90) continue;
		CGFloat area = n.frame.size.width * n.frame.size.height;
		if (!best || area > best.frame.size.width * best.frame.size.height) best = n;
	}
	return best;
}

/// X AX sulla scheda ads (non sulla card NoxReel).
static MiaoAXNode *MiaoAdCloseButton(MiaoAXNode *siteCard) {
	for (MiaoAXNode *c in MiaoAXFindAll(MiaoNamesClose())) {
		if (c.frame.size.width > 90 && c.frame.size.height > 90) continue;
		if (siteCard && CGRectContainsPoint(CGRectInset(siteCard.frame, -18, -18), c.center))
			continue;
		return c;
	}
	return nil;
}

/**
 Card grandi che non sono NoxReel: la X Safari sta in alto a destra della
 miniatura (~22 pt dal bordo). Serve se AX non espone "Chiudi scheda".
 */
static BOOL MiaoTapForeignCardCloseX(MiaoAXNode *siteCard) {
	MiaoAXNode *pick = nil;
	CGFloat best = 0;
	for (MiaoAXNode *n in MiaoAXNodes()) {
		if (n.frame.size.width < 100 || n.frame.size.height < 120) continue;
		if (siteCard && CGRectIntersectsRect(CGRectInset(siteCard.frame, -8, -8), n.frame)
			&& fabs(n.frame.size.width - siteCard.frame.size.width) < 40)
			continue;
		NSString *lab = (n.label ?: @"").lowercaseString;
		NSString *host = MiaoSiteHost().lowercaseString;
		if (host.length && [lab containsString:host]) continue;
		if (gSiteTitle.length && [lab containsString:gSiteTitle.lowercaseString]) continue;
		CGFloat a = n.frame.size.width * n.frame.size.height;
		if (a > best) { best = a; pick = n; }
	}
	if (!pick) return NO;
	CGPoint x = CGPointMake(CGRectGetMaxX(pick.frame) - 22, pick.frame.origin.y + 22);
	x.x += MiaoNudge(4);
	x.y += MiaoNudge(4);
	MiaoLog([NSString stringWithFormat:@"X geometrica su card %@ @%.0f,%.0f",
		pick, x.x, x.y]);
	return MiaoTapPt(x, @"chiudi-x-geo");
}

/// Chiude UNA scheda ads in panoramica. YES se ha tappato qualcosa.
static BOOL MiaoCloseOneForeignInGrid(void) {
	MiaoAXNode *site = MiaoSiteCard();
	MiaoAXNode *ax = MiaoAdCloseButton(site);
	if (ax && MiaoTapNode(ax, @"chiudi ad")) return YES;
	if (MiaoTapForeignCardCloseX(site)) return YES;
	return NO;
}

static void MiaoCloseAllForeignInGrid(NSInteger left, NSInteger closed, void (^done)(NSInteger n));
static void MiaoLeaveTabGrid(NSInteger tries, void (^done)(BOOL onSite));
static void MiaoReturnToSiteTab(void (^done)(BOOL ok));

/**
 Chiude tutte le X possibili in panoramica (max 8), poi rientra sulla scheda
 NoxReel. Una sola X lasciava stack di popup aperti.
 */
static void MiaoCloseAllForeignInGrid(NSInteger left, NSInteger closed, void (^done)(NSInteger n)) {
	if (left <= 0 || !MiaoInTabOverview()) {
		if (done) done(closed);
		return;
	}
	if (!MiaoCloseOneForeignInGrid()) {
		if (done) done(closed);
		return;
	}
	MiaoAfter(MiaoBetween(0.55, 0.95), ^{
		MiaoCloseAllForeignInGrid(left - 1, closed + 1, done);
	});
}

/// Rientro sulla scheda sito SENZA openURL (openURL = nuova tab + nuovi pop).
static void MiaoReturnToSiteTab(void (^done)(BOOL ok)) {
	if (MiaoSiteIsFront() && !MiaoInTabOverview()) {
		if (done) done(YES);
		return;
	}
	if (MiaoInTabOverview()) {
		MiaoLeaveTabGrid(0, ^(BOOL onSite) {
			if (onSite) {
				if (done) done(YES);
				return;
			}
			if (MiaoSelectSiteTab()) {
				MiaoAfter(1.2, ^{
					if (done) done(MiaoSiteIsFront() && !MiaoInTabOverview());
				});
				return;
			}
			if (done) done(NO);
		});
		return;
	}
	if (MiaoSelectSiteTab()) {
		MiaoAfter(1.2, ^{
			if (done) done(MiaoSiteIsFront() && !MiaoInTabOverview());
		});
		return;
	}
	if (done) done(NO);
}

/**
 Esce dalla griglia. Riprova: a volte la prima card non e' ancora "pronta"
 dopo la chiusura dell'ad, e un solo tentativo lascia Safari in Mostra pannelli.
 */
static void MiaoLeaveTabGrid(NSInteger tries, void (^done)(BOOL onSite)) {
	if (!MiaoInTabOverview() && MiaoSiteIsFront()) {
		if (done) done(YES);
		return;
	}
	if (tries >= 6) {
		MiaoLog([NSString stringWithFormat:@"griglia: uscita fallita dopo %ld\n%@",
			(long)tries, MiaoAXDump()]);
		if (done) done(MiaoSiteIsFront() && !MiaoInTabOverview());
		return;
	}

	MiaoAXNode *card = MiaoSiteCard();
	MiaoAXNode *fine = MiaoAXFind(MiaoNamesDone());
	/* Dopo il primo miss, Fine e' piu' affidabile della miniatura. */
	if (fine && tries >= 1) {
		MiaoTapNode(fine, @"fine");
	} else if (card) {
		MiaoTapNode(card, @"scheda sito");
	} else if (fine) {
		MiaoTapNode(fine, @"fine");
	} else {
			/* ultima carta: tocca la card piu' grande in schermo (spesso e' la nostra
			   dopo aver chiuso l'ad: resta una sola scheda) */
			MiaoAXNode *biggest = nil;
			CGFloat best = 0;
			for (MiaoAXNode *n in MiaoAXNodes()) {
				CGFloat a = n.frame.size.width * n.frame.size.height;
				if (n.frame.size.width < 100 || n.frame.size.height < 120) continue;
				if (a > best) { best = a; biggest = n; }
			}
		if (biggest) MiaoTapNode(biggest, @"scheda unica");
		else {
			MiaoLog([NSString stringWithFormat:@"griglia: niente da toccare\n%@", MiaoAXDump()]);
			if (done) done(NO);
			return;
		}
	}

	MiaoAfter(MiaoHumanDelay(0.9, 0.5), ^{
		if (MiaoSiteIsFront() && !MiaoInTabOverview()) {
			if (done) done(YES);
			return;
		}
		MiaoLeaveTabGrid(tries + 1, done);
	});
}

/**
 Siamo in modalita' navigazione (pagina piena), non nella griglia.
 Se siamo in overview esce; non apre di nuovo Schede (quello peggiora lo stato).
 Se davanti c'e' un ad, restituisce NO: il recupero ads e' compito di
 EnsureSiteFront / CloseAdsHuman.
 */
static void MiaoEnsureBrowsing(void (^done)(BOOL ok)) {
	if (MiaoSiteIsFront() && !MiaoInTabOverview()) {
		if (done) done(YES);
		return;
	}
	if (MiaoInTabOverview()) {
		MiaoToast(@"Esco dai pannelli");
		MiaoReturnToSiteTab(^(BOOL ok) {
			MiaoLog([NSString stringWithFormat:@"browsing via scheda sito %d", ok]);
			if (done) done(ok);
		});
		return;
	}
	/* non overview ma neanche sito davanti: c'e' un ad o una pagina vuota */
	if (done) done(NO);
}

/// Ultimo tentativo: Fine / scheda Nox / API schede — niente openURL (nuovi pop).
static void MiaoRecoverFromOverview(void (^done)(BOOL ok)) {
	if (MiaoSiteIsFront() && !MiaoInTabOverview()) {
		if (done) done(YES);
		return;
	}
	MiaoToast(@"Rientro…");
	MiaoReturnToSiteTab(^(BOOL ok) {
		if (ok) {
			if (done) done(YES);
			return;
		}
		MiaoAXNode *fine = MiaoAXFind(MiaoNamesDone());
		if (fine) MiaoTapNode(fine, @"fine-rec");
		MiaoAfter(1.2, ^{
			MiaoReturnToSiteTab(done);
		});
	});
}

/**
 Chiude le schede ads come a mano: quadrato → X su TUTTE le estranee →
 tap sulla scheda NoxReel. Niente openURL.
 */
static void MiaoCloseAdTabNative(void (^done)(BOOL ok)) {
	void (^closeThenLeave)(void) = ^{
		MiaoCloseAllForeignInGrid(8, 0, ^(NSInteger n) {
			MiaoLog([NSString stringWithFormat:@"griglia: chiuse %ld X", (long)n]);
			MiaoAfter(MiaoBetween(0.45, 0.85), ^{
				MiaoLeaveTabGrid(0, ^(BOOL onSite) {
					if (onSite && MiaoForeignTabCount() == 0) {
						if (done) done(YES);
						return;
					}
					/* Ancora estranee: ripeti X senza riaprire Schede. */
					if (MiaoInTabOverview() && MiaoForeignTabCount() > 0) {
						MiaoCloseAllForeignInGrid(6, 0, ^(NSInteger n2) {
							(void)n2;
							MiaoLeaveTabGrid(0, ^(BOOL on2) {
								if (done) done(on2 && MiaoSiteIsFront() && !MiaoInTabOverview());
							});
						});
						return;
					}
					MiaoReturnToSiteTab(^(BOOL ok) { if (done) done(ok); });
				});
			});
		});
	};

	if (MiaoInTabOverview()) {
		MiaoLog(@"UI nativa: gia' in panoramica, chiudo tutte le ads");
		closeThenLeave();
		return;
	}

	MiaoAXNode *tabs = MiaoAXFind(MiaoNamesTabs());
	MiaoToast(@"Schede...");
	BOOL opened = NO;
	if (tabs) opened = MiaoTapNode(tabs, @"schede");
	if (!opened) opened = MiaoTapPt(MiaoPtTabs(), @"schede-quadrato");
	if (!opened) {
		MiaoLog([NSString stringWithFormat:@"UI nativa: quadrato schede non toccato\n%@", MiaoAXDump()]);
		if (done) done(NO);
		return;
	}

	MiaoAfter(MiaoHumanDelay(1.2, 0.9), ^{
		closeThenLeave();
	});
}

/**
 Torna indietro con lo swipe dal bordo, come si fa col pollice. Se la pagina non
 cambia prova il pulsante Indietro della barra. `history.back()` resta fuori:
 e' una chiamata che una persona non puo' fare.
 */
static void MiaoGoBackHuman(void (^done)(BOOL ok)) {
	NSString *pathJS = @"(function(){return location.pathname;})()";
	// il confronto prima/dopo va fatto sulla pagina che si vede, altrimenti un
	// path che non cambia perche' stiamo leggendo un'altra scheda diventa "back
	// fallito" anche quando lo swipe e' andato a buon fine
	MiaoJSFront(pathJS, ^(NSString *before) {
		NSString *from = before ?: @"";
		UIView *wk = MiaoFrontWebView() ?: MiaoBestWebView();
		UIWindow *win = wk.window;
		CGRect b = win ? win.bounds : UIScreen.mainScreen.bounds;
		CGFloat y = b.size.height * (0.42 + (CGFloat)MiaoRnd() * 0.2);
		CGPoint p0 = CGPointMake(2 + (CGFloat)MiaoRnd() * 4, y);
		CGPoint p1 = CGPointMake(b.size.width * (0.55 + (CGFloat)MiaoRnd() * 0.25), y + MiaoNudge(16));

		NSString *why = nil;
		BOOL sent = MiaoUIKitSwipe(p0, p1, 0.28 + MiaoRnd() * 0.14, &why, nil);
		MiaoLog([NSString stringWithFormat:@"back: swipe bordo %@ (%@)", sent ? @"ok" : @"NO", why ?: @"-"]);

		MiaoAfter(MiaoHumanDelay(1.6, 0.9), ^{
			MiaoJSFront(pathJS, ^(NSString *mid) {
				if (mid.length && ![mid isEqualToString:from]) {
					if (done) done(YES);
					return;
				}
				MiaoAXNode *back = MiaoAXFind(MiaoNamesBack());
				if (!back || !MiaoTapNode(back, @"indietro")) {
					MiaoLog([NSString stringWithFormat:@"back: nessun pulsante\n%@", MiaoAXDump()]);
					if (done) done(NO);
					return;
				}
				MiaoAfter(MiaoHumanDelay(1.6, 0.9), ^{
					MiaoJSFront(pathJS, ^(NSString *after) {
						if (done) done(after.length && ![after isEqualToString:from]);
					});
				});
			});
		});
	});
}

/**
 Riporta il sito in primo piano provando le vie in ordine di realismo e
 verificando dopo ogni tentativo, invece di dare per riuscito il primo.
 */
static void MiaoEnsureSiteFront(void (^done)(BOOL ok)) {
	if (!MiaoIsSafari()) {
		if (done) done(NO);
		return;
	}
	/* Prima di tutto: se siamo in Mostra pannelli, esci. Riaprire Schede qui
	   peggiora lo stato (griglia su griglia) ed e' quello che ha lasciato il
	   run a scrollare i pannelli. */
	if (MiaoInTabOverview()) {
		MiaoEnsureBrowsing(done);
		return;
	}
	if (MiaoSiteIsFront()) {
		if (done) done(YES);
		return;
	}
	MiaoAck([NSString stringWithFormat:@"sito non in primo piano, recupero\n%@", MiaoWebState()]);

	MiaoCloseAdTabNative(^(BOOL nativeOk) {
		if (nativeOk && MiaoSiteIsFront() && !MiaoInTabOverview()) {
			MiaoAck(@"tornato sul sito dalla UI di Safari");
			if (done) done(YES);
			return;
		}
		MiaoGoBackHuman(^(BOOL back) {
			(void)back;
			MiaoAfter(0.8, ^{
				if (MiaoInTabOverview()) {
					MiaoEnsureBrowsing(done);
					return;
				}
				if (MiaoSiteIsFront()) {
					MiaoLog(@"front ok via back");
					if (done) done(YES);
					return;
				}
				MiaoSelectSiteTab();
				MiaoAfter(1.0, ^{
					if (MiaoSiteIsFront() && !MiaoInTabOverview()) {
						MiaoLog(@"front ok via API schede");
						if (done) done(YES);
						return;
					}
					/* Niente openURL: nuova tab = nuovi popunder. Solo scheda esistente. */
					MiaoReturnToSiteTab(^(BOOL ok) {
						MiaoAck([NSString stringWithFormat:@"recupero %@\n%@",
							ok ? @"ok via scheda" : @"FALLITO", MiaoWebState()]);
						if (done) done(ok);
					});
				});
			});
		});
	});
}

/**
 Chiude le pagine ads dopo che l'impression e' stata registrata: prima con la UI
 di Safari, e solo se quella strada non porta a casa con `window.close()`.
 */
static void MiaoCloseAdsHuman(void (^done)(BOOL siteFront)) {
	NSInteger before = MiaoForeignTabCount();
	if (before <= 0 && !MiaoForeignFront()) {
		MiaoEnsureBrowsing(^(BOOL ok) { if (done) done(ok); });
		return;
	}

	void (^viaSafariUI)(void) = ^{
		MiaoCloseAdTabNative(^(BOOL nativeOk) {
			if (nativeOk && MiaoSiteIsFront() && !MiaoInTabOverview()) {
				MiaoAck([NSString stringWithFormat:@"ads chiuse da Schede (%ld -> %ld)",
					(long)before, (long)MiaoForeignTabCount()]);
				if (done) done(YES);
				return;
			}
			/* Niente window.close / openURL. Torna sulla scheda Nox. */
			MiaoReturnToSiteTab(^(BOOL ok) {
				if (done) done(ok && MiaoSiteIsFront() && !MiaoInTabOverview());
			});
		});
	};

	/* Come a mano: quadrato Schede → X su tutte → tap scheda sito. */
	viaSafariUI();
}

#pragma mark - Loop ads

/**
 Il giro completo che serve al sito:

 1. torna sulla scheda del sito (l'ad ruba il primo piano) e, se il tap
    precedente ci ha portati su `/video/`, risali alla home con lo swipe
 2. scegli un video a caso, scorri fino a lui e tappalo con un touch umano
 3. lascia caricare l'impression, poi chiudi la scheda ads dalla UI di Safari
 4. ripeti

 Gira dentro Safari: le schede, il JS e il tap stanno tutti qui, quindi non
 dipende dai tempi indovinati da SpringBoard.
 */
static NSInteger gLoopLeft = 0;
static NSInteger gLoopAds = 0;
static NSInteger gLoopTaps = 0;
static BOOL gLoopBusy = NO;

static void MiaoLoopStep(void);

static void MiaoLoopFinish(void) {
	gLoopBusy = NO;
	if (!MiaoDebug()) MiaoCleanProbe(nil);
	MiaoAck([NSString stringWithFormat:@"loop fine tap=%ld ads=%ld", (long)gLoopTaps, (long)gLoopAds]);
	MiaoToast([NSString stringWithFormat:@"Loop fine %ld tap %ld ads", (long)gLoopTaps, (long)gLoopAds]);
}

static void MiaoLoopAfterTap(void) {
	NSInteger ads = MiaoForeignTabCount();
	if (ads <= 0) {
		// nessun popunder: normale, Exo ha un frequency cap per utente
		MiaoAfter(MiaoHumanDelay(0.9, 1.0), ^{ MiaoLoopStep(); });
		return;
	}
	gLoopAds += ads;
	MiaoToast([NSString stringWithFormat:@"Ads +%ld", (long)ads]);
	// resta sull'ad quanto basta a registrare l'impression, poi chiudi
	MiaoAfter(MiaoHumanDelay(2.2, 1.8), ^{
		MiaoCloseAdsHuman(^(BOOL siteFront) {
			MiaoAck([NSString stringWithFormat:@"loop: ads chiuse, sito davanti=%d", siteFront]);
			MiaoAfter(MiaoHumanDelay(1.1, 0.9), ^{ MiaoLoopStep(); });
		});
	});
}

static void MiaoLoopTap(void) {
	MiaoInstallProbe(nil);
	MiaoPickThumb(^(NSInteger idx) {
		if (idx < 0) {
			MiaoAck(@"loop: nessun thumb");
			MiaoToast(@"Loop no thumb");
			MiaoAfter(MiaoHumanDelay(1.5, 1.0), ^{ MiaoLoopStep(); });
			return;
		}
		MiaoScrollToThumb(idx, 0, ^(BOOL ok, NSString *raw) {
			if (!ok) {
				MiaoAck([NSString stringWithFormat:@"loop: thumb %ld non raggiunto (%@)", (long)idx, raw]);
				MiaoAfter(MiaoHumanDelay(1.2, 0.8), ^{ MiaoLoopStep(); });
				return;
			}
			MiaoAfter(MiaoHumanDelay(0.45, 0.9), ^{
				MiaoTapThumb(idx, @"loop", ^(BOOL tapped) {
					if (!tapped) {
						MiaoAfter(MiaoHumanDelay(1.2, 0.8), ^{ MiaoLoopStep(); });
						return;
					}
					gLoopTaps++;
					MiaoAfter(MiaoHumanDelay(2.6, 1.8), ^{ MiaoLoopAfterTap(); });
				});
			});
		});
	});
}

static void MiaoLoopStep(void) {
	if (gLoopLeft <= 0) {
		MiaoLoopFinish();
		return;
	}
	gLoopLeft--;
	MiaoToast([NSString stringWithFormat:@"Loop %ld", (long)(gLoopLeft + 1)]);

	// Niente tap finche' il sito non e' davvero davanti
	MiaoEnsureSiteFront(^(BOOL front) {
		if (!front) {
			MiaoToast(@"Sito non davanti");
			MiaoAfter(MiaoHumanDelay(2.5, 1.5), ^{ MiaoLoopStep(); });
			return;
		}
		MiaoRememberSiteTitle();
		MiaoJS(@"(function(){return location.pathname;})()", ^(NSString *path) {
			if (!path.length) {
				MiaoOpenURL(MiaoHomeURL());
				MiaoAfter(MiaoHumanDelay(3.0, 1.5), ^{ MiaoLoopTap(); });
				return;
			}
			if (![path containsString:@"/video/"]) {
				MiaoAfter(MiaoHumanDelay(0.7, 0.9), ^{ MiaoLoopTap(); });
				return;
			}
			// il tap precedente ha aperto il video: torna alla lista col pollice
			MiaoGoBackHuman(^(BOOL back) {
				if (!back) {
					MiaoAck(@"loop: indietro non ha funzionato, riapro la home");
					MiaoOpenURL(MiaoHomeURL());
				}
				MiaoAfter(MiaoHumanDelay(1.5, 1.2), ^{ MiaoLoopTap(); });
			});
		});
	});
}

static void MiaoActLoop(void) {
	if (gLoopBusy) {
		MiaoToast(@"Loop attivo");
		return;
	}
	gLoopBusy = YES;
	gLoopLeft = MiaoLoopTaps();
	gLoopAds = 0;
	gLoopTaps = 0;
	MiaoAck([NSString stringWithFormat:@"loop start %ld", (long)gLoopLeft]);
	MiaoToast([NSString stringWithFormat:@"Loop %ld click", (long)gLoopLeft]);
	MiaoLoopStep();
}

#pragma mark - Run singolo

/**
 Un passaggio solo, lineare, senza loop:

 1. sito in primo piano e sulla home
 2. scroll umano
 3. tap su una thumb: questo primo tap se lo prende il popunder
 4. chiudi la pagina ads e torna al sito
 5. ri-tap sulla STESSA thumb: adesso entra nel video
 6. aspetta che lo skip si sblocchi e tappalo

 Ogni passo verifica il proprio effetto prima di passare al successivo.
 */
static BOOL gRunBusy = NO;
static NSInteger gRunSkipTries = 0;
static NSInteger gRunTapTries = 0;
static NSInteger gRunThumb = -1;
static NSInteger gRunVideosLeft = 1;
static BOOL gRunDidFS = NO;
static BOOL gRunSecondVideo = NO;
static NSInteger gRunRescueTries = 0;

static void MiaoRunPickAndTap(void);
static void MiaoRunAfterFirstTap(void);
static void MiaoRunSecondTap(void);
static void MiaoRunWaitSkip(void);
static void MiaoRunContinueToVideo(NSString *why);
static void MiaoRunEnd(NSString *msg, BOOL ok);
static void MiaoRunWatchThenEnd(NSString *msg);
static void MiaoRunNextOrEnd(NSString *msg);

/// Un passo con esito: finisce nel log leggibile e nel report del pannello.
static void MiaoStepResult(NSString *name, BOOL ok, NSString *detail) {
	MiaoReportStep(name, ok, detail);
	MiaoLog([NSString stringWithFormat:@"step %@ %@ %@",
		name, ok ? @"OK" : @"KO", detail ?: @""]);
}

/**
 Stato del VIDEO DEL SITO, non del preroll.

 Formato: `playing|path|cur|dur|content` oppure `novideo|...|0|0|none`.
 Il quinto campo e' `content` solo se e' `data-nox-content` o un <video>
 sulla pagina /video/ che non sembra un ad. Senza questo il preroll
 "playing" faceva chiudere il run prima dello skip e del contenuto.
 */
static NSString *const kMiaoJSVideoState =
	@"(function(){"
	@"var path=location.pathname||'';"
	@"var onVid=path.indexOf('/video/')>=0;"
	@"function mark(el){"
	@"  var s=((el.currentSrc||el.src||'')+' '+(el.id||'')+' '+(el.className||'')+' '+(el.getAttribute('data-name')||'')).toLowerCase();"
	@"  if(/ad|vast|ima|preroll|midroll|companion/.test(s)) return 'ad';"
	@"  if(el.hasAttribute('data-ad')||el.hasAttribute('data-ima')) return 'ad';"
	@"  if(el.hasAttribute('data-nox-content')) return 'content';"
	@"  return onVid?'maybe':'other';"
	@"}"
	@"var content=document.querySelector('video[data-nox-content]');"
	@"var v=content;"
	@"if(!v&&onVid){"
	@"  var all=document.querySelectorAll('video');"
	@"  for(var i=0;i<all.length;i++){if(mark(all[i])!=='ad'){v=all[i];break;}}"
	@"}"
	@"if(!v) return 'novideo|'+path+'|0|0|none';"
	@"var kind=content?'content':mark(v);"
	@"var st=v.paused?'paused':'playing';"
	@"return st+'|'+path+'|'+Math.round(v.currentTime||0)+'|'+Math.round(v.duration||0)+'|'+kind;"
	@"})()";

/**
 Barra di avanzamento in coordinate viewport: preferisce un range/scrubber reale,
 altrimenti la fascia bassa del video. Niente seek via JS (`currentTime`).
 */
static NSString *const kMiaoJSScrubBar =
	@"(function(){"
	@"var v=document.querySelector('video[data-nox-content]');"
	@"if(!v){"
	@"  var all=document.querySelectorAll('video');"
	@"  for(var i=0;i<all.length;i++){"
	@"    var s=((all[i].currentSrc||all[i].src||'')+' '+(all[i].id||'')+' '+(all[i].className||'')).toLowerCase();"
	@"    if(/ad|vast|ima|preroll/.test(s)) continue;"
	@"    if(location.pathname.indexOf('/video/')>=0){v=all[i];break;}"
	@"  }"
	@"}"
	@"if(!v) return 'NONE';"
	@"var bar=document.querySelector('input[type=range]')"
	@"||document.querySelector('[class*=\"progress\"],[class*=\"scrub\"],[class*=\"seek\"]');"
	@"var left,top,w,h;"
	@"if(bar){var r=bar.getBoundingClientRect(); left=r.left; top=r.top; w=r.width; h=r.height;}"
	@"else{var r=v.getBoundingClientRect(); left=r.left+10; top=r.bottom-20; w=Math.max(48,r.width-20); h=16;}"
	@"if(w<40) return 'NONE';"
	@"var y=top+h*0.5;"
	@"var x0=left+w*0.10;"
	@"var x1=left+w*(0.32+Math.random()*0.40);"
	@"if(x1-x0<24) x1=x0+28;"
	@"return 'SCRUB|'+Math.round(x0)+','+Math.round(y)+'|'+Math.round(x1)+','+Math.round(y);"
	@"})()";

/// True solo se il video DEL SITO sta playando, non un preroll.
static BOOL MiaoIsContentPlaying(NSString *st) {
	if (![st hasPrefix:@"playing"]) return NO;
	NSArray *sp = [st componentsSeparatedByString:@"|"];
	NSString *path = sp.count > 1 ? sp[1] : @"";
	NSInteger cur = sp.count > 2 ? [sp[2] integerValue] : 0;
	NSString *kind = sp.count > 4 ? sp[4] : @"";
	if (![path containsString:@"/video/"]) return NO;
	if ([kind isEqualToString:@"ad"] || [kind isEqualToString:@"none"] || [kind isEqualToString:@"other"])
		return NO;
	/* content certo, o maybe con almeno 1s di play */
	if ([kind isEqualToString:@"content"]) return YES;
	return cur >= 1;
}

static void MiaoScrubVideoHuman(void (^done)(BOOL did)) {
	MiaoJSFront(kMiaoJSScrubBar, ^(NSString *r) {
		if (![r hasPrefix:@"SCRUB|"]) {
			if (done) done(NO);
			return;
		}
		NSArray *parts = [r componentsSeparatedByString:@"|"];
		CGPoint a = parts.count > 1 ? MiaoParseXY(parts[1]) : CGPointZero;
		CGPoint b = parts.count > 2 ? MiaoParseXY(parts[2]) : CGPointZero;
		UIView *front = MiaoFrontWebView();
		if (!front || a.x < 1 || b.x < 1) {
			if (done) done(NO);
			return;
		}
		MiaoCalLoad();
		CGPoint w0 = MiaoViewportToWindowIn(front, a);
		CGPoint w1 = MiaoViewportToWindowIn(front, b);
		w0.x += gCalDX; w0.y += gCalDY;
		w1.x += gCalDX; w1.y += gCalDY;
		NSString *why = nil;
		NSTimeInterval dur = MiaoBetween(0.38, 0.90);
		MiaoToast(@"Scrub…");
		BOOL ok = MiaoUIKitSwipe(w0, w1, dur, &why, ^{
			if (done) done(YES);
		});
		if (!ok) {
			MiaoLog([NSString stringWithFormat:@"scrub fail %@", why ?: @"?"]);
			if (done) done(NO);
		}
	});
}

static void MiaoExitFullscreenIfNeeded(void (^done)(void)) {
	if (!MiaoInNativeVideoFS()) {
		if (done) done();
		return;
	}
	MiaoTapPt(MiaoPtDoneFS(), @"esci-fs");
	MiaoAfter(MiaoHumanDelay(0.9, 0.6), ^{
		if (done) done();
	});
}

static void MiaoEnterFullscreen(void (^done)(BOOL ok)) {
	MiaoToast(@"Controlli");
	MiaoTapPt(MiaoPtShowControls(), @"mostra-controlli");
	MiaoAfter(MiaoBetween(0.55, 1.05), ^{
		MiaoToast(@"Schermo intero");
		MiaoTapPt(MiaoPtFullscreen(), @"fullscreen");
		MiaoAfter(MiaoBetween(1.1, 1.7), ^{
			if (MiaoInNativeVideoFS()) {
				if (done) done(YES);
				return;
			}
			MiaoTapPt(MiaoPtShowControls(), @"mostra-controlli-2");
			MiaoAfter(MiaoBetween(0.50, 0.90), ^{
				MiaoTapPt(MiaoPtFullscreen(), @"fullscreen-2");
				MiaoAfter(MiaoBetween(1.0, 1.6), ^{
					if (done) done(MiaoInNativeVideoFS());
				});
			});
		});
	});
}

/**
 Dopo il contenuto: schermo intero (tranne Mirato), resta ~2 min fermo.
 Fine nativo solo se siamo davvero in FS. Secondo video solo se il primo
 e' andato in fullscreen.
 */
static void MiaoRunNextOrEnd(NSString *msg) {
	BOOL another = (gRunVideosLeft > 1) && gRunDidFS && !gRunSecondVideo;
	if (another) {
		gRunVideosLeft--;
		gRunSecondVideo = YES;
		MiaoToast(@"Altro video…");
		MiaoStepResult(@"altro-video", YES, @"dopo FS");
		MiaoExitFullscreenIfNeeded(^{
			MiaoAfter(MiaoHumanDelay(1.0, 0.8), ^{
				gRunTapTries = 0;
				gRunSkipTries = 0;
				MiaoRunPickAndTap();
			});
		});
		return;
	}
	MiaoExitFullscreenIfNeeded(^{
		MiaoRunEnd(msg, YES);
	});
}

static void MiaoRunWatchThenEnd(NSString *msg) {
	BOOL wantFS = (gMood != 2);
	NSTimeInterval minWatch;
	if (gRunSecondVideo) minWatch = MiaoBetween(40.0, 70.0);
	else if (gMood == 4) minWatch = MiaoBetween(90.0, 120.0);
	else if (gMood == 2) minWatch = MiaoBetween(35.0, 65.0);
	else if (gMood == 3) minWatch = MiaoBetween(50.0, 80.0);
	else minWatch = MiaoBetween(100.0, 130.0); /* casual / curioso */

	void (^watchIdle)(BOOL inFS) = ^(BOOL inFS) {
		if (inFS) gRunDidFS = YES;
		MiaoStepResult(@"fullscreen", inFS, inFS ? @"player nativo" : @"non entrato");
		MiaoToast([NSString stringWithFormat:@"Guardo %.0fs%@", minWatch, inFS ? @" FS" : @""]);

		NSTimeInterval midAt = minWatch * (0.38 + MiaoRng() * 0.24);
		MiaoAfter(midAt, ^{
			if (inFS) {
				CGRect b = UIScreen.mainScreen.bounds;
				CGPoint peek = MiaoJitterPt(
					CGPointMake(CGRectGetMidX(b) + 70, CGRectGetMidY(b) + 40), 10);
				MiaoTapPt(peek, @"fs-tempo");
			} else {
				MiaoTapPt(MiaoPtShowControls(), @"tempo");
			}
		});

		MiaoAfter(minWatch, ^{
			MiaoStepResult(@"visione", YES,
				[NSString stringWithFormat:@"watch=%.0f fs=%d video=%ld",
					minWatch, gRunDidFS ? 1 : 0, (long)(gRunSecondVideo ? 2 : 1)]);
			MiaoRunNextOrEnd(msg);
		});
	};

	if (!wantFS) {
		watchIdle(NO);
		return;
	}
	MiaoEnterFullscreen(watchIdle);
}

/**
 Riporta Safari a uno stato noto: nessuna pagina esterna aperta, sito davanti.

 Senza questo il run successivo parte dove ha smesso il precedente, e i suoi
 passi misurano il residuo invece del comportamento vero.
 */
static void MiaoRunTeardown(void (^done)(void)) {
	if (!MiaoForeignFront() && MiaoForeignTabCount() == 0) {
		if (done) done();
		return;
	}
	MiaoCloseAdsHuman(^(BOOL siteFront) {
		MiaoStepResult(@"teardown", siteFront,
			[NSString stringWithFormat:@"estranee=%ld", (long)MiaoForeignTabCount()]);
		if (done) done();
	});
}

static void MiaoRunEnd(NSString *msg, BOOL ok) {
	gRunBusy = NO;
	// niente listener nostri lasciati sulla pagina quando non stiamo debuggando
	if (!MiaoDebug()) MiaoCleanProbe(nil);
	MiaoAck([NSString stringWithFormat:@"run %@: %@", ok ? @"OK" : @"KO", msg]);
	MiaoToast(ok ? [NSString stringWithFormat:@"Run OK %@", msg]
				 : [NSString stringWithFormat:@"Run stop: %@", msg]);
	/* Il teardown va registrato dentro la sessione, quindi prima della chiusura
	   del report: se la pulizia non riesce e' un'informazione che serve leggere
	   accanto al verdetto, non un dettaglio da perdere. */
	MiaoRunTeardown(^{
		MiaoReportEnd(ok, msg);
		if (MiaoReportLastWriteError().length)
			MiaoLog([NSString stringWithFormat:@"report end write ERR %@", MiaoReportLastWriteError()]);
		// SpringBoard aspetta questo per passare al passo successivo, invece di
		// tirare a indovinare quanto durera' il run
		notify_post("com.noxlab.miao.runend");
	});
}

/**
 Se Schede/pannelli falliscono: rientra sulla scheda Nox gia' aperta e ritenta
 il video. openURL home e' vietato a meta' run (nuovi popup in loop).
 */
static void MiaoRunContinueToVideo(NSString *why) {
	MiaoLog([NSString stringWithFormat:@"rescue %ld %@", (long)gRunRescueTries, why ?: @""]);
	MiaoStepResult(@"recupero", YES, why ?: @"");
	if (gRunRescueTries++ >= 3) {
		MiaoRunEnd(why.length ? why : @"recupero esaurito", NO);
		return;
	}
	if (MiaoFrontIsVideo() && !MiaoInTabOverview() && !MiaoForeignFront()) {
		gRunTapTries = 0;
		MiaoToast(@"Sul video");
		MiaoAfter(MiaoHumanDelay(0.8, 0.5), ^{ MiaoRunWaitSkip(); });
		return;
	}
	MiaoToast(@"Rientro scheda…");
	MiaoReturnToSiteTab(^(BOOL ok) {
		(void)ok;
		gRunTapTries = 0;
		MiaoAfter(MiaoHumanDelay(0.8, 0.6), ^{
			if (MiaoForeignFront() || MiaoForeignTabCount() > 0) {
				MiaoCloseAdsHuman(^(BOOL front) {
					(void)front;
					if (MiaoFrontIsVideo() && !MiaoForeignFront())
						MiaoRunWaitSkip();
					else
						MiaoRunPickAndTap();
				});
				return;
			}
			if (MiaoFrontIsVideo() && !MiaoForeignFront())
				MiaoRunWaitSkip();
			else
				MiaoRunPickAndTap();
		});
	});
}

/**
 6) aspetta il countdown VAST (>=10s sul sito) e tocca Skip in basso a destra
 del player. Poi play al centro. Niente scan DOM.
 */
static void MiaoRunWaitSkip(void) {
	if (MiaoForeignFront()) {
		MiaoStepResult(@"skip-attesa", NO, @"pagina esterna davanti, recupero");
		MiaoCloseAdsHuman(^(BOOL front) {
			if (!front) {
				MiaoRunContinueToVideo(@"pagina esterna davanti, sito non recuperato");
				return;
			}
			MiaoAfter(MiaoHumanDelay(0.8, 0.6), ^{ MiaoRunWaitSkip(); });
		});
		return;
	}

	NSTimeInterval wait = MiaoBetween(11.2, 14.8);
	MiaoToast([NSString stringWithFormat:@"Attendo skip %.0fs", wait]);
	MiaoAfter(wait, ^{
		MiaoToast(@"Skip");
		BOOL ok = MiaoTapPt(MiaoPtSkip(), @"skip");
		MiaoStepResult(@"skip", ok, @"zona basso-destra player");
		MiaoAfter(MiaoBetween(1.5, 2.6), ^{
			MiaoTapPt(MiaoPtPlay(), @"play-dopo-skip");
			MiaoAfter(MiaoBetween(1.2, 2.2), ^{
				MiaoRunWatchThenEnd(@"video");
			});
		});
	});
}

/// 5) secondo tap sullo STESSO video: il primo l'ha consumato il popunder
static void MiaoRunSecondTap(void) {
	/* Prima di chiedere path o scrollare: fuori da Mostra pannelli. */
	if (MiaoInTabOverview()) {
		MiaoEnsureBrowsing(^(BOOL ok) {
			if (!ok) {
				MiaoStepResult(@"ritorno-sito", NO, @"overview non recuperata");
				MiaoRunContinueToVideo(@"bloccato in Mostra pannelli");
				return;
			}
			MiaoAfter(MiaoHumanDelay(0.6, 0.5), ^{ MiaoRunSecondTap(); });
		});
		return;
	}

	/* La domanda "sono sul video?" va fatta alla pagina che si vede. Chiedendola
	   alla webview del sito mentre davanti c'e' un ad, la risposta e' sempre
	   quella che ci aspettiamo e non ci accorgiamo di essere altrove. */
	if (MiaoForeignFront() || !MiaoSiteIsFront()) {
		MiaoStepResult(@"ritorno-sito", NO, @"pagina esterna ancora davanti");
		MiaoCloseAdsHuman(^(BOOL front) {
			(void)front;
			MiaoEnsureSiteFront(^(BOOL ok) {
				if (!ok || MiaoInTabOverview()) {
					MiaoEnsureBrowsing(^(BOOL browsing) {
						if (!browsing) {
							MiaoRunContinueToVideo(@"pagina esterna davanti, sito non recuperato");
							return;
						}
						MiaoAfter(MiaoHumanDelay(0.8, 0.7), ^{ MiaoRunSecondTap(); });
					});
					return;
				}
				MiaoAfter(MiaoHumanDelay(0.8, 0.7), ^{ MiaoRunSecondTap(); });
			});
		});
		return;
	}

	if (MiaoFrontIsVideo()) {
		NSString *u = MiaoWebViewURL(MiaoFrontWebView());
		MiaoToast(@"Sul video");
		MiaoStepResult(@"pagina-video", YES, u ?: @"");
		gRunSkipTries = 0;
		MiaoAfter(MiaoHumanDelay(1.5, 1.0), ^{ MiaoRunWaitSkip(); });
		return;
	}
	if (gRunTapTries++ > 2) {
		MiaoStepResult(@"pagina-video", NO, MiaoWebViewURL(MiaoFrontWebView()));
		MiaoRunContinueToVideo(@"il video non si apre");
		return;
	}
	MiaoToast([NSString stringWithFormat:@"Ri-click video (%ld)", (long)gRunTapTries]);
	MiaoAfter(MiaoHumanDelay(0.5, 0.8), ^{
		BOOL tapped = MiaoTapPt(MiaoPtThumb(gRunTapTries > 1 ? 1 : 0), @"video-2");
		MiaoStepResult(@"tap-video-2", tapped, tapped ? @"zona card" : @"tap rifiutato");
		MiaoAfter(MiaoHumanDelay(3.0, 1.5), ^{ MiaoRunSecondTap(); });
	});
}

/**
 Resta sull'ad come una persona: guarda, eventualmente clicca il creativo,
 scrolla un po', esita, poi chiude.

 Il click sul creativo e' quello che Relay puo' contare: aprire e chiudere la
 scheda senza toccare la landing non genera alcun click nel tag.
 */
static void MiaoLingerOnAd(void (^done)(void)) {
	NSTimeInterval budget = MiaoAdDwell();
	NSTimeInterval t0 = MiaoBetween(1.4, MIN(3.8, budget * 0.4));
	MiaoLog([NSString stringWithFormat:@"ad dwell total=%.1fs first=%.1fs mood=%ld",
		budget, t0, (long)gMood]);
	MiaoToast([NSString stringWithFormat:@"Ads… %.0fs", budget]);

	MiaoAfter(t0, ^{
		void (^afterClicks)(void) = ^{
			void (^finish)(void) = ^{
				NSTimeInterval hesitate = MiaoBetween(1.0, 3.0);
				MiaoAfter(hesitate, ^{ if (done) done(); });
			};

			CGRect area;
			BOOL canScroll = MiaoContentArea(&area);
			if (!canScroll) {
				finish();
				return;
			}
			CGFloat dy1 = 70 + (CGFloat)(MiaoRng() * 180);
			if (MiaoRng() < 0.35) dy1 = -dy1;
			MiaoGestureScroll(dy1, ^{
				MiaoAfter(MiaoBetween(0.7, 1.8), finish);
			});
		};

		/* Click sul creativo solo se la persona lo chiede. Sulle altre
		   si guarda l'ad e si chiude: cosi' Relay vede l'impression e
		   tu vedi davvero la landing, non un tap immediato che la fa sparire. */
		NSInteger clicks = 0;
		if (gMood == 3) clicks = 2 + (NSInteger)(MiaoRng() * 3); // 2-4
		else if (gMood == 0 && MiaoRng() < 0.16) clicks = 1;
		else if (gMood == 1 && MiaoRng() < 0.08) clicks = 1;

		if (clicks <= 0) {
			MiaoStepResult(@"ad-click", YES, @"guardata, nessun tap (persona)");
			afterClicks();
		} else {
			/* Centro landing: un dito, niente querySelector sul creativo. */
			void (^one)(void (^)(void)) = ^(void (^next)(void)) {
				BOOL ok = MiaoTapPt(MiaoPtAdCenter(), @"ad-centro");
				MiaoStepResult(@"ad-click", ok, @"tap centro landing");
				MiaoAfter(MiaoBetween(1.6, 3.2), ^{ if (next) next(); });
			};
			if (clicks == 1) {
				one(afterClicks);
			} else {
				MiaoToast([NSString stringWithFormat:@"Click ads x%ld", (long)clicks]);
				one(^{
					one(afterClicks);
				});
			}
		}
	});
}

/// 4) resta sull'ad il tempo di una persona, chiudi la scheda, torna al sito
static void MiaoRunAfterFirstTap(void) {
	NSInteger ads = MiaoForeignTabCount();
	if (ads <= 0 && !MiaoForeignFront()) {
		/* Nessun popunder non e' un errore del run: dipende dal frequency cap.
		   Va registrato come tale, altrimenti i risultati non si leggono. */
		MiaoStepResult(@"popunder", YES, @"nessuno (frequency cap)");
		MiaoRecoverFromOverview(^(BOOL ok) {
			if (!ok) {
				MiaoRunContinueToVideo(@"dopo tap: non sulla pagina");
				return;
			}
			MiaoRunSecondTap();
		});
		return;
	}
	MiaoStepResult(@"popunder", YES, [NSString stringWithFormat:@"%ld pagine esterne", (long)ads]);
	MiaoToast([NSString stringWithFormat:@"Ads +%ld", (long)ads]);

	MiaoLingerOnAd(^{
		MiaoToast(@"Chiudo ads");
		MiaoCloseAdsHuman(^(BOOL front) {
			(void)front;
			MiaoRecoverFromOverview(^(BOOL browsing) {
				BOOL ok = browsing && MiaoSiteIsFront() && !MiaoInTabOverview();
				MiaoStepResult(@"chiudi-ads", ok,
					[NSString stringWithFormat:@"estranee=%ld overview=%d front=%d",
						(long)MiaoForeignTabCount(),
						MiaoInTabOverview() ? 1 : 0, front ? 1 : 0]);
				if (!ok) {
					MiaoRunContinueToVideo(@"non torno sulla pagina (pannelli?)");
					return;
				}
				/* dopo la chiusura ci si riprende: non si ritappa subito */
				MiaoAfter(MiaoHumanDelay(1.2, 1.8), ^{ MiaoRunSecondTap(); });
			});
		});
	});
}

/**
 Scroll esplorativo prima di scegliere: 1-3 passate, a volte un po' indietro.
 Cosi' due sessioni non partono con lo stesso gesto unico.
 */
static void MiaoExploreHome(NSInteger left, void (^done)(void)) {
	if (left <= 0) {
		if (done) done();
		return;
	}
	/* Flick corti: 180–440 pt (vecchio curioso) mandavano la card
	   fuori schermo e il tap cadeva su titolo / sort / chip. */
	CGFloat dy = 90 + (CGFloat)(MiaoRng() * 80);
	if (gMood == 2) dy = 50 + (CGFloat)(MiaoRng() * 70);
	if (gMood == 0 || gMood == 4) dy = 80 + (CGFloat)(MiaoRng() * 90);
	if (MiaoRng() < 0.18) dy = -(50 + (CGFloat)(MiaoRng() * 70));
	MiaoGestureScroll(dy, ^{
		MiaoAfter(MiaoHumanDelay(0.7, 1.4), ^{
			MiaoExploreHome(left - 1, done);
		});
	});
}

static void MiaoRunTapHomeCard(NSInteger which) {
	MiaoToast(@"Click video");
	BOOL tapped = MiaoTapPt(MiaoPtThumb(which), @"video-1");
	MiaoStepResult(@"tap-video", tapped,
		[NSString stringWithFormat:@"card %ld %@", (long)which,
			tapped ? @"ok" : @"rifiutato"]);
	if (!tapped && which == 0) {
		MiaoAfter(MiaoHumanDelay(0.6, 0.5), ^{ MiaoRunTapHomeCard(1); });
		return;
	}
	if (!tapped) {
		MiaoRunContinueToVideo(@"primo tap non partito");
		return;
	}
	MiaoAfter(MiaoHumanDelay(3.0, 1.4), ^{
		if (!MiaoFrontIsVideo() && !MiaoForeignFront() && which == 0) {
			MiaoStepResult(@"tap-video", NO, @"non aperto, riprovo card sotto");
			MiaoRunTapHomeCard(1);
			return;
		}
		MiaoRunAfterFirstTap();
	});
}

/// 2-3) scroll a gesti, scelta del video, primo tap
static void MiaoRunPickAndTap(void) {
	if (MiaoInTabOverview() || !MiaoSiteIsFront()) {
		MiaoRecoverFromOverview(^(BOOL ok) {
			if (!ok) {
				MiaoStepResult(@"scroll", NO, @"non sulla pagina (pannelli)");
				MiaoRunContinueToVideo(@"non sulla pagina prima dello scroll");
				return;
			}
			MiaoAfter(0.5, ^{ MiaoRunPickAndTap(); });
		});
		return;
	}
	/* Secondo video: se il back e' rimasto su /video/, torna in home
	   oppure tocca una correlata sotto il player. */
	if (MiaoFrontIsVideo()) {
		MiaoGoBackHuman(^(BOOL back) {
			(void)back;
			MiaoAfter(MiaoHumanDelay(1.1, 0.8), ^{
				if (MiaoFrontIsVideo()) {
					MiaoToast(@"Correlato…");
					MiaoGestureScroll(200 + (CGFloat)(MiaoRng() * 80), ^{
						MiaoAfter(MiaoHumanDelay(0.5, 0.5), ^{
							BOOL tapped = MiaoTapPt(MiaoPtThumb(1), @"video-rel");
							MiaoStepResult(@"tap-video", tapped, @"correlata sotto player");
							MiaoAfter(MiaoHumanDelay(2.8, 1.4), ^{
								MiaoRunAfterFirstTap();
							});
						});
					});
					return;
				}
				MiaoRunPickAndTap();
			});
		});
		return;
	}
	/* Un passaggio solo: due flick + tap basso (curioso) uscivano dalla card. */
	NSInteger passes = 1;
	MiaoToast(@"Scroll…");
	MiaoExploreHome(passes, ^{
		MiaoStepResult(@"scroll", YES,
			[NSString stringWithFormat:@"mood=%ld passes=%ld", (long)gMood, (long)passes]);
		MiaoAfter(MiaoHumanDelay(0.7, 1.2), ^{
			MiaoRunTapHomeCard(0);
		});
	});
}


/// La home e' davanti: basta l'URL della scheda, niente scan DOM.
static void MiaoWaitReady(NSInteger tries, void (^done)(BOOL ok)) {
	BOOL ok = MiaoSiteIsFront() && !MiaoInTabOverview();
	if (ok && tries >= 3) {
		if (done) done(YES);
		return;
	}
	if (tries >= 10) {
		if (done) done(ok);
		return;
	}
	MiaoAfter(0.55, ^{ MiaoWaitReady(tries + 1, done); });
}

/// Quante volte il run ha rinviato la partenza aspettando la calibrazione.
static NSInteger gRunWaitCalib = 0;

/// 1) sito in primo piano, sulla home, con la pagina caricata
static void MiaoActRun(void) {
	if (gRunBusy) {
		MiaoToast(@"Run attivo");
		return;
	}
	/* La calibrazione tappa un punto vuoto e misura dove atterra: se il run
	   parte nel frattempo si scorre la pagina sotto la misura e il risultato
	   non vale niente (gProbeForce e' alto solo durante la calibrazione). */
	if (gProbeForce && gRunWaitCalib < 15) {
		gRunWaitCalib++;
		MiaoToast(@"Attendo calib");
		MiaoAfter(2.0, ^{ MiaoActRun(); });
		return;
	}
	gRunWaitCalib = 0;
	gRunBusy = YES;
	gRunTapTries = 0;
	gRunSkipTries = 0;
	gRunThumb = -1;
	gRunDidFS = NO;
	gRunSecondVideo = NO;
	gRunRescueTries = 0;
	MiaoToast(@"Run...");
	MiaoReportBegin(@"run", 0);
	MiaoPersonaBegin();
	/* Lunga: un video da ~2 min. Due partenze = due volte il rischio pannelli. */
	gRunVideosLeft = (gMood == 2 || gMood == 4) ? 1 : 2;
	if (MiaoReportLastWriteError().length) {
		MiaoLog([NSString stringWithFormat:@"report write ERR %@", MiaoReportLastWriteError()]);
		MiaoToast(@"Report: scrittura fallita");
	} else {
		MiaoLog([NSString stringWithFormat:@"report begin sid=%@", MiaoReportSid() ?: @"?"]);
	}

	MiaoEnsureSiteFront(^(BOOL front) {
		MiaoStepResult(@"sito-davanti", front, MiaoWebViewURL(MiaoFrontWebView()));
		if (!front) {
			MiaoRunContinueToVideo(@"sito non in primo piano");
			return;
		}
		MiaoRememberSiteTitle();

		/* Prima di partire la pagina deve esistere davvero. Con i tempi fissi il
		   run partiva su un DOM vuoto quando la rete era lenta, e il risultato
		   era "nessun video in pagina" su un sito che funziona. */
		void (^start)(void) = ^{
			MiaoWaitReady(0, ^(BOOL ready) {
				MiaoStepResult(@"home-pronta", ready, ready ? MiaoWebViewURL(MiaoFrontWebView()) : @"sito non davanti");
				if (!ready) {
					MiaoRunContinueToVideo(@"home non pronta");
					return;
				}
				MiaoAfter(MiaoHumanDelay(0.7, 1.2), ^{ MiaoRunPickAndTap(); });
			});
		};

		NSString *u = MiaoWebViewURL(MiaoFrontWebView());
		if (MiaoFrontIsVideo() && !MiaoInTabOverview()) {
			MiaoStepResult(@"gia-video", YES, u ?: @"");
			MiaoAfter(MiaoHumanDelay(1.0, 0.6), ^{ MiaoRunWaitSkip(); });
			return;
		}
		if (MiaoFrontIsVideo()) {
			MiaoRunContinueToVideo(@"video sotto i pannelli");
			return;
		}
		if (!u.length || !MiaoIsSiteURL(u)) {
			MiaoOpenURL(MiaoHomeURL());
			MiaoAfter(MiaoHumanDelay(1.5, 1.0), start);
			return;
		}
		start();
	});
}

#pragma mark - Safari cmd

static void MiaoHandle(NSString *cmd) {
	if (!MiaoIsSafari()) return;
	cmd = [[cmd lowercaseString] stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
	if (!cmd.length) return;
	MiaoLog([NSString stringWithFormat:@"handle %@", cmd]);
	MiaoToast([NSString stringWithFormat:@"> %@", cmd]);

	if ([cmd isEqualToString:@"ping"]) {
		MiaoAck(@"pong");
		MiaoToast(@"Safari OK");
	} else if ([cmd isEqualToString:@"clickvideo"]) {
		MiaoActClickVideo();
	} else if ([cmd isEqualToString:@"clickad"]) {
		MiaoActClickAd();
	} else if ([cmd isEqualToString:@"closeads"]) {
		NSInteger n = MiaoCloseNonNoxTabs();
		MiaoToast([NSString stringWithFormat:@"Ads chiuse %@", @(n)]);
	} else if ([cmd isEqualToString:@"skipad"]) {
		MiaoActSkip();
	} else if ([cmd isEqualToString:@"human"]) {
		MiaoActHumanWatch();
	} else if ([cmd isEqualToString:@"closeextra"]) {
		// le API private delle schede spesso non rispondono su iOS 16: qui serve
		// la via che funziona davvero, altrimenti il ciclo dopo parte sporco
		MiaoCloseAdsHuman(^(BOOL front) {
			MiaoToast(front ? @"Pulito" : @"Extra: sito NO");
		});
	} else if ([cmd isEqualToString:@"where"]) {
		MiaoActWhere(^(NSString *p) { MiaoToast(p ?: @"?"); });
	} else if ([cmd isEqualToString:@"calib"]) {
		MiaoActCalib();
	} else if ([cmd isEqualToString:@"run"]) {
		MiaoActRun();
	} else if ([cmd isEqualToString:@"adloop"]) {
		MiaoActLoop();
	} else if ([cmd isEqualToString:@"backsite"]) {
		MiaoEnsureSiteFront(^(BOOL ok) {
			MiaoToast(ok ? @"Su sito" : @"Sito non recuperato");
		});
	} else if ([cmd isEqualToString:@"state"]) {
		NSString *s = MiaoWebState();
		MiaoAck(s);
		MiaoToast([NSString stringWithFormat:@"WK %ld front=%@",
			(long)MiaoAllWebViews().count, MiaoSiteIsFront() ? @"sito" : @"ALTRO"]);
	} else if ([cmd isEqualToString:@"ax"]) {
		// come si chiamano davvero i controlli di Safari su questo device
		MiaoAck(MiaoAXDump());
		MiaoAXNode *tabs = MiaoAXFind(MiaoNamesTabs());
		MiaoToast([NSString stringWithFormat:@"AX %lu, schede=%@",
			(unsigned long)MiaoAXNodes().count, tabs ? @"ok" : @"NO"]);
	} else if ([cmd isEqualToString:@"scroll"]) {
		MiaoGestureScroll(220 + (CGFloat)arc4random_uniform(320), ^{
			MiaoToast(@"Scroll ok");
		});
	} else if ([cmd isEqualToString:@"back"]) {
		MiaoGoBackHuman(^(BOOL ok) { MiaoToast(ok ? @"Indietro ok" : @"Indietro NO"); });
	} else if ([cmd isEqualToString:@"clean"]) {
		MiaoCleanProbe(^{ MiaoToast(@"Sonda rimossa"); });
	}
}

static void MiaoConsumeFile(void) {
	NSString *raw = [NSString stringWithContentsOfFile:kCmdPath encoding:NSUTF8StringEncoding error:nil];
	if (!raw.length) return;
	[[NSFileManager defaultManager] removeItemAtPath:kCmdPath error:nil];
	NSString *cmd = [[raw componentsSeparatedByCharactersInSet:[NSCharacterSet newlineCharacterSet]] firstObject];
	MiaoHandle(cmd);
}

void MiaoStartSafari(void) {
	if (gSafariPollStarted || !MiaoIsSafari()) return;
	gSafariPollStarted = YES;
	MiaoLog(@"safari ready 0.14.4 chiudi-x");
	MiaoToast(@"Miao Safari ON");

	for (NSString *n in @[ @"ping", @"clickvideo", @"clickad", @"closeads", @"skipad", @"human",
						   @"closeextra", @"where", @"calib", @"run", @"adloop", @"backsite",
						   @"state", @"ax", @"scroll", @"back", @"clean" ]) {
		NSString *full = [NSString stringWithFormat:@"com.noxlab.miao.%@", n];
		int token = 0;
		notify_register_dispatch(full.UTF8String, &token, dispatch_get_main_queue(), ^(int t) {
			(void)t;
			NSString *raw = [NSString stringWithContentsOfFile:kCmdPath encoding:NSUTF8StringEncoding error:nil];
			if (raw.length) MiaoConsumeFile();
			else MiaoHandle(n);
		});
	}
	[NSTimer scheduledTimerWithTimeInterval:0.5 repeats:YES block:^(__unused NSTimer *tm) {
		MiaoConsumeFile();
	}];
}

#pragma mark - Session SB (orchestrator)

/**
 SpringBoard apre Safari e la home, poi manda un solo comando `run`: il flusso
 completo (scroll, click, ads, ri-click, skip) si svolge dentro Safari, dove
 ogni passo puo' verificare il proprio effetto.
 */
void MiaoAfter(NSTimeInterval sec, void (^block)(void)) {
	dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(sec * NSEC_PER_SEC)), dispatch_get_main_queue(), block);
}

/// Attesa dell'esito del run: Safari posta `runend` quando ha finito e
/// riportato. Il tetto di tempo esiste solo perche' Safari puo' morire.
static void (^gRunEndBlock)(void) = nil;
static BOOL gRunEndListening = NO;
static NSInteger gRunEndGen = 0;

static void MiaoRunEndListen(void) {
	if (gRunEndListening || !MiaoIsSB()) return;
	gRunEndListening = YES;
	int token = 0;
	notify_register_dispatch("com.noxlab.miao.runend", &token, dispatch_get_main_queue(), ^(int t) {
		(void)t;
		void (^b)(void) = gRunEndBlock;
		gRunEndBlock = nil;
		if (b) b();
	});
}

static void MiaoAwaitRunEnd(NSTimeInterval timeout, void (^done)(BOOL fromSafari)) {
	MiaoRunEndListen();
	NSInteger gen = ++gRunEndGen;
	gRunEndBlock = ^{
		if (gen != gRunEndGen) return;
		gRunEndGen++;
		if (done) done(YES);
	};
	MiaoAfter(timeout, ^{
		if (gen != gRunEndGen) return;
		gRunEndGen++;
		gRunEndBlock = nil;
		if (done) done(NO);
	});
}

static void MiaoRunCycle(NSInteger idx, NSInteger total, void (^done)(void)) {
	MiaoToast([NSString stringWithFormat:@"%@/%@ sessione...", @(idx + 1), @(total)]);
	MiaoLog([NSString stringWithFormat:@"cycle %ld", (long)idx]);

	/* Apri Safari, non la home ogni volta: openURL crea una scheda nuova
	   e lascia lo stack sporco (stessi cookie, N tab). Il run riusa la
	   scheda del sito e apre l'URL solo se serve davvero. */
	MiaoOpenSafari();

	MiaoAfter(2.2, ^{ MiaoSendCmd(@"ping"); });

	/* La calibrazione installa una sonda sulla pagina: si fa una volta sola e il
	   risultato resta su disco. Se c'e' gia', non la rifacciamo. */
	BOOL calibrated = [[NSFileManager defaultManager] fileExistsAtPath:kCalPath];
	NSTimeInterval runAt = 6.5;
	if (idx == 0 && !calibrated) {
		MiaoAfter(3.8, ^{ MiaoSendCmd(@"calib"); });
		// la calibrazione ora aspetta il DOM prima di misurare: diamole spazio
		runAt = 22.0;
	}

	/* Un solo passaggio, autonomo dentro Safari: scroll, click video, chiusura
	   ads, ri-click, attesa dello skip, skip. SpringBoard non scandisce i passi,
	   aspetta solo il verdetto. */
	MiaoAfter(runAt, ^{
		MiaoToast(@"Run...");
		MiaoSendCmd(@"run");
		/* Il passo successivo parte quando il run ha finito, non a un orario
		   deciso prima: con i tempi fissi mandavamo `human` e `closeextra` su un
		   run ancora in corso, e il ciclo dopo partiva su uno stato sporco. */
		MiaoAwaitRunEnd(520.0, ^(BOOL fromSafari) {
			MiaoLog(fromSafari ? @"cycle: run concluso" : @"cycle: timeout attesa run");
			if (!fromSafari) MiaoToast(@"Run: timeout");
			/* Niente `human`: erano scroll dopo la visione e uscivano dal FS. */
			MiaoAfter(1.4, ^{
				MiaoSendCmd(@"closeextra");
				MiaoAfter(2.0, ^{ if (done) done(); });
			});
		});
	});
}

/// Generazione della sessione: `stop` la incrementa e i passi ancora in coda,
/// che sono tutti dispatch_after gia' programmati, si accorgono e si spengono.
static NSInteger gSessionGen = 0;

static void MiaoStep(NSInteger i, NSInteger n, NSInteger gen);

static void MiaoStep(NSInteger i, NSInteger n, NSInteger gen) {
	if (gen != gSessionGen) {
		MiaoLog(@"session: passo annullato");
		return;
	}
	if (i >= n) {
		gSessionBusy = NO;
		MiaoToast(@"Fine sessione");
		MiaoLog(@"session end");
		return;
	}
	MiaoRunCycle(i, n, ^{
		MiaoAfter(1.0, ^{ MiaoStep(i + 1, n, gen); });
	});
}

static void MiaoSessionStop(void) {
	gSessionGen++;
	gRunEndGen++;
	gRunEndBlock = nil;
	gSessionBusy = NO;
	MiaoLog(@"session stop");
	MiaoToast(@"Sessione fermata");
}

/// `cycles` a 0 = quanti dicono le preferenze.
static void MiaoSessionRun(NSInteger cycles) {
	if (!MiaoIsSB()) return;
	if (gSessionBusy) {
		MiaoToast(@"Busy");
		return;
	}
	gSessionBusy = YES;
	NSInteger n = cycles > 0 ? MIN(cycles, 200) : MiaoCycles();
	MiaoReportEnsure();
	[@"" writeToFile:kLogPath atomically:YES encoding:NSUTF8StringEncoding error:nil];
	MiaoLog([NSString stringWithFormat:@"session 0.14.3 x%ld mood=%ld",
		(long)n, (long)gForcedMood]);
	MiaoToast([NSString stringWithFormat:@"Sessione x%ld %@...",
		(long)n, gForcedMood >= 0 ? MiaoMoodName(gForcedMood) : @"auto"]);
	/* Traccia batch da SpringBoard: cosi' il pannello vede qualcosa anche se
	   Safari non riesce ancora a scrivere gli step del singolo run. */
	MiaoReportBegin(@"batch", 0);
	MiaoReportStep(@"batch-start", YES,
		[NSString stringWithFormat:@"x%ld mood=%@", (long)n,
			gForcedMood >= 0 ? MiaoMoodName(gForcedMood) : @"auto"]);
	MiaoReportEnd(YES, [NSString stringWithFormat:@"avviato x%ld", (long)n]);
	MiaoStep(0, n, ++gSessionGen);
}

static void MiaoSession(void) {
	gForcedMood = -1;
	MiaoMoodWrite(-1);
	MiaoSessionRun(0);
}

/**
 Comandi che arrivano dal pannello. Vanno su un file loro: `miao-cmd.txt` lo
 consuma Safari con un poll, quindi un comando per SpringBoard scritto la'
 verrebbe mangiato dall'altro processo.
 */
static void MiaoStartSBCommands(void) {
	if (!MiaoIsSB()) return;
	static BOOL started = NO;
	if (started) return;
	started = YES;

	int t1 = 0, t2 = 0;
	notify_register_dispatch("com.noxlab.miao.session", &t1, dispatch_get_main_queue(), ^(int t) {
		(void)t;
		NSString *raw = [NSString stringWithContentsOfFile:kSbCmdPath
												 encoding:NSUTF8StringEncoding error:nil];
		if (!raw.length) {
			raw = [NSString stringWithContentsOfFile:
				@"/var/mobile/Library/Preferences/com.noxlab.miao.sbcmd.txt"
				encoding:NSUTF8StringEncoding error:nil];
		}
		[[NSFileManager defaultManager] removeItemAtPath:kSbCmdPath error:nil];
		[[NSFileManager defaultManager] removeItemAtPath:
			@"/var/mobile/Library/Preferences/com.noxlab.miao.sbcmd.txt" error:nil];
		NSString *line = [[raw componentsSeparatedByCharactersInSet:
			[NSCharacterSet newlineCharacterSet]] firstObject] ?: @"";
		NSArray *parts = [line componentsSeparatedByString:@" "];
		NSInteger n = 0;
		NSInteger mood = -1;
		for (NSUInteger i = 0; i < parts.count; i++) {
			NSString *tok = parts[i];
			if (!tok.length || [tok.lowercaseString isEqualToString:@"session"]) continue;
			NSInteger m = MiaoParseMoodToken(tok);
			if (m >= 0) { mood = m; continue; }
			NSInteger num = [tok integerValue];
			if (num > 0 || [tok isEqualToString:@"0"]) n = num;
		}
		gForcedMood = mood;
		MiaoMoodWrite(mood);
		MiaoLog([NSString stringWithFormat:@"pannello: sessione x%ld mood=%ld",
			(long)n, (long)mood]);
		MiaoSessionRun(n);
	});
	notify_register_dispatch("com.noxlab.miao.stop", &t2, dispatch_get_main_queue(), ^(int t) {
		(void)t;
		[[NSFileManager defaultManager] removeItemAtPath:kSbCmdPath error:nil];
		MiaoSessionStop();
	});
	MiaoRunEndListen();
}

#pragma mark - Volume

void MiaoVol(void) {
	if (!MiaoIsSB()) return;
	NSTimeInterval now = NSDate.date.timeIntervalSince1970;
	if (now - gLastVol < 0.45) return;
	gLastVol = now;
	if (gVolWindowStart <= 0 || (now - gVolWindowStart) > 2.2) {
		gVolWindowStart = now;
		gVolCount = 1;
		MiaoToast(@"1/3");
		return;
	}
	gVolCount++;
	if (gVolCount < 3) {
		MiaoToast([NSString stringWithFormat:@"%ld/3", (long)gVolCount]);
		return;
	}
	gVolCount = 0;
	gVolWindowStart = 0;
	MiaoSession();
}

void MiaoBoot(void) {
	if (gBootDone) return;
	gBootDone = YES;
	MiaoLog([NSString stringWithFormat:@"boot %@", NSBundle.mainBundle.bundleIdentifier ?: @"?"]);
	if (MiaoIsSB()) {
		MiaoReportEnsure();
		MiaoStartSBCommands();
		MiaoToast(@"Miao 0.14.3 - app o 3x Vol");
	} else if (MiaoIsSafari()) {
		MiaoReportEnsure();
		MiaoStartSafari();
	}
}

