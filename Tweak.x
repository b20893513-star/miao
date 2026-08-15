#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <objc/runtime.h>
#import <objc/message.h>
#import <CoreFoundation/CoreFoundation.h>
#import <notify.h>
#import "TouchSim.h"

static NSInteger gVolCount = 0;
static NSTimeInterval gVolWindowStart = 0;
static NSTimeInterval gLastVol = 0;
static BOOL gBootDone = NO;
static BOOL gSessionBusy = NO;
static BOOL gSafariPollStarted = NO;

static NSString *const kMiaoPrefPath = @"/var/mobile/Library/Preferences/com.noxlab.miao.plist";
static NSString *const kMiaoDefaultHome = @"https://noxreel.uk/";
static NSString *const kMiaoCmdPath = @"/var/mobile/Documents/miao-cmd.txt";
static NSString *const kMiaoAckPath = @"/var/mobile/Documents/miao-ack.txt";
static NSString *const kMiaoLogPath = @"/var/mobile/Documents/miao-loaded.txt";

#pragma mark - Utils

static void MiaoMarker(NSString *note) {
	NSString *line = [NSString stringWithFormat:@"%@ | %@\n", [NSDate date], note ?: @""];
	NSFileHandle *fh = [NSFileHandle fileHandleForWritingAtPath:kMiaoLogPath];
	if (!fh) {
		[line writeToFile:kMiaoLogPath atomically:YES encoding:NSUTF8StringEncoding error:nil];
		return;
	}
	[fh seekToEndOfFile];
	[fh writeData:[line dataUsingEncoding:NSUTF8StringEncoding]];
	[fh closeFile];
}

static __weak UILabel *gToastLab = nil;

static void MiaoToast(NSString *text) {
	dispatch_async(dispatch_get_main_queue(), ^{
		UIWindow *win = nil;
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations"
		win = UIApplication.sharedApplication.keyWindow;
#pragma clang diagnostic pop
		if (!win) {
			for (UIWindow *w in UIApplication.sharedApplication.windows) {
				if (w.isKeyWindow) { win = w; break; }
			}
		}
		if (!win && UIApplication.sharedApplication.windows.count) {
			win = UIApplication.sharedApplication.windows.firstObject;
		}
		if (!win) return;

		[gToastLab removeFromSuperview];
		UILabel *lab = [[UILabel alloc] initWithFrame:CGRectZero];
		lab.backgroundColor = [[UIColor blackColor] colorWithAlphaComponent:0.85];
		lab.textColor = UIColor.whiteColor;
		lab.font = [UIFont boldSystemFontOfSize:14];
		lab.textAlignment = NSTextAlignmentCenter;
		lab.layer.cornerRadius = 10;
		lab.clipsToBounds = YES;
		lab.numberOfLines = 3;
		lab.text = [NSString stringWithFormat:@"  %@  ", text];
		[lab sizeToFit];
		CGFloat w = MAX(220, lab.bounds.size.width + 28);
		CGFloat h = MAX(40, lab.bounds.size.height + 14);
		lab.frame = CGRectMake((win.bounds.size.width - w) / 2.0, 56, w, h);
		[win addSubview:lab];
		gToastLab = lab;
		dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(2.8 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
			if (gToastLab == lab) [lab removeFromSuperview];
		});
	});
}

static NSDictionary *MiaoPrefs(void) {
	return [NSDictionary dictionaryWithContentsOfFile:kMiaoPrefPath] ?: @{};
}

static NSString *MiaoHomeURL(void) {
	NSString *u = MiaoPrefs()[@"HomeURL"];
	if ([u isKindOfClass:[NSString class]] && u.length > 4) return u;
	return kMiaoDefaultHome;
}

static NSTimeInterval MiaoWaitSeconds(void) {
	id v = MiaoPrefs()[@"WaitSeconds"];
	double s = v ? [v doubleValue] : 16.0;
	if (s < 8.0) s = 8.0;
	if (s > 180.0) s = 180.0;
	return s;
}

static NSInteger MiaoCycles(void) {
	id v = MiaoPrefs()[@"Cycles"];
	NSInteger n = v ? [v integerValue] : 1;
	if (n < 1) n = 1;
	if (n > 20) n = 20;
	return n;
}

static BOOL MiaoIsSpringBoard(void) {
	return [NSBundle.mainBundle.bundleIdentifier isEqualToString:@"com.apple.springboard"];
}

static BOOL MiaoIsSafari(void) {
	return [NSBundle.mainBundle.bundleIdentifier isEqualToString:@"com.apple.mobilesafari"];
}

#pragma mark - Open URL

static BOOL MiaoOpenURLString(NSString *urlStr) {
	if (urlStr.length == 0) return NO;
	NSURL *url = [NSURL URLWithString:urlStr];
	if (!url) return NO;
	MiaoMarker([NSString stringWithFormat:@"openURL %@", urlStr]);
	id app = [UIApplication sharedApplication];
	[app openURL:url options:@{} completionHandler:nil];
	return YES;
}

static BOOL MiaoOpenBundleID(NSString *bid) {
	Class wsCls = NSClassFromString(@"LSApplicationWorkspace");
	if (!wsCls) return NO;
	id ws = ((id (*)(id, SEL))objc_msgSend)(wsCls, NSSelectorFromString(@"defaultWorkspace"));
	SEL sel = NSSelectorFromString(@"openApplicationWithBundleID:");
	if (ws && [ws respondsToSelector:sel]) {
		return ((BOOL (*)(id, SEL, id))objc_msgSend)(ws, sel, bid);
	}
	return NO;
}

#pragma mark - Command bus (file + notify)

static void MiaoAck(NSString *msg) {
	NSString *line = [NSString stringWithFormat:@"%@ | %@\n", [NSDate date], msg ?: @""];
	[line writeToFile:kMiaoAckPath atomically:YES encoding:NSUTF8StringEncoding error:nil];
	MiaoMarker([NSString stringWithFormat:@"ack %@", msg]);
}

static void MiaoSendCmd(NSString *cmd) {
	NSString *body = [NSString stringWithFormat:@"%@\n%@", cmd, @([[NSDate date] timeIntervalSince1970])];
	[body writeToFile:kMiaoCmdPath atomically:YES encoding:NSUTF8StringEncoding error:nil];
	MiaoMarker([NSString stringWithFormat:@"cmd send %@", cmd]);
	// notify_post e' cross-process affidabile; CF Darwin a volte no
	NSString *note = [NSString stringWithFormat:@"com.noxlab.miao.%@", cmd];
	notify_post(note.UTF8String);
}

#pragma mark - Windows / WKWebView / JS

static NSArray<UIWindow *> *MiaoAllWindows(void) {
	NSMutableArray *arr = [NSMutableArray array];
	for (UIScene *scene in UIApplication.sharedApplication.connectedScenes) {
		if (![scene isKindOfClass:[UIWindowScene class]]) continue;
		[arr addObjectsFromArray:((UIWindowScene *)scene).windows];
	}
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations"
	if (arr.count == 0) [arr addObjectsFromArray:UIApplication.sharedApplication.windows];
#pragma clang diagnostic pop
	return arr;
}

static void MiaoCollectWK(UIView *view, NSMutableArray *out) {
	if ([view isKindOfClass:NSClassFromString(@"WKWebView")]) [out addObject:view];
	for (UIView *s in view.subviews) MiaoCollectWK(s, out);
}

static NSArray *MiaoWebViews(void) {
	NSMutableArray *out = [NSMutableArray array];
	for (UIWindow *w in MiaoAllWindows()) MiaoCollectWK(w, out);
	return out;
}

static void MiaoEvalJS(NSString *js, void (^done)(NSString *result)) {
	NSArray *wvs = MiaoWebViews();
	MiaoMarker([NSString stringWithFormat:@"webview count %lu", (unsigned long)wvs.count]);
	if (wvs.count == 0) {
		if (done) done(nil);
		return;
	}
	// Preferisci l'ultimo WKWebView visibile (tab attiva)
	id wk = wvs.lastObject;
	for (id cand in wvs.reverseObjectEnumerator) {
		UIView *v = (UIView *)cand;
		if (!v.hidden && v.alpha > 0.1 && v.window) { wk = cand; break; }
	}
	SEL sel = @selector(evaluateJavaScript:completionHandler:);
	if (![wk respondsToSelector:sel]) {
		if (done) done(nil);
		return;
	}
	((void (*)(id, SEL, id, id))objc_msgSend)(wk, sel, js, ^(id result, NSError *error) {
		NSString *s = [result isKindOfClass:[NSString class]] ? result : (result ? [result description] : nil);
		if (error) MiaoMarker([NSString stringWithFormat:@"js err %@", error.localizedDescription]);
		MiaoMarker([NSString stringWithFormat:@"js -> %@", s ?: @"nil"]);
		if (done) done(s);
	});
}

static CGPoint MiaoParsePoint(NSString *s) {
	if (s.length == 0) return CGPointZero;
	NSArray *p = [s componentsSeparatedByString:@","];
	if (p.count < 2) return CGPointZero;
	return CGPointMake([p[0] doubleValue], [p[1] doubleValue]);
}

/// Tap reale (HID) SOLO in Safari — coordinate dallo schermo.
static void MiaoSafariHIDTap(CGPoint pt) {
	if (!MiaoIsSafari()) return;
	if (pt.x < 1 && pt.y < 1) {
		MiaoMarker(@"hid tap skipped zero point");
		return;
	}
	CGRect b = UIScreen.mainScreen.bounds;
	pt.x = MAX(8, MIN(b.size.width - 8, pt.x));
	pt.y = MAX(40, MIN(b.size.height - 8, pt.y));
	MiaoMarker([NSString stringWithFormat:@"HID tap %.0f,%.0f", pt.x, pt.y]);
	MiaoToast([NSString stringWithFormat:@"TAP %.0f,%.0f", pt.x, pt.y]);
	dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
		MiaoPerformTap(pt.x, pt.y);
	});
}

#pragma mark - Safari actions

static void MiaoSafariClickVideo(void) {
	MiaoToast(@"Safari: cerco video…");
	NSString *js =
		@"(function(){"
		@"var as=[].slice.call(document.querySelectorAll('a[href*=\"/video/\"]'));"
		@"if(!as.length) return 'NONE';"
		@"var a=as[0];"
		@"for(var i=0;i<Math.min(as.length,8);i++){"
		@"  var r=as[i].getBoundingClientRect();"
		@"  if(r.width>40&&r.height>40&&r.top>60&&r.top<window.innerHeight-40){a=as[i];break;}"
		@"}"
		@"a.scrollIntoView({block:'center'});"
		@"var r=a.getBoundingClientRect();"
		@"var x=Math.round(r.left+r.width/2);"
		@"var y=Math.round(r.top+r.height/2);"
		@"return x+','+y+'|'+a.getAttribute('href');"
		@"})()";

	MiaoEvalJS(js, ^(NSString *result) {
		if (!result || [result hasPrefix:@"NONE"]) {
			MiaoAck(@"clickvideo FAIL no link");
			MiaoToast(@"Nessun link /video/");
			// fallback HID zona tipica prima card
			CGRect b = UIScreen.mainScreen.bounds;
			MiaoSafariHIDTap(CGPointMake(b.size.width * 0.5, MIN(360, b.size.height * 0.40)));
			return;
		}
		NSArray *parts = [result componentsSeparatedByString:@"|"];
		CGPoint pt = MiaoParsePoint(parts.firstObject);
		MiaoAck([NSString stringWithFormat:@"clickvideo %@", result]);
		// doppio tap HID (gesture piu' "umana" / popunder)
		MiaoSafariHIDTap(pt);
		dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.35 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
			MiaoSafariHIDTap(pt);
		});
	});
}

static void MiaoSafariSkipAd(void) {
	MiaoToast(@"Safari: Skip…");
	NSString *js =
		@"(function(){"
		@"var btns=[].slice.call(document.querySelectorAll('button,a,[role=button]'));"
		@"var b=btns.find(function(x){"
		@"  var t=(x.innerText||x.textContent||'').trim();"
		@"  if(!/skip|salta/i.test(t)) return false;"
		@"  if(x.disabled) return false;"
		@"  var r=x.getBoundingClientRect();"
		@"  return r.width>20&&r.height>10;"
		@"});"
		@"if(!b){"
		@"  b=btns.find(function(x){return /skip|salta/i.test((x.innerText||'')+'')});"
		@"}"
		@"if(!b) return 'NONE';"
		@"var r=b.getBoundingClientRect();"
		@"return Math.round(r.left+r.width/2)+','+Math.round(r.top+r.height/2)+'|'+((b.innerText||'').trim().slice(0,24));"
		@"})()";

	MiaoEvalJS(js, ^(NSString *result) {
		if (!result || [result hasPrefix:@"NONE"]) {
			MiaoAck(@"skip NONE — fallback coords");
			CGRect b = UIScreen.mainScreen.bounds;
			// barra Skip sotto player (layout VideoPlayer)
			CGFloat y = 70.0 + (b.size.width * 9.0 / 16.0) + 24.0;
			MiaoSafariHIDTap(CGPointMake(b.size.width * 0.78, MIN(y, b.size.height * 0.62)));
			return;
		}
		NSArray *parts = [result componentsSeparatedByString:@"|"];
		CGPoint pt = MiaoParsePoint(parts.firstObject);
		MiaoAck([NSString stringWithFormat:@"skip %@", result]);
		MiaoSafariHIDTap(pt);
		dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.4 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
			MiaoSafariHIDTap(pt);
		});
	});
}

static void MiaoSafariHumanize(void) {
	NSString *js =
		@"(function(){"
		@"var v=document.querySelector('video[data-nox-content],video');"
		@"if(v){try{v.currentTime=Math.min((v.duration||999),(v.currentTime||0)+10);v.muted=false;v.play();}catch(e){}}"
		@"window.scrollBy(0, 320+Math.floor(Math.random()*200));"
		@"return v?'seek+scroll':'scroll';"
		@"})()";
	MiaoEvalJS(js, ^(NSString *result) {
		MiaoAck([NSString stringWithFormat:@"human %@", result ?: @"?"]);
		MiaoToast([NSString stringWithFormat:@"Human %@", result ?: @"ok"]);
	});
}

#pragma mark - Close ad tabs

static id MiaoBrowserController(void) {
	Class cls = NSClassFromString(@"BrowserController");
	if (!cls) cls = NSClassFromString(@"_SFBrowserController");
	if (!cls) return nil;
	for (NSString *s in @[ @"sharedBrowserController", @"sharedInstance" ]) {
		SEL sel = NSSelectorFromString(s);
		if ([cls respondsToSelector:sel]) {
			@try { return ((id (*)(id, SEL))objc_msgSend)(cls, sel); }
			@catch (NSException *ex) { (void)ex; }
		}
	}
	return nil;
}

static NSString *MiaoTabURL(id tab) {
	for (NSString *k in @[ @"URLString", @"urlString", @"URL", @"committedURL" ]) {
		@try {
			id v = [tab valueForKey:k];
			if ([v isKindOfClass:[NSURL class]]) return [v absoluteString];
			if ([v isKindOfClass:[NSString class]] && [v length]) return v;
		} @catch (NSException *ex) { (void)ex; }
	}
	return nil;
}

static NSArray *MiaoTabs(id bc) {
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

static BOOL MiaoCloseOneTab(id bc, id tab) {
	for (NSString *m in @[ @"closeTabDocument:animated:", @"closeTab:" ]) {
		SEL sel = NSSelectorFromString(m);
		if (![bc respondsToSelector:sel]) continue;
		@try {
			if ([m hasSuffix:@"animated:"]) {
				((void (*)(id, SEL, id, BOOL))objc_msgSend)(bc, sel, tab, YES);
			} else {
				((void (*)(id, SEL, id))objc_msgSend)(bc, sel, tab);
			}
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

static NSInteger MiaoCloseAdTabs(void) {
	id bc = MiaoBrowserController();
	NSArray *tabs = MiaoTabs(bc);
	NSInteger closed = 0;
	for (id tab in [tabs reverseObjectEnumerator]) {
		NSString *u = MiaoTabURL(tab) ?: @"";
		MiaoMarker([NSString stringWithFormat:@"tab %@", u.length ? u : @"(empty)"]);
		BOOL keep = [u.lowercaseString containsString:@"noxreel"];
		if (keep) continue;
		if (MiaoCloseOneTab(bc, tab)) closed++;
	}
	MiaoAck([NSString stringWithFormat:@"closeads %ld/%lu", (long)closed, (unsigned long)tabs.count]);
	return closed;
}

#pragma mark - Safari cmd handler + poll

static void MiaoHandleCmd(NSString *cmd) {
	if (!MiaoIsSafari()) return;
	cmd = [[cmd stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]] lowercaseString];
	if (cmd.length == 0) return;
	MiaoMarker([NSString stringWithFormat:@"handle %@", cmd]);
	MiaoToast([NSString stringWithFormat:@"CMD %@", cmd]);

	if ([cmd isEqualToString:@"clickvideo"]) {
		MiaoSafariClickVideo();
	} else if ([cmd isEqualToString:@"closeads"]) {
		NSInteger n = MiaoCloseAdTabs();
		MiaoToast([NSString stringWithFormat:@"Ads chiuse %ld", (long)n]);
	} else if ([cmd isEqualToString:@"skipad"]) {
		MiaoSafariSkipAd();
	} else if ([cmd isEqualToString:@"human"]) {
		MiaoSafariHumanize();
	} else if ([cmd isEqualToString:@"closeextra"]) {
		NSInteger n = MiaoCloseAdTabs();
		MiaoToast([NSString stringWithFormat:@"Extra %ld", (long)n]);
	} else if ([cmd isEqualToString:@"ping"]) {
		MiaoAck(@"pong");
		MiaoToast(@"Safari PONG");
	}
}

static void MiaoConsumeCmdFile(void) {
	NSString *raw = [NSString stringWithContentsOfFile:kMiaoCmdPath encoding:NSUTF8StringEncoding error:nil];
	if (raw.length == 0) return;
	[[NSFileManager defaultManager] removeItemAtPath:kMiaoCmdPath error:nil];
	NSString *cmd = [[raw componentsSeparatedByCharactersInSet:[NSCharacterSet newlineCharacterSet]] firstObject];
	MiaoHandleCmd(cmd);
}

static void MiaoStartSafariPoll(void) {
	if (gSafariPollStarted || !MiaoIsSafari()) return;
	gSafariPollStarted = YES;
	MiaoMarker(@"safari poll start");
	MiaoToast(@"Miao Safari ON");

	// notify listeners
	NSArray *names = @[ @"clickvideo", @"closeads", @"skipad", @"human", @"closeextra", @"ping" ];
	for (NSString *n in names) {
		NSString *full = [NSString stringWithFormat:@"com.noxlab.miao.%@", n];
		int token = 0;
		notify_register_dispatch(full.UTF8String, &token, dispatch_get_main_queue(), ^(int t) {
			(void)t;
			// preferisci file se presente, altrimenti usa nome notify
			NSString *raw = [NSString stringWithContentsOfFile:kMiaoCmdPath encoding:NSUTF8StringEncoding error:nil];
			if (raw.length) {
				MiaoConsumeCmdFile();
			} else {
				MiaoHandleCmd(n);
			}
		});
	}

	// poll file ogni 0.6s (backup se notify non arriva)
	[NSTimer scheduledTimerWithTimeInterval:0.6 repeats:YES block:^(__unused NSTimer *timer) {
		MiaoConsumeCmdFile();
	}];
}

#pragma mark - Session (SpringBoard orchestrator)

/**
 1) HOME
 2) clickvideo (HID sulle coordinate del thumb) → popunder possibile
 3) closeads
 4) skipad dopo 11s
 5) human
 6) closeextra
 */
static void MiaoRunOneCycle(NSInteger index, NSInteger total, void (^done)(void)) {
	NSString *home = MiaoHomeURL();
	NSTimeInterval afterSkip = MiaoWaitSeconds();

	MiaoToast([NSString stringWithFormat:@"Ciclo %ld/%ld HOME", (long)(index + 1), (long)total]);
	MiaoMarker([NSString stringWithFormat:@"cycle %ld start", (long)index]);

	// Assicura Safari up + home
	MiaoOpenBundleID(@"com.apple.mobilesafari");
	dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.0 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
		MiaoOpenURLString(home);
	});

	// ping: verifica che Safari riceva comandi
	dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(3.0 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
		MiaoSendCmd(@"ping");
	});

	// click thumb (attendi hydration Next.js)
	dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(7.0 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
		MiaoToast(@"Click video…");
		MiaoSendCmd(@"clickvideo");
	});

	// ritenta click (a volte 1° fallisce)
	dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(9.5 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
		MiaoSendCmd(@"clickvideo");
	});

	// chiudi ads se aperte
	dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(12.0 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
		MiaoToast(@"Chiudo ads…");
		MiaoSendCmd(@"closeads");
	});

	// Skip dopo countdown 10s dal video (dal 2° click ~9.5 → +11)
	dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(21.0 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
		MiaoToast(@"Skip…");
		MiaoSendCmd(@"skipad");
	});
	dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(22.5 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
		MiaoSendCmd(@"skipad");
	});

	dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(26.0 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
		MiaoSendCmd(@"human");
	});

	NSTimeInterval endAt = 26.0 + afterSkip;
	dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(endAt * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
		MiaoSendCmd(@"closeextra");
		dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.5 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
			if (done) done();
		});
	});
}

static void MiaoSessionStep(NSInteger index, NSInteger total);

static void MiaoSessionStep(NSInteger index, NSInteger total) {
	if (index >= total) {
		gSessionBusy = NO;
		MiaoToast(@"Sessione fine");
		MiaoMarker(@"session end");
		return;
	}
	MiaoRunOneCycle(index, total, ^{
		dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.0 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
			MiaoSessionStep(index + 1, total);
		});
	});
}

static void MiaoRunSession(void) {
	if (!MiaoIsSpringBoard()) return;
	if (gSessionBusy) {
		MiaoToast(@"Gia in corso");
		return;
	}
	gSessionBusy = YES;
	[@"" writeToFile:kMiaoLogPath atomically:YES encoding:NSUTF8StringEncoding error:nil];
	MiaoMarker(@"session start 0.5.1");
	MiaoToast(@"Sessione 0.5.1…");
	MiaoSessionStep(0, MiaoCycles());
}

#pragma mark - Volume

static void MiaoVol(void) {
	if (!MiaoIsSpringBoard()) return;
	NSTimeInterval now = NSDate.date.timeIntervalSince1970;
	if (now - gLastVol < 0.45) return;
	gLastVol = now;
	if (gVolWindowStart <= 0 || (now - gVolWindowStart) > 2.0) {
		gVolWindowStart = now;
		gVolCount = 1;
		MiaoToast(@"Miao 1/3");
		return;
	}
	gVolCount++;
	if (gVolCount < 3) {
		MiaoToast([NSString stringWithFormat:@"Miao %ld/3", (long)gVolCount]);
		return;
	}
	gVolCount = 0;
	gVolWindowStart = 0;
	MiaoRunSession();
}

static void MiaoBoot(void) {
	if (gBootDone) return;
	gBootDone = YES;
	MiaoMarker([NSString stringWithFormat:@"boot %@", NSBundle.mainBundle.bundleIdentifier ?: @"?"]);
	if (MiaoIsSpringBoard()) {
		MiaoToast(@"Miao 0.5.1 - 3x Vol");
	} else if (MiaoIsSafari()) {
		MiaoStartSafariPoll();
	}
}

%hook SpringBoard
- (void)applicationDidFinishLaunching:(id)app {
	%orig;
	dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(3 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
		MiaoBoot();
	});
}
%end

%hook SBVolumeControl
- (void)decreaseVolume {
	MiaoVol();
	%orig;
}
- (void)increaseVolume {
	MiaoVol();
	%orig;
}
%end

%ctor {
	@autoreleasepool {
		MiaoMarker([NSString stringWithFormat:@"ctor %@", NSBundle.mainBundle.bundleIdentifier ?: @"?"]);
		if (MiaoIsSpringBoard()) {
			[[NSNotificationCenter defaultCenter] addObserverForName:@"AVSystemController_SystemVolumeDidChangeNotification"
															  object:nil
															   queue:NSOperationQueue.mainQueue
														  usingBlock:^(__unused NSNotification *n) { MiaoVol(); }];
			dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(5 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
				MiaoBoot();
			});
		} else if (MiaoIsSafari()) {
			dispatch_async(dispatch_get_main_queue(), ^{
				MiaoStartSafariPoll();
			});
			dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(2 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
				MiaoBoot();
			});
		}
	}
}
