#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <objc/runtime.h>
#import <objc/message.h>
#import <CoreFoundation/CoreFoundation.h>

static NSInteger gVolCount = 0;
static NSTimeInterval gVolWindowStart = 0;
static NSTimeInterval gLastVol = 0;
static BOOL gBootDone = NO;
static BOOL gSessionBusy = NO;

static NSString *const kMiaoPrefPath = @"/var/mobile/Library/Preferences/com.noxlab.miao.plist";
static NSString *const kMiaoDefaultHome = @"https://noxreel.uk/";
static CFStringRef const kNotifyClickVideo = CFSTR("com.noxlab.miao.clickvideo");
static CFStringRef const kNotifyCloseAds = CFSTR("com.noxlab.miao.closeads");
static CFStringRef const kNotifySkip = CFSTR("com.noxlab.miao.skipad");
static CFStringRef const kNotifyHuman = CFSTR("com.noxlab.miao.human");
static CFStringRef const kNotifyCloseExtra = CFSTR("com.noxlab.miao.closeextra");
static NSMutableSet<NSString *> *gVisitedVideos = nil;

#pragma mark - Utils

static void MiaoMarker(NSString *note) {
	NSString *line = [NSString stringWithFormat:@"%@ | %@\n", [NSDate date], note ?: @""];
	[line writeToFile:@"/var/mobile/Documents/miao-loaded.txt" atomically:YES encoding:NSUTF8StringEncoding error:nil];
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
		lab.font = [UIFont boldSystemFontOfSize:15];
		lab.textAlignment = NSTextAlignmentCenter;
		lab.layer.cornerRadius = 10;
		lab.clipsToBounds = YES;
		lab.numberOfLines = 2;
		lab.text = [NSString stringWithFormat:@"  %@  ", text];
		[lab sizeToFit];
		CGFloat w = MAX(200, lab.bounds.size.width + 28);
		CGFloat h = MAX(40, lab.bounds.size.height + 14);
		lab.frame = CGRectMake((win.bounds.size.width - w) / 2.0, 70, w, h);
		[win addSubview:lab];
		gToastLab = lab;
		dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(2.5 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
			if (gToastLab == lab) [lab removeFromSuperview];
		});
	});
}

static NSDictionary *MiaoPrefs(void) {
	NSDictionary *p = [NSDictionary dictionaryWithContentsOfFile:kMiaoPrefPath];
	return p ?: @{};
}

static NSString *MiaoHomeURL(void) {
	NSString *u = MiaoPrefs()[@"HomeURL"];
	if ([u isKindOfClass:[NSString class]] && u.length > 4) return u;
	NSString *s = MiaoPrefs()[@"SessionURL"];
	if ([s isKindOfClass:[NSString class]] && s.length > 4 && ![s containsString:@"/video/"]) return s;
	return kMiaoDefaultHome;
}

static NSTimeInterval MiaoWaitSeconds(void) {
	id v = MiaoPrefs()[@"WaitSeconds"];
	// Default 18: preroll VAST/html + ~10s content (view progress sito)
	double s = v ? [v doubleValue] : 18.0;
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
	NSString *bid = NSBundle.mainBundle.bundleIdentifier ?: @"";
	return [bid isEqualToString:@"com.apple.springboard"];
}

static BOOL MiaoIsSafari(void) {
	NSString *bid = NSBundle.mainBundle.bundleIdentifier ?: @"";
	return [bid isEqualToString:@"com.apple.mobilesafari"];
}

#pragma mark - Open URL / Safari

static BOOL MiaoOpenURLString(NSString *urlStr) {
	if (urlStr.length == 0) return NO;
	NSURL *url = [NSURL URLWithString:urlStr];
	if (!url) return NO;
	MiaoMarker([NSString stringWithFormat:@"openURL %@", urlStr]);

	id app = [UIApplication sharedApplication];
	if ([app respondsToSelector:@selector(openURL:options:completionHandler:)]) {
		[app openURL:url options:@{} completionHandler:nil];
		return YES;
	}
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations"
	if ([app respondsToSelector:@selector(openURL:)]) {
		return [app openURL:url];
	}
#pragma clang diagnostic pop
	return NO;
}

static BOOL MiaoOpenBundleID(NSString *bid) {
	if (bid.length == 0) return NO;
	MiaoMarker([NSString stringWithFormat:@"open bid %@", bid]);

	Class wsCls = NSClassFromString(@"LSApplicationWorkspace");
	if (wsCls) {
		id ws = ((id (*)(id, SEL))objc_msgSend)(wsCls, NSSelectorFromString(@"defaultWorkspace"));
		for (NSString *name in @[ @"openApplicationWithBundleID:", @"openApplicationWithBundleIdentifier:" ]) {
			SEL sel = NSSelectorFromString(name);
			if (ws && [ws respondsToSelector:sel]) {
				@try {
					if (((BOOL (*)(id, SEL, id))objc_msgSend)(ws, sel, bid)) return YES;
				} @catch (NSException *ex) { (void)ex; }
			}
		}
	}

	id app = [UIApplication sharedApplication];
	SEL launchSel = NSSelectorFromString(@"launchApplicationWithIdentifier:suspended:");
	if ([app respondsToSelector:launchSel]) {
		@try {
			if (((BOOL (*)(id, SEL, id, BOOL))objc_msgSend)(app, launchSel, bid, NO)) return YES;
		} @catch (NSException *ex) { (void)ex; }
	}
	return NO;
}

#pragma mark - Soft tap (in-process, no HID)

static NSArray<UIWindow *> *MiaoAllWindows(void) {
	NSMutableArray *arr = [NSMutableArray array];
	for (UIScene *scene in UIApplication.sharedApplication.connectedScenes) {
		if (![scene isKindOfClass:[UIWindowScene class]]) continue;
		[arr addObjectsFromArray:((UIWindowScene *)scene).windows];
	}
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations"
	if (arr.count == 0 && UIApplication.sharedApplication.windows.count) {
		[arr addObjectsFromArray:UIApplication.sharedApplication.windows];
	}
#pragma clang diagnostic pop
	return arr;
}

static CGPoint MiaoHomeVideoTapPoint(void) {
	NSDictionary *prefs = MiaoPrefs();
	CGRect b = UIScreen.mainScreen.bounds;
	// Mobile home: header + ad top + chip categorie + "In tendenza" + meta' prima card aspect-video
	CGFloat x = prefs[@"HomeTapX"] ? [prefs[@"HomeTapX"] doubleValue] : CGRectGetMidX(b);
	CGFloat y = prefs[@"HomeTapY"] ? [prefs[@"HomeTapY"] doubleValue] : MIN(b.size.height * 0.42, 340.0);
	return CGPointMake(x, y);
}

static CGPoint MiaoSkipTapPoint(void) {
	NSDictionary *prefs = MiaoPrefs();
	CGRect b = UIScreen.mainScreen.bounds;
	// Skip HTML preroll: barra in basso al player aspect-video
	CGFloat x = prefs[@"SkipTapX"] ? [prefs[@"SkipTapX"] doubleValue] : (b.size.width * 0.72);
	CGFloat playerBottom = 56.0 + (b.size.width * 9.0 / 16.0) + 48.0;
	CGFloat y = prefs[@"SkipTapY"] ? [prefs[@"SkipTapY"] doubleValue] : MIN(playerBottom, b.size.height * 0.55);
	return CGPointMake(x, y);
}

static void MiaoCollectClass(UIView *view, NSString *className, NSMutableArray *out) {
	if ([NSStringFromClass(view.class) isEqualToString:className] || [view isKindOfClass:NSClassFromString(className)]) {
		[out addObject:view];
	}
	for (UIView *sub in view.subviews) {
		MiaoCollectClass(sub, className, out);
	}
}

static NSArray *MiaoWebViews(void) {
	NSMutableArray *out = [NSMutableArray array];
	for (UIWindow *win in MiaoAllWindows()) {
		MiaoCollectClass(win, @"WKWebView", out);
	}
	return out;
}

static void MiaoEvalJS(NSString *js, void (^done)(NSString *result)) {
	NSArray *wvs = MiaoWebViews();
	if (wvs.count == 0) {
		MiaoMarker(@"evalJS no WKWebView");
		if (done) done(nil);
		return;
	}
	id wk = wvs.lastObject;
	SEL sel = @selector(evaluateJavaScript:completionHandler:);
	if (![wk respondsToSelector:sel]) {
		if (done) done(nil);
		return;
	}
	MiaoMarker([NSString stringWithFormat:@"evalJS %@", [js substringToIndex:MIN(60, js.length)]]);
	((void (*)(id, SEL, id, id))objc_msgSend)(wk, sel, js, ^(id result, NSError *error) {
		NSString *s = nil;
		if ([result isKindOfClass:[NSString class]]) s = result;
		else if (result) s = [result description];
		if (error) MiaoMarker([NSString stringWithFormat:@"evalJS err %@", error.localizedDescription]);
		MiaoMarker([NSString stringWithFormat:@"evalJS -> %@", s ?: @"nil"]);
		if (done) done(s);
	});
}

/// Tap sintetico in-process (solo Safari). Meglio di UIControl: il sito e' dentro WKWebView.
static BOOL MiaoSynthTapAt(CGPoint pt) {
	UIWindow *win = nil;
	for (UIWindow *w in MiaoAllWindows()) {
		if (w.isKeyWindow) { win = w; break; }
	}
	if (!win && MiaoAllWindows().count) win = MiaoAllWindows().firstObject;
	if (!win) return NO;

	UIView *view = [win hitTest:pt withEvent:nil] ?: win;
	MiaoMarker([NSString stringWithFormat:@"synthTap (%.0f,%.0f) %@", pt.x, pt.y, NSStringFromClass(view.class)]);

	@try {
		Class touchCls = NSClassFromString(@"UITouch");
		UITouch *touch = [[touchCls alloc] init];
		if (!touch) return NO;
		if ([touch respondsToSelector:NSSelectorFromString(@"setWindow:")]) {
			((void (*)(id, SEL, id))objc_msgSend)(touch, NSSelectorFromString(@"setWindow:"), win);
		}
		if ([touch respondsToSelector:NSSelectorFromString(@"setView:")]) {
			((void (*)(id, SEL, id))objc_msgSend)(touch, NSSelectorFromString(@"setView:"), view);
		}
		SEL setLoc = NSSelectorFromString(@"_setLocationInWindow:resetPrevious:");
		if ([touch respondsToSelector:setLoc]) {
			((void (*)(id, SEL, CGPoint, BOOL))objc_msgSend)(touch, setLoc, pt, YES);
		}
		if ([touch respondsToSelector:NSSelectorFromString(@"setPhase:")]) {
			((void (*)(id, SEL, NSInteger))objc_msgSend)(touch, NSSelectorFromString(@"setPhase:"), UITouchPhaseBegan);
		}
		if ([touch respondsToSelector:NSSelectorFromString(@"setTapCount:")]) {
			((void (*)(id, SEL, NSUInteger))objc_msgSend)(touch, NSSelectorFromString(@"setTapCount:"), 1);
		}

		NSSet *set = [NSSet setWithObject:touch];
		UIEvent *event = nil;
		id app = [UIApplication sharedApplication];
		SEL evSel = NSSelectorFromString(@"_touchesEvent");
		if ([app respondsToSelector:evSel]) {
			event = ((id (*)(id, SEL))objc_msgSend)(app, evSel);
		}
		if (event && [event respondsToSelector:NSSelectorFromString(@"_addTouch:forDelayedDelivery:")]) {
			((void (*)(id, SEL, id, BOOL))objc_msgSend)(event, NSSelectorFromString(@"_addTouch:forDelayedDelivery:"), touch, NO);
		}

		[view touchesBegan:set withEvent:event];
		if ([touch respondsToSelector:NSSelectorFromString(@"setPhase:")]) {
			((void (*)(id, SEL, NSInteger))objc_msgSend)(touch, NSSelectorFromString(@"setPhase:"), UITouchPhaseEnded);
		}
		[view touchesEnded:set withEvent:event];
		if ([app respondsToSelector:@selector(sendEvent:)] && event) {
			[app sendEvent:event];
		}
		return YES;
	} @catch (NSException *ex) {
		MiaoMarker([NSString stringWithFormat:@"synthTap ex %@", ex.reason]);
		return NO;
	}
}

static void MiaoSafariClickFirstVideo(void) {
	NSString *js =
		@"(function(){"
		@"var as=[].slice.call(document.querySelectorAll('a[href*=\"/video/\"]'));"
		@"if(!as.length) return 'none';"
		@"var a=as[Math.floor(Math.random()*Math.min(as.length,6))];"
		@"a.scrollIntoView({block:'center'});"
		@"try{a.dispatchEvent(new MouseEvent('mousedown',{bubbles:true}));}catch(e){}"
		@"try{a.dispatchEvent(new MouseEvent('click',{bubbles:true}));}catch(e){}"
		@"a.click();"
		@"return a.getAttribute('href')||'ok';"
		@"})()";
	MiaoEvalJS(js, ^(NSString *result) {
		CGPoint pt = MiaoHomeVideoTapPoint();
		MiaoSynthTapAt(pt);
		MiaoToast([NSString stringWithFormat:@"Click video %@", result ?: @"…"]);
	});
}

static void MiaoSafariSkipAd(void) {
	NSString *js =
		@"(function(){"
		@"var btns=[].slice.call(document.querySelectorAll('button,a,[role=button]'));"
		@"var b=btns.find(function(x){var t=(x.innerText||x.textContent||'');return /skip|salta/i.test(t)&&!x.disabled;});"
		@"if(b){b.click();return 'skip:'+((b.innerText||'').trim().slice(0,20));}"
		@"return 'no-skip';"
		@"})()";
	MiaoEvalJS(js, ^(NSString *result) {
		if (![result hasPrefix:@"skip"]) {
			MiaoSynthTapAt(MiaoSkipTapPoint());
		}
		MiaoToast([NSString stringWithFormat:@"Skip %@", result ?: @"tap"]);
	});
}

static void MiaoSafariHumanize(void) {
	NSString *js =
		@"(function(){"
		@"var v=document.querySelector('video[data-nox-content],video');"
		@"if(v){try{v.currentTime=Math.min((v.duration||1e3),(v.currentTime||0)+10);v.muted=false;v.play();}catch(e){}}"
		@"window.scrollBy(0, Math.floor(280+Math.random()*220));"
		@"var rel=[].slice.call(document.querySelectorAll('a[href*=\"/video/\"]'));"
		@"if(rel.length>2 && Math.random()<0.55){rel[2].click();return 'next-video';}"
		@"return v?'seek+scroll':'scroll';"
		@"})()";
	MiaoEvalJS(js, ^(NSString *result) {
		MiaoToast([NSString stringWithFormat:@"Human %@", result ?: @"ok"]);
	});
}

#pragma mark - Safari close tabs

static id MiaoBrowserController(void) {
	for (NSString *cn in @[ @"BrowserController", @"_SFBrowserController" ]) {
		Class cls = NSClassFromString(cn);
		if (!cls) continue;
		for (NSString *shared in @[ @"sharedBrowserController", @"sharedInstance", @"sharedController" ]) {
			SEL sel = NSSelectorFromString(shared);
			if (![cls respondsToSelector:sel]) continue;
			@try {
				id obj = ((id (*)(id, SEL))objc_msgSend)(cls, sel);
				if (obj) return obj;
			} @catch (NSException *ex) { (void)ex; }
		}
	}
	return nil;
}

static NSString *MiaoTabURLString(id tab) {
	if (!tab) return nil;
	NSArray *sels = @[ @"URLString", @"urlString", @"committedURL", @"URL", @"stableURL", @"rawURL" ];
	for (NSString *name in sels) {
		SEL sel = NSSelectorFromString(name);
		if (![tab respondsToSelector:sel]) continue;
		@try {
			id val = ((id (*)(id, SEL))objc_msgSend)(tab, sel);
			if ([val isKindOfClass:[NSURL class]]) return [(NSURL *)val absoluteString];
			if ([val isKindOfClass:[NSString class]] && [val length]) return val;
		} @catch (NSException *ex) { (void)ex; }
	}
	@try {
		id doc = [tab valueForKey:@"URL"];
		if ([doc isKindOfClass:[NSURL class]]) return [doc absoluteString];
		if ([doc isKindOfClass:[NSString class]]) return doc;
	} @catch (NSException *ex) { (void)ex; }
	return nil;
}

static BOOL MiaoIsNoxURL(NSString *url) {
	if (url.length == 0) return NO;
	NSString *l = url.lowercaseString;
	return [l containsString:@"noxreel.uk"] || [l containsString:@"noxreel"];
}

static NSArray *MiaoAllTabDocuments(id bc) {
	if (!bc) return @[];
	id tabController = nil;
	for (NSString *name in @[ @"tabController", @"tabsController", @"_tabController" ]) {
		@try {
			tabController = [bc valueForKey:name];
			if (tabController) break;
		} @catch (NSException *ex) { (void)ex; }
		SEL sel = NSSelectorFromString(name);
		if ([bc respondsToSelector:sel]) {
			@try {
				tabController = ((id (*)(id, SEL))objc_msgSend)(bc, sel);
				if (tabController) break;
			} @catch (NSException *ex) { (void)ex; }
		}
	}
	id src = tabController ?: bc;
	for (NSString *name in @[ @"tabDocuments", @"allTabDocuments", @"tabs", @"openTabs", @"tabDocumentArr" ]) {
		@try {
			id arr = [src valueForKey:name];
			if ([arr isKindOfClass:[NSArray class]] && [arr count]) return arr;
		} @catch (NSException *ex) { (void)ex; }
		SEL sel = NSSelectorFromString(name);
		if ([src respondsToSelector:sel]) {
			@try {
				id arr = ((id (*)(id, SEL))objc_msgSend)(src, sel);
				if ([arr isKindOfClass:[NSArray class]] && [arr count]) return arr;
			} @catch (NSException *ex) { (void)ex; }
		}
	}
	return @[];
}

static BOOL MiaoCloseTabDocument(id bc, id tab) {
	if (!bc || !tab) return NO;
	NSArray *pairs = @[
		@[ @"closeTabDocument:animated:", @YES ],
		@[ @"closeTab:", @YES ],
		@[ @"_closeTabDocument:animated:", @YES ],
	];
	for (NSArray *p in pairs) {
		SEL sel = NSSelectorFromString(p[0]);
		if (![bc respondsToSelector:sel]) continue;
		@try {
			((void (*)(id, SEL, id, BOOL))objc_msgSend)(bc, sel, tab, YES);
			return YES;
		} @catch (NSException *ex) { (void)ex; }
	}
	id tc = nil;
	@try { tc = [bc valueForKey:@"tabController"]; } @catch (NSException *ex) { (void)ex; }
	if (tc) {
		SEL sel = NSSelectorFromString(@"closeTabDocument:animated:");
		if ([tc respondsToSelector:sel]) {
			@try {
				((void (*)(id, SEL, id, BOOL))objc_msgSend)(tc, sel, tab, YES);
				return YES;
			} @catch (NSException *ex) { (void)ex; }
		}
	}
	return NO;
}

/// Chiude schede che NON sono noxreel (popunder ads). Tiene almeno una scheda nox.
static NSInteger MiaoSafariCloseAdTabs(void) {
	id bc = MiaoBrowserController();
	NSArray *tabs = MiaoAllTabDocuments(bc);
	MiaoMarker([NSString stringWithFormat:@"tabs count %lu", (unsigned long)tabs.count]);
	NSInteger closed = 0;
	NSInteger noxCount = 0;
	for (id tab in tabs) {
		NSString *u = MiaoTabURLString(tab) ?: @"";
		MiaoMarker([NSString stringWithFormat:@"tab %@", u.length ? u : @"(empty)"]);
		if (MiaoIsNoxURL(u)) noxCount++;
	}
	for (id tab in [tabs reverseObjectEnumerator]) {
		NSString *u = MiaoTabURLString(tab) ?: @"";
		if (MiaoIsNoxURL(u)) continue;
		// chiudi ads / blank / altro
		if (MiaoCloseTabDocument(bc, tab)) {
			closed++;
		}
	}
	MiaoMarker([NSString stringWithFormat:@"closed ads %ld noxLeft~%ld", (long)closed, (long)noxCount]);
	return closed;
}

/// Chiude schede extra noxreel lasciandone una sola, e di nuovo le ads.
static NSInteger MiaoSafariCloseExtra(void) {
	NSInteger closed = MiaoSafariCloseAdTabs();
	id bc = MiaoBrowserController();
	NSArray *tabs = MiaoAllTabDocuments(bc);
	NSMutableArray *nox = [NSMutableArray array];
	for (id tab in tabs) {
		if (MiaoIsNoxURL(MiaoTabURLString(tab))) [nox addObject:tab];
	}
	while (nox.count > 1) {
		id tab = nox.lastObject;
		[nox removeLastObject];
		if (MiaoCloseTabDocument(bc, tab)) closed++;
	}
	return closed;
}

#pragma mark - Session (SpringBoard)

static void MiaoPost(CFStringRef name) {
	CFNotificationCenterPostNotification(CFNotificationCenterGetDarwinNotifyCenter(), name, NULL, NULL, true);
}

/**
 Flusso mobile reale NoxReel + Exo:
 1) HOME (non deep-link video) — click thumb apre spesso popunder/nuova scheda ads
 2) Chiudi scheda ads, resta su noxreel video
 3) Preroll: Skip dopo ~10s
 4) Azioni umane: seek +10, scroll, forse altro video
 5) Chiudi extra
 */
static void MiaoRunOneCycle(NSInteger index, NSInteger total, void (^done)(void)) {
	NSTimeInterval skipWait = 10.5; // Skip HTML abilitato dopo countdown 10s
	NSTimeInterval afterSkip = MiaoWaitSeconds(); // resto sessione sul contenuto
	if (afterSkip < 12) afterSkip = 12;

	NSString *home = MiaoHomeURL();
	MiaoToast([NSString stringWithFormat:@"Ciclo %ld/%ld\nApro HOME", (long)(index + 1), (long)total]);
	MiaoMarker([NSString stringWithFormat:@"cycle %ld home %@", (long)index, home]);
	MiaoOpenURLString(home);

	// 1) Click prima card /video/ (JS + synth) → popunder ads
	dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(4.0 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
		MiaoToast(@"Tap video in home…");
		MiaoPost(kNotifyClickVideo);
	});

	// 2) Chiudi schede ads (non-noxreel)
	dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(7.0 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
		MiaoToast(@"Chiudo scheda ads…");
		MiaoPost(kNotifyCloseAds);
	});

	// 3) Attendi Skip 10s poi tap Skip
	dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)((7.0 + skipWait) * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
		MiaoToast(@"Skip ads…");
		MiaoPost(kNotifySkip);
	});

	// 4) Human: seek/scroll/altro video
	dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)((7.0 + skipWait + 3.0) * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
		MiaoToast(@"Azioni umane…");
		MiaoPost(kNotifyHuman);
	});

	// 5) Chiudi extra / ads rimaste
	NSTimeInterval endAt = 7.0 + skipWait + 3.0 + afterSkip;
	dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(endAt * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
		MiaoToast(@"Chiudo extra…");
		MiaoPost(kNotifyCloseExtra);
		dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.5 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
			if (done) done();
		});
	});
}

static void MiaoSessionStep(NSInteger index, NSInteger total) {
	if (index >= total) {
		gSessionBusy = NO;
		MiaoToast(@"Sessione fine");
		MiaoMarker(@"session end");
		return;
	}
	MiaoRunOneCycle(index, total, ^{
		dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.8 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
			MiaoSessionStep(index + 1, total);
		});
	});
}

static void MiaoRunSession(void) {
	if (!MiaoIsSpringBoard()) return;
	if (gSessionBusy) {
		MiaoToast(@"Sessione già in corso");
		return;
	}
	gSessionBusy = YES;
	NSInteger cycles = MiaoCycles();
	if (!gVisitedVideos) gVisitedVideos = [NSMutableSet set];
	[gVisitedVideos removeAllObjects];
	MiaoToast(@"Sessione Miao…");
	MiaoMarker(@"session start");
	MiaoSessionStep(0, cycles);
}

#pragma mark - Volume trigger (SpringBoard)

static void MiaoFire(void) {
	NSString *mode = MiaoPrefs()[@"Mode"];
	if ([mode isKindOfClass:[NSString class]] && [mode.lowercaseString isEqualToString:@"icon"]) {
		// legacy: apri Safari bundle (non sessione)
		MiaoToast(@"Apro Safari…");
		if (MiaoOpenBundleID(@"com.apple.mobilesafari") || MiaoOpenURLString(@"https://")) {
			return;
		}
		MiaoToast(@"Fail Safari");
		return;
	}
	MiaoRunSession();
}

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
	MiaoFire();
}

static void MiaoBoot(void) {
	if (gBootDone) return;
	gBootDone = YES;
	NSString *bid = NSBundle.mainBundle.bundleIdentifier ?: @"?";
	MiaoMarker([NSString stringWithFormat:@"boot ok %@", bid]);
	if (MiaoIsSpringBoard()) {
		MiaoToast(@"Miao 0.5 - 3x Vol = home+ads");
	}
}

#pragma mark - Darwin (Safari)

static void MiaoDarwinCallback(CFNotificationCenterRef center, void *observer, CFStringRef name, const void *object, CFDictionaryRef userInfo) {
	(void)center; (void)observer; (void)object; (void)userInfo;
	NSString *n = (__bridge NSString *)name;
	dispatch_async(dispatch_get_main_queue(), ^{
		if (!MiaoIsSafari()) return;
		if ([n containsString:@"clickvideo"]) {
			MiaoSafariClickFirstVideo();
		} else if ([n containsString:@"closeads"]) {
			NSInteger nClosed = MiaoSafariCloseAdTabs();
			MiaoToast([NSString stringWithFormat:@"Ads chiuse: %ld", (long)nClosed]);
		} else if ([n containsString:@"skipad"]) {
			MiaoSafariSkipAd();
		} else if ([n containsString:@"human"]) {
			MiaoSafariHumanize();
		} else if ([n containsString:@"closeextra"]) {
			NSInteger nClosed = MiaoSafariCloseExtra();
			MiaoToast([NSString stringWithFormat:@"Extra chiuse: %ld", (long)nClosed]);
		}
	});
}

static void MiaoRegisterSafariNotify(void) {
	if (!MiaoIsSafari()) return;
	CFNotificationCenterRef darwin = CFNotificationCenterGetDarwinNotifyCenter();
	CFStringRef names[] = {
		CFSTR("com.noxlab.miao.clickvideo"),
		CFSTR("com.noxlab.miao.closeads"),
		CFSTR("com.noxlab.miao.skipad"),
		CFSTR("com.noxlab.miao.human"),
		CFSTR("com.noxlab.miao.closeextra"),
	};
	for (size_t i = 0; i < sizeof(names) / sizeof(names[0]); i++) {
		CFNotificationCenterAddObserver(darwin, NULL, MiaoDarwinCallback, names[i], NULL,
			CFNotificationSuspensionBehaviorDeliverImmediately);
	}
	MiaoMarker(@"safari notify registered v0.5");
}

#pragma mark - Hooks

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
		NSString *bid = NSBundle.mainBundle.bundleIdentifier ?: @"?";
		MiaoMarker([NSString stringWithFormat:@"ctor %@", bid]);
		if (MiaoIsSpringBoard()) {
			[[NSNotificationCenter defaultCenter] addObserverForName:@"AVSystemController_SystemVolumeDidChangeNotification"
															  object:nil
															   queue:NSOperationQueue.mainQueue
														  usingBlock:^(__unused NSNotification *n) { MiaoVol(); }];
			dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(5 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
				MiaoBoot();
			});
		} else if (MiaoIsSafari()) {
			MiaoRegisterSafariNotify();
		}
	}
}
