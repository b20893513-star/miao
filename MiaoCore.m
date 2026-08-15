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

static NSInteger gVolCount = 0;
static NSTimeInterval gVolWindowStart = 0;
static NSTimeInterval gLastVol = 0;
static BOOL gBootDone = NO;
static BOOL gSessionBusy = NO;
static BOOL gSafariPollStarted = NO;

static NSString *const kPrefPath = @"/var/mobile/Library/Preferences/com.noxlab.miao.plist";
static NSString *const kHomeDefault = @"https://noxreel.uk/";
static NSString *const kCmdPath = @"/var/mobile/Documents/miao-cmd.txt";
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

static BOOL MiaoIsSiteURL(NSString *url) {
	return url.length && [url.lowercaseString containsString:MiaoSiteHost()];
}

/// Ritardo casuale: le pause identiche sono la firma piu' facile da riconoscere.
static NSTimeInterval MiaoHumanDelay(NSTimeInterval base, NSTimeInterval spread) {
	return base + (double)arc4random_uniform((uint32_t)MAX(1, spread * 1000.0)) / 1000.0;
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

/**
 Quando un popunder apre la scheda ads, la webview piu' grande e' quella
 DELL'AD: prendendo quella mandavamo tutto il JS sulla pagina sbagliata.
 Priorita': webview del sito visibile, poi webview del sito anche nascosta,
 infine la piu' grande visibile.
 */
static id MiaoBestWebView(void) {
	NSMutableArray *all = [NSMutableArray array];
	for (UIWindow *w in MiaoWindows()) MiaoFindWK(w, all);

	id siteVisible = nil, siteAny = nil, biggest = nil;
	CGFloat siteArea = 0, bigArea = 0;
	for (UIView *v in all) {
		BOOL visible = !v.hidden && v.alpha >= 0.05 && v.window;
		CGFloat area = v.bounds.size.width * v.bounds.size.height;
		BOOL site = MiaoIsSiteURL(MiaoWebViewURL(v));
		if (site && !siteAny) siteAny = v;
		if (site && visible && area > siteArea) { siteArea = area; siteVisible = v; }
		if (visible && area > bigArea) { bigArea = area; biggest = v; }
	}
	id pick = siteVisible ?: (siteAny ?: (biggest ?: all.lastObject));
	MiaoLog([NSString stringWithFormat:@"wk count %lu pick=%@ site=%d",
		(unsigned long)all.count, MiaoWebViewURL(pick), pick == siteVisible || pick == siteAny]);
	return pick;
}

static void MiaoJS(NSString *js, void (^done)(NSString *)) {
	id wk = MiaoBestWebView();
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
static CGPoint MiaoViewportToWindow(CGPoint vp) {
	UIView *wk = MiaoBestWebView();
	if (!wk) return vp;
	UIWindow *win = wk.window;
	CGPoint p = win ? [wk convertPoint:vp toView:win] : [wk convertPoint:vp toView:nil];
	CGRect fr = win ? [wk convertRect:wk.bounds toView:win] : wk.bounds;
	MiaoLog([NSString stringWithFormat:@"wkframe=%.0f,%.0f %.0fx%.0f vp=%.0f,%.0f -> win=%.0f,%.0f",
		fr.origin.x, fr.origin.y, fr.size.width, fr.size.height, vp.x, vp.y, p.x, p.y]);
	return p;
}

/// Punti finestra → schermo (serve solo all'HID worker).
static CGPoint MiaoWindowToScreen(CGPoint p) {
	UIView *wk = MiaoBestWebView();
	UIWindow *win = wk.window;
	if (!win) return p;
	return [win convertPoint:p toWindow:nil];
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

static NSString *const kMiaoProbeJS =
	@"(function(){"
	@"window.__miaoTap=null;"
	@"if(window.__miaoProbe) return 'READY';"
	@"window.__miaoProbe=1;"
	@"var h=function(e){try{"
	@"var t=(e.touches&&e.touches[0])||(e.changedTouches&&e.changedTouches[0])||e;"
	@"window.__miaoTap={x:Math.round(t.clientX),y:Math.round(t.clientY),"
	@"tr:(e.isTrusted?1:0),ty:e.type,t:Date.now()};"
	@"}catch(err){}};"
	@"document.addEventListener('touchstart',h,true);"
	@"document.addEventListener('mousedown',h,true);"
	@"document.addEventListener('click',h,true);"
	@"return 'OK';"
	@"})()";

static NSString *const kMiaoProbeReadJS =
	@"(function(){var t=window.__miaoTap;"
	@"return t?(t.x+','+t.y+'|'+t.tr+'|'+t.ty):'NONE';})()";

static void MiaoInstallProbe(void (^done)(void)) {
	MiaoJS(kMiaoProbeJS, ^(NSString *r) {
		MiaoLog([NSString stringWithFormat:@"probe %@", r ?: @"nil"]);
		if (done) done();
	});
}

/// Legge dove e' atterrato l'ultimo touch: CGPointZero se nessuno.
static void MiaoReadProbe(void (^done)(CGPoint landed, BOOL trusted, NSString *raw)) {
	MiaoJS(kMiaoProbeReadJS, ^(NSString *r) {
		if (!r.length || [r hasPrefix:@"NONE"]) {
			done(CGPointZero, NO, r ?: @"NONE");
			return;
		}
		NSArray *p = [r componentsSeparatedByString:@"|"];
		CGPoint q = MiaoParseXY(p.firstObject);
		BOOL tr = p.count > 1 && [p[1] isEqualToString:@"1"];
		done(q, tr, r);
	});
}

/// Path principale: coords viewport DOM → schermo (+ correzione) → HID worker.
static BOOL MiaoTrustedTapViewport(CGPoint vp, NSString *label) {
	if (vp.x < 1 && vp.y < 1) return NO;
	MiaoCalLoad();
	CGPoint win = MiaoViewportToWindow(vp);
	win.x += gCalDX;
	win.y += gCalDY;
	MiaoLog([NSString stringWithFormat:@"tap %@ vp=%.0f,%.0f win=%.0f,%.0f cal=%.0f,%.0f",
		label ?: @"", vp.x, vp.y, win.x, win.y, gCalDX, gCalDY]);
	return MiaoTrustedTapScreen(win, label);
}

/**
 Tappa un punto senza link e confronta richiesto vs atterrato.
 Toast: `CAL ok d=dx,dy` oppure `CAL NO TOUCH` (= HID non arriva alla pagina).
 */
static void MiaoActCalib(void) {
	MiaoToast(@"Calib...");
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
				MiaoToast(@"Calib no point");
				return;
			}
			NSArray *parts = [r componentsSeparatedByString:@"|"];
			CGPoint vp = MiaoParseXY(parts.firstObject);
			if (vp.x < 1 && vp.y < 1) {
				MiaoToast(@"Calib no point");
				return;
			}
			MiaoAck([NSString stringWithFormat:@"calib target %@", r]);

			// tap SENZA correzione: vogliamo misurare l'errore grezzo
			CGPoint win = MiaoViewportToWindow(vp);
			MiaoTrustedTapScreen(win, @"calib");

			MiaoAfter(1.3, ^{
				MiaoReadProbe(^(CGPoint landed, BOOL trusted, NSString *raw) {
					if (landed.x < 1 && landed.y < 1) {
						MiaoAck(@"calib NO TOUCH — HID non arriva al web content");
						MiaoToast(@"CAL NO TOUCH");
						return;
					}
					CGFloat dx = vp.x - landed.x;
					CGFloat dy = vp.y - landed.y;
					MiaoCalSave(dx, dy);
					MiaoAck([NSString stringWithFormat:@"calib ok raw=%@ want=%.0f,%.0f got=%.0f,%.0f d=%.0f,%.0f tr=%d",
						raw, vp.x, vp.y, landed.x, landed.y, dx, dy, trusted ? 1 : 0]);
					MiaoToast([NSString stringWithFormat:@"CAL ok d=%.0f,%.0f tr%d", dx, dy, trusted ? 1 : 0]);
				});
			});
		});
	});
}

static void MiaoRequestHidTap(CGPoint pt) {
	// usato da Skip zona / player: coords schermo
	MiaoTrustedTapScreen(pt, @"screen");
}

static void MiaoHumanTapAt(CGPoint pt, void (^done)(void)) {
	if (pt.x < 1 || pt.y < 1) {
		if (done) done();
		return;
	}
	MiaoTrustedTapScreen(pt, @"human");
	if (done) {
		dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.25 * NSEC_PER_SEC)), dispatch_get_main_queue(), done);
	}
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

static void MiaoActReady(void (^done)(BOOL ok)) {
	MiaoJS(@"(function(){return document.querySelectorAll('a[href*=\"/video/\"]').length+'|'+location.href;})()", ^(NSString *r) {
		BOOL ok = r && ![r hasPrefix:@"0|"];
		if (done) done(ok);
	});
}

/// Sceglie una thumb casuale, la memorizza in `__miaoTarget` e la porta a centro schermo.
static NSString *const kMiaoJSPickThumb =
	@"(function(){"
	@"var as=[].slice.call(document.querySelectorAll('a[href*=\"/video/\"]'));"
	@"if(!as.length) return 'NONE';"
	@"var cand=as.filter(function(x){var r=x.getBoundingClientRect();return r.width>=40&&r.height>=40;});"
	@"if(!cand.length) cand=as;"
	// thumb casuale: cliccare sempre la stessa e' il segnale piu' ovvio di un bot
	@"var a=cand[Math.floor(Math.random()*cand.length)];"
	// memorizza il target: il tap deve colpire QUESTO, non un altro ripescato dopo
	@"window.__miaoTarget=a;"
	@"try{a.scrollIntoView({block:'center',inline:'nearest',behavior:'instant'});}catch(e){try{a.scrollIntoView(true);}catch(e2){}}"
	@"var href=a.href||a.getAttribute('href')||'';"
	@"if(href&&href.indexOf('http')!==0) href=location.origin+href;"
	@"return 'SCROLL|'+href;"
	@"})()";

/**
 Punto del tap sul target memorizzato da `__miaoTarget`.
 Restituisce `x,y|HIT/MISS|elemento|href`, oppure `OFFSCREEN` se lo scroll non
 ha portato la thumb nel viewport.
 */
static NSString *const kMiaoJSThumbPoint =
	@"(function(){"
	@"var a=window.__miaoTarget;"
	@"if(!a||!a.getBoundingClientRect||!a.isConnected){"
	@"  var as=[].slice.call(document.querySelectorAll('a[href*=\"/video/\"]'));"
	@"  if(!as.length) return 'NONE';"
	@"  var best=null,bestArea=0;"
	@"  for(var i=0;i<as.length;i++){"
	@"    var rr=as[i].getBoundingClientRect();"
	@"    var vis=Math.max(0,Math.min(rr.bottom,window.innerHeight)-Math.max(rr.top,0));"
	@"    var area=Math.max(0,rr.width)*vis;"
	@"    if(area>bestArea&&rr.width>=40){bestArea=area;best=as[i];}"
	@"  }"
	@"  a=best||as[0];"
	@"}"
	@"var r=a.getBoundingClientRect();"
	@"if(r.bottom<40||r.top>window.innerHeight-20) return 'OFFSCREEN';"
	// punto casuale nella zona centrale: un dito non centra mai il pixel esatto
	@"var fx=0.5+(Math.random()-0.5)*0.56, fy=0.5+(Math.random()-0.5)*0.56;"
	@"var x=Math.round(r.left+r.width*fx), y=Math.round(r.top+r.height*fy);"
	@"x=Math.max(2,Math.min(window.innerWidth-2,x));"
	@"y=Math.max(4,Math.min(window.innerHeight-4,y));"
	@"var el=document.elementFromPoint(x,y);"
	@"var hit=el&&el.closest&&el.closest('a[href*=\"/video/\"]');"
	@"var href=a.href||'';"
	@"return x+','+y+'|'+(hit?'HIT':'MISS')+'|'+(el?(el.tagName+(el.className?'.'+String(el.className).slice(0,24):'')):'nil')+'|'+href;"
	@"})()";

static void MiaoActClickVideo(void) {
	MiaoToast(@"Thumb...");
	// 1) scegli+scrolla  2) aspetta il layout  3) leggi il punto  4) tap umano
	NSString *jsPoint = kMiaoJSThumbPoint;

	MiaoJS(kMiaoJSPickThumb, ^(NSString *sc) {
		if (!sc || [sc hasPrefix:@"NONE"]) {
			MiaoAck(@"click NONE");
			MiaoToast(@"Nessun thumb");
			return;
		}
		MiaoAck(sc);
		// sonda attiva: se il tap non naviga sapremo se e' arrivato e dove
		MiaoInstallProbe(nil);
		// lascia finire layout dopo scroll
		dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.45 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
			MiaoJS(jsPoint, ^(NSString *result) {
				if (!result || [result hasPrefix:@"NONE"]) {
					MiaoToast(@"Point NONE");
					return;
				}
				NSArray *parts = [result componentsSeparatedByString:@"|"];
				CGPoint vp = MiaoParseXY(parts.firstObject);
				NSString *hit = parts.count > 1 ? parts[1] : @"?";
				NSString *el = parts.count > 2 ? parts[2] : @"?";
				NSString *href = parts.count > 3 ? parts[3] : nil;
				MiaoAck([NSString stringWithFormat:@"point %@", result]);
				MiaoToast([NSString stringWithFormat:@"%@ %@", hit, el]);

				if (![hit isEqualToString:@"HIT"]) {
					MiaoAck(@"elementFromPoint miss — coords sbagliate");
					// prova comunque (a volte closest fallisce su overlay)
				}

				MiaoTrustedTapViewport(vp, @"thumb");

				dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(2.5 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
					MiaoJS(@"(function(){return location.pathname;})()", ^(NSString *path) {
						if (path && [path containsString:@"/video/"]) {
							MiaoAck(@"navigated OK");
							MiaoToast(@"Video OK");
							return;
						}
						// un retry con coords fresche
						MiaoJS(jsPoint, ^(NSString *r2) {
							CGPoint vp2 = MiaoParseXY([[r2 componentsSeparatedByString:@"|"] firstObject]);
							if (vp2.x > 1) MiaoTrustedTapViewport(vp2, @"thumb-retry");
							dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(2.2 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
								MiaoJS(@"(function(){return location.pathname;})()", ^(NSString *p3) {
									if (p3 && [p3 containsString:@"/video/"]) {
										MiaoToast(@"Video OK");
										return;
									}
									id allow = MiaoPrefs()[@"AllowJSVideoFallback"];
									if (allow && [allow boolValue] && href.length) {
										MiaoToast(@"JS video (NO ads)");
										NSString *go = [NSString stringWithFormat:
											@"(function(){location.assign('%@');return 'JS';})()",
											[[href stringByReplacingOccurrencesOfString:@"'" withString:@"\\'"]
												stringByReplacingOccurrencesOfString:@"\\" withString:@"\\\\"]];
										MiaoJS(go, ^(NSString *rr) { MiaoAck(rr ?: @"js"); });
									} else {
										// diagnosi: il touch e' arrivato alla pagina?
										MiaoReadProbe(^(CGPoint landed, BOOL trusted, NSString *raw) {
											if (landed.x < 1 && landed.y < 1) {
												MiaoAck(@"tap miss — nessun touch nel web content (HID non passa)");
												MiaoToast(@"Miss NO TOUCH");
											} else {
												MiaoAck([NSString stringWithFormat:@"tap miss — touch a %@ (voluto %.0f,%.0f)",
													raw, vp.x, vp.y]);
												MiaoToast([NSString stringWithFormat:@"Miss @%.0f,%.0f tr%d",
													landed.x, landed.y, trusted ? 1 : 0]);
											}
										});
									}
								});
							});
						});
					});
				});
			});
		});
	});
}

static void MiaoActSkip(void) {
	MiaoToast(@"Skip...");
	// Skip HTML e' disabled finche' countdown > 1s. Forziamo enable + click.
	// VAST Skip spesso e' dentro iframe same-origin /x/pr
	NSString *js =
		@"(function(){"
		@"function txt(el){return ((el&& (el.innerText||el.textContent))||'').trim();}"
		@"function isSkip(el){return /skip|salta|chiudi\\s*ad|close\\s*ad/i.test(txt(el));}"
		@"function tryClick(el){"
		@"  if(!el) return false;"
		@"  try{el.disabled=false;el.removeAttribute('disabled');}catch(e){}"
		@"  try{el.click();}catch(e){}"
		@"  try{el.dispatchEvent(new MouseEvent('click',{bubbles:true,cancelable:true,view:window}));}catch(e){}"
		@"  return true;"
		@"}"
		@"function scan(root){"
		@"  if(!root||!root.querySelectorAll) return null;"
		@"  var nodes=[].slice.call(root.querySelectorAll('button,a,[role=button],div,span'));"
		@"  var hit=nodes.find(function(x){return isSkip(x);});"
		@"  return hit||null;"
		@"}"
		@"var b=scan(document);"
		@"if(b&&tryClick(b)){"
		@"  var r=b.getBoundingClientRect();"
		@"  return 'SKIP|'+Math.round(r.left+r.width/2)+','+Math.round(r.top+r.height/2)+'|'+txt(b).slice(0,20);"
		@"}"
		@"var ifr=document.querySelectorAll('iframe');"
		@"for(var i=0;i<ifr.length;i++){"
		@"  try{"
		@"    var doc=ifr[i].contentDocument||(ifr[i].contentWindow&&ifr[i].contentWindow.document);"
		@"    var ib=scan(doc);"
		@"    if(ib&&tryClick(ib)){"
		@"      var ir=ib.getBoundingClientRect();"
		@"      var fr=ifr[i].getBoundingClientRect();"
		@"      return 'SKIP-IFRAME|'+Math.round(fr.left+ir.left+ir.width/2)+','+Math.round(fr.top+ir.top+ir.height/2);"
		@"    }"
		@"  }catch(e){}"
		@"}"
		@"return 'NONE';"
		@"})()";

	MiaoJS(js, ^(NSString *result) {
		if (!result || [result hasPrefix:@"NONE"]) {
			MiaoAck(@"skip NONE");
			CGRect b = UIScreen.mainScreen.bounds;
			CGFloat y = MIN(90 + b.size.width * 9.0 / 16.0 + 20, b.size.height * 0.62);
			MiaoTrustedTapScreen(CGPointMake(b.size.width * 0.82, y), @"skip-zona");
			MiaoToast(@"Skip zona");
			return;
		}
		NSArray *parts = [result componentsSeparatedByString:@"|"];
		if (parts.count >= 2) {
			CGPoint vp = MiaoParseXY(parts[1]);
			if (vp.x > 1) MiaoTrustedTapViewport(vp, @"skip");
		}
		MiaoAck([NSString stringWithFormat:@"skip %@", result]);
		MiaoToast(@"Skip OK+tap");
	});
}

/// Click ads: CTA preroll, learn more, exo real-href — PRIORITA' tap trusted (coords), JS solo info
static void MiaoActClickAd(void) {
	MiaoToast(@"Click ads...");
	NSString *js =
		@"(function(){"
		@"function visible(el){"
		@"  if(!el) return false;"
		@"  var r=el.getBoundingClientRect();"
		@"  return r.width>12&&r.height>12&&r.bottom>0&&r.top<window.innerHeight;"
		@"}"
		@"function pack(el,tag){"
		@"  if(!el||!visible(el)) return null;"
		@"  try{el.scrollIntoView({block:'center'});}catch(e){}"
		@"  var r=el.getBoundingClientRect();"
		@"  var h=el.getAttribute('real-href')||el.href||el.getAttribute('href')||'';"
		@"  return tag+'|'+Math.round(r.left+r.width/2)+','+Math.round(r.top+r.height/2)+'|'+(h||'').toString().slice(0,80);"
		@"}"
		@"var sels=["
		@"  'a.exo-native-widget-item[real-href]',"
		@"  'a.exo-native-widget-item',"
		@"  'a[real-href*=\"magsrv\"]',"
		@"  'a[real-href*=\"click.php\"]',"
		@"  '[real-href*=\"magsrv\"]',"
		@"  'a[href*=\"click.php\"]',"
		@"  'a[href*=\"magsrv\"]',"
		@"  'a[href*=\"exoclick\"]',"
		@"  'a[href*=\"realsrv\"]',"
		@"  '.ad-slot a[href]',"
		@"  '[class*=\"vast\"] a[href]',"
		@"  '[class*=\"preroll\"] a[href]'"
		@"];"
		@"for(var s=0;s<sels.length;s++){"
		@"  var nodes=[].slice.call(document.querySelectorAll(sels[s]));"
		@"  for(var i=0;i<nodes.length;i++){"
		@"    var el=nodes[i];"
		@"    var h=(el.getAttribute('real-href')||el.href||'').toLowerCase();"
		@"    var t=((el.innerText||'')+'').toLowerCase();"
		@"    if(/noxreel\\.uk/.test(h)&&!/click|out|go|redirect/.test(h)) continue;"
		@"    if(/skip|salta/.test(t)) continue;"
		@"    var r=pack(el,'AD');"
		@"    if(r) return r;"
		@"  }"
		@"}"
		@"var ctaRe=/learn\\s*more|visit|scopri|visita|continua|click\\s*here|vai\\s*al\\s*sito|annuncio|advertiser/i;"
		@"var btns=[].slice.call(document.querySelectorAll('a,button,[role=button]'));"
		@"for(var j=0;j<btns.length;j++){"
		@"  if(ctaRe.test((btns[j].innerText||'')+'')){"
		@"    var r2=pack(btns[j],'CTA');"
		@"    if(r2) return r2;"
		@"  }"
		@"}"
		@"var player=document.querySelector('[data-nox-preroll],iframe[data-nox-preroll],iframe[title=\"preroll\"]');"
		@"if(player){var r3=pack(player,'PREROLL'); if(r3) return r3;}"
		@"var box=document.querySelector('.relative.aspect-video, [class*=\"aspect-video\"]');"
		@"if(box){var r4=pack(box,'PLAYER'); if(r4) return r4;}"
		@"return 'NONE';"
		@"})()";

	MiaoJS(js, ^(NSString *result) {
		if (!result || [result hasPrefix:@"NONE"]) {
			MiaoAck(@"clickad NONE");
			CGRect b = UIScreen.mainScreen.bounds;
			MiaoTrustedTapScreen(CGPointMake(b.size.width * 0.5, MIN(200, b.size.height * 0.28)), @"ads-player");
			MiaoToast(@"Ads miss -> player");
			return;
		}
		NSArray *parts = [result componentsSeparatedByString:@"|"];
		NSString *tag = parts.firstObject ?: @"AD";
		CGPoint vp = parts.count >= 2 ? MiaoParseXY(parts[1]) : CGPointZero;
		MiaoAck([NSString stringWithFormat:@"clickad %@", result]);
		if (vp.x > 1) {
			MiaoTrustedTapViewport(vp, [NSString stringWithFormat:@"ad-%@", tag]);
			MiaoToast([NSString stringWithFormat:@"Ads tap %@", tag]);
		} else {
			MiaoToast([NSString stringWithFormat:@"Ads %@", tag]);
		}
	});
}

static void MiaoActOpenVideoURL(NSString *url) {
	if (url.length < 8) return;
	NSString *js = [NSString stringWithFormat:
		@"(function(){location.assign(%@);return location.href;})()",
		[NSString stringWithFormat:@"'%@'", [[url stringByReplacingOccurrencesOfString:@"\\" withString:@"\\\\"]
			stringByReplacingOccurrencesOfString:@"'" withString:@"\\'"]]];
	MiaoJS(js, ^(NSString *r) {
		MiaoAck([NSString stringWithFormat:@"openVideoURL %@", r ?: url]);
		MiaoToast(@"Goto video");
	});
}

static void MiaoActHumanWatch(void) {
	NSString *js =
		@"(function(){"
		@"var v=document.querySelector('video[data-nox-content],video');"
		@"if(v){try{v.currentTime=Math.min((v.duration||999),(v.currentTime||0)+10);v.muted=false;v.play();}catch(e){}}"
		@"window.scrollBy({top:260+Math.floor(Math.random()*180),left:0,behavior:'smooth'});"
		@"return (v?'seek10+':'')+'scroll|'+location.pathname;"
		@"})()";
	MiaoJS(js, ^(NSString *r) {
		MiaoAck([NSString stringWithFormat:@"human %@", r ?: @"?"]);
		MiaoToast([NSString stringWithFormat:@"Human %@", r ?: @"ok"]);
	});
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

/// Quante schede ads sono aperte adesso.
static NSInteger MiaoAdTabCount(void) {
	NSInteger n = 0;
	for (id tab in MiaoTabList(MiaoBrowser())) {
		NSString *u = MiaoTabURL(tab);
		if (u.length && !MiaoIsSiteURL(u)) n++;
	}
	return n;
}

#pragma mark - Loop ads

/**
 Il giro completo che serve al sito:

 1. torna sulla scheda del sito (l'ad ruba il primo piano) e, se il tap
    precedente ci ha portati su `/video/`, risali alla home con `history.back()`
 2. scegli una thumb casuale e tappala con un touch umano
 3. lascia caricare l'impression, poi chiudi la scheda ads
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
	MiaoAck([NSString stringWithFormat:@"loop fine tap=%ld ads=%ld", (long)gLoopTaps, (long)gLoopAds]);
	MiaoToast([NSString stringWithFormat:@"Loop fine %ld tap %ld ads", (long)gLoopTaps, (long)gLoopAds]);
}

static void MiaoLoopAfterTap(void) {
	NSInteger ads = MiaoAdTabCount();
	if (ads <= 0) {
		// nessun popunder: normale, Exo ha un frequency cap per utente
		MiaoAfter(MiaoHumanDelay(0.9, 1.0), ^{ MiaoLoopStep(); });
		return;
	}
	gLoopAds += ads;
	MiaoToast([NSString stringWithFormat:@"Ads +%ld", (long)ads]);
	// resta sull'ad quanto basta a registrare l'impression, poi chiudi
	MiaoAfter(MiaoHumanDelay(2.2, 1.8), ^{
		MiaoCloseNonNoxTabs();
		MiaoAfter(MiaoHumanDelay(1.1, 0.9), ^{ MiaoLoopStep(); });
	});
}

static void MiaoLoopTap(void) {
	MiaoInstallProbe(nil);
	MiaoJS(kMiaoJSPickThumb, ^(NSString *pick) {
		if (!pick.length || [pick hasPrefix:@"NONE"]) {
			MiaoAck([NSString stringWithFormat:@"loop no thumb (%@)", pick ?: @"nil"]);
			MiaoToast(@"Loop no thumb");
			MiaoAfter(MiaoHumanDelay(1.5, 1.0), ^{ MiaoLoopStep(); });
			return;
		}
		MiaoAfter(MiaoHumanDelay(0.5, 0.8), ^{
			MiaoJS(kMiaoJSThumbPoint, ^(NSString *res) {
				CGPoint vp = MiaoParseXY([[res componentsSeparatedByString:@"|"] firstObject]);
				if (vp.x < 1 && vp.y < 1) {
					MiaoAck([NSString stringWithFormat:@"loop point %@", res ?: @"nil"]);
					MiaoAfter(MiaoHumanDelay(1.2, 0.8), ^{ MiaoLoopStep(); });
					return;
				}
				gLoopTaps++;
				MiaoTrustedTapViewport(vp, @"loop");
				MiaoAfter(MiaoHumanDelay(2.6, 1.8), ^{ MiaoLoopAfterTap(); });
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

	MiaoSelectSiteTab();
	MiaoAfter(MiaoHumanDelay(0.6, 0.6), ^{
		MiaoJS(@"(function(){return location.pathname;})()", ^(NSString *path) {
			if (!path.length) {
				// nessuna webview del sito raggiungibile: riapri la home
				MiaoOpenURL(MiaoHomeURL());
				MiaoAfter(MiaoHumanDelay(3.0, 1.5), ^{ MiaoLoopTap(); });
				return;
			}
			if (![path containsString:@"/video/"]) {
				MiaoAfter(MiaoHumanDelay(0.7, 0.9), ^{ MiaoLoopTap(); });
				return;
			}
			// il tap precedente ha aperto il video: torna indietro come una persona
			MiaoJS(@"(function(){history.back();return 'back';})()", ^(NSString *r) {
				(void)r;
				MiaoAfter(MiaoHumanDelay(2.0, 1.2), ^{
					MiaoJS(@"(function(){return location.pathname;})()", ^(NSString *p2) {
						if (p2 && [p2 containsString:@"/video/"]) {
							MiaoAck(@"loop: back non ha funzionato, riapro la home");
							MiaoOpenURL(MiaoHomeURL());
						}
						MiaoAfter(MiaoHumanDelay(1.5, 1.2), ^{ MiaoLoopTap(); });
					});
				});
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
		NSInteger n = MiaoCloseNonNoxTabs();
		MiaoToast([NSString stringWithFormat:@"Extra %@", @(n)]);
	} else if ([cmd isEqualToString:@"where"]) {
		MiaoActWhere(^(NSString *p) { MiaoToast(p ?: @"?"); });
	} else if ([cmd isEqualToString:@"calib"]) {
		MiaoActCalib();
	} else if ([cmd isEqualToString:@"adloop"]) {
		MiaoActLoop();
	} else if ([cmd isEqualToString:@"backsite"]) {
		BOOL ok = MiaoSelectSiteTab();
		MiaoToast(ok ? @"Su sito" : @"Sito non trovato");
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
	MiaoLog(@"safari ready 0.9.2 adloop");
	MiaoToast(@"Miao Safari ON");

	for (NSString *n in @[ @"ping", @"clickvideo", @"clickad", @"closeads", @"skipad", @"human",
						   @"closeextra", @"where", @"calib", @"adloop", @"backsite" ]) {
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
 1 HOME
 2 Tap trusted sul thumb (BKS+bb) — unico modo per Exo popunder
 3 Niente location.assign di default (rompe ads)
 4 Skip / clickad / human
 */
void MiaoAfter(NSTimeInterval sec, void (^block)(void)) {
	dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(sec * NSEC_PER_SEC)), dispatch_get_main_queue(), block);
}

static NSArray<NSString *> *MiaoParseVideoHrefs(NSString *html) {
	if (!html.length) return @[];
	NSMutableOrderedSet *set = [NSMutableOrderedSet orderedSet];
	NSRegularExpression *re = [NSRegularExpression regularExpressionWithPattern:@"/video/([a-z0-9\\-]+)"
																		 options:NSRegularExpressionCaseInsensitive
																		   error:nil];
	for (NSTextCheckingResult *m in [re matchesInString:html options:0 range:NSMakeRange(0, html.length)]) {
		if (m.numberOfRanges < 2) continue;
		NSString *slug = [html substringWithRange:[m rangeAtIndex:1]].lowercaseString;
		if (slug.length > 1) [set addObject:[NSString stringWithFormat:@"https://noxreel.uk/video/%@", slug]];
	}
	return set.array;
}

static void MiaoFetchVideoURL(void (^cb)(NSString *url)) {
	NSString *home = MiaoHomeURL();
	NSURL *u = [NSURL URLWithString:home];
	if (!u) {
		cb(@"https://noxreel.uk/video/sessione-hardcore-di-notte");
		return;
	}
	NSMutableURLRequest *req = [NSMutableURLRequest requestWithURL:u];
	req.timeoutInterval = 18;
	[req setValue:@"Mozilla/5.0 (iPhone; CPU iPhone OS 16_2 like Mac OS X) AppleWebKit/605.1.15" forHTTPHeaderField:@"User-Agent"];
	[[[NSURLSession sharedSession] dataTaskWithRequest:req completionHandler:^(NSData *data, NSURLResponse *resp, NSError *err) {
		dispatch_async(dispatch_get_main_queue(), ^{
			NSArray *hrefs = nil;
			if (data && !err) {
				NSString *html = [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding];
				hrefs = MiaoParseVideoHrefs(html);
			}
			if (!hrefs.count) {
				hrefs = @[
					@"https://noxreel.uk/video/sessione-hardcore-di-notte",
					@"https://noxreel.uk/video/clip-amateur-allo-specchio",
					@"https://noxreel.uk/video/weekend-hardcore",
				];
			}
			NSString *pick = hrefs[arc4random_uniform((uint32_t)hrefs.count)];
			MiaoLog([NSString stringWithFormat:@"picked %@", pick]);
			cb(pick);
		});
	}] resume];
}

static void MiaoRunCycle(NSInteger idx, NSInteger total, void (^done)(void)) {
	NSString *home = MiaoHomeURL();
	NSTimeInterval watch = MiaoWatchSec();

	MiaoToast([NSString stringWithFormat:@"%@/%@ sessione...", @(idx + 1), @(total)]);
	MiaoLog([NSString stringWithFormat:@"cycle %ld", (long)idx]);

	MiaoFetchVideoURL(^(NSString *videoURL) {
		MiaoOpenSafari();
		MiaoAfter(1.0, ^{ MiaoOpenURL(home); });

		MiaoAfter(3.5, ^{ MiaoSendCmd(@"ping"); });

		// Prima sessione: misura l'errore viewport→schermo con la sonda JS
		if (idx == 0) MiaoAfter(4.6, ^{ MiaoSendCmd(@"calib"); });

		// Il loop fa tutto dentro Safari: tap, chiusura scheda ads, ritorno al sito
		MiaoAfter(8.5, ^{
			MiaoToast(@"Loop ads...");
			MiaoSendCmd(@"adloop");
		});

		// Il loop e' autonomo: qui stimiamo solo quando avra' finito
		NSTimeInterval loopEnd = 8.5 + MiaoLoopTaps() * 10.0 + 5.0;

		MiaoAfter(loopEnd - 1.0, ^{
			id allow = MiaoPrefs()[@"AllowJSVideoFallback"];
			if (allow && [allow boolValue]) {
				MiaoToast(@"Backup openURL");
				MiaoOpenURL(videoURL);
			} else {
				MiaoLog(@"skip backup openURL (keep ads path)");
			}
		});

		// Poi guarda un video come un utente: preroll, skip, scroll
		MiaoAfter(loopEnd, ^{ MiaoSendCmd(@"clickvideo"); });
		MiaoAfter(loopEnd + 4.0, ^{ MiaoSendCmd(@"closeads"); });
		MiaoAfter(loopEnd + 6.0, ^{ MiaoSendCmd(@"clickad"); });
		MiaoAfter(loopEnd + 9.0, ^{ MiaoSendCmd(@"clickad"); });
		MiaoAfter(loopEnd + 12.0, ^{ MiaoSendCmd(@"skipad"); });
		MiaoAfter(loopEnd + 14.0, ^{ MiaoSendCmd(@"skipad"); });
		MiaoAfter(loopEnd + 16.0, ^{ MiaoSendCmd(@"human"); });

		MiaoAfter(loopEnd + 16.0 + watch, ^{
			MiaoSendCmd(@"closeextra");
			MiaoAfter(1.5, ^{ if (done) done(); });
		});
	});
}

static void MiaoStep(NSInteger i, NSInteger n);

static void MiaoStep(NSInteger i, NSInteger n) {
	if (i >= n) {
		gSessionBusy = NO;
		MiaoToast(@"Fine sessione");
		MiaoLog(@"session end");
		return;
	}
	MiaoRunCycle(i, n, ^{
		MiaoAfter(1.0, ^{ MiaoStep(i + 1, n); });
	});
}

static void MiaoSession(void) {
	if (!MiaoIsSB() || gSessionBusy) {
		if (gSessionBusy) MiaoToast(@"Busy");
		return;
	}
	gSessionBusy = YES;
	[@"" writeToFile:kLogPath atomically:YES encoding:NSUTF8StringEncoding error:nil];
	MiaoLog(@"session 0.9.2 adloop");
	MiaoToast(@"Sessione 0.9.2...");
	MiaoStep(0, MiaoCycles());
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
	if (MiaoIsSB()) MiaoToast(@"Miao 0.9.2 - 3x Vol");
	else if (MiaoIsSafari()) MiaoStartSafari();
}

