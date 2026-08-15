#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <objc/runtime.h>
#import <objc/message.h>
#import <notify.h>
#import "TouchSim.h"
#import "MiaoCore.h"

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

static id MiaoBestWebView(void) {
	NSMutableArray *all = [NSMutableArray array];
	for (UIWindow *w in MiaoWindows()) MiaoFindWK(w, all);
	MiaoLog([NSString stringWithFormat:@"wk count %lu", (unsigned long)all.count]);
	id best = nil;
	CGFloat bestArea = 0;
	for (UIView *v in all) {
		if (v.hidden || v.alpha < 0.05 || !v.window) continue;
		CGFloat area = v.bounds.size.width * v.bounds.size.height;
		if (area > bestArea) { bestArea = area; best = v; }
	}
	return best ?: all.lastObject;
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

/// HID umano SOLO Safari, su queue dedicata (non blocca main).
static void MiaoHumanTapAt(CGPoint pt, void (^done)(void)) {
	if (!MiaoIsSafari()) {
		MiaoLog(@"humanTap blocked: not safari");
		if (done) done();
		return;
	}
	if (pt.x < 1 || pt.y < 1) {
		MiaoLog(@"humanTap bad point");
		if (done) done();
		return;
	}
	CGRect b = UIScreen.mainScreen.bounds;
	pt.x = MAX(12, MIN(b.size.width - 12, pt.x));
	pt.y = MAX(55, MIN(b.size.height - 12, pt.y));
	MiaoToast([NSString stringWithFormat:@"Dito %.0f,%.0f", pt.x, pt.y]);
	MiaoLog([NSString stringWithFormat:@"humanTap %.0f,%.0f", pt.x, pt.y]);
	dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
		MiaoPerformHumanTap(pt.x, pt.y);
		dispatch_async(dispatch_get_main_queue(), ^{
			if (done) done();
		});
	});
}

#pragma mark - Safari actions (human)

static void MiaoActReady(void (^done)(BOOL ok)) {
	MiaoJS(@"(function(){return document.querySelectorAll('a[href*=\"/video/\"]').length+'|'+location.href;})()", ^(NSString *r) {
		BOOL ok = r && ![r hasPrefix:@"0|"];
		if (done) done(ok);
	});
}

static void MiaoActClickVideo(void) {
	MiaoToast(@"Apro un video...");
	// HID su questo device non apre i link WKWebView. JS location funziona (come lo scroll).
	NSString *js =
		@"(function(){"
		@"var as=[].slice.call(document.querySelectorAll('a[href*=\"/video/\"]'));"
		@"if(!as.length) return 'NONE';"
		@"var a=as[Math.floor(Math.random()*Math.min(as.length,8))];"
		@"var href=a.href||a.getAttribute('href')||'';"
		@"if(!href) return 'NONE';"
		@"if(href.indexOf('http')!==0) href=location.origin+href;"
		@"a.scrollIntoView({block:'center'});"
		@"try{a.click();}catch(e){}"
		@"setTimeout(function(){ location.assign(href); }, 200);"
		@"return 'GO|'+href;"
		@"})()";

	MiaoJS(js, ^(NSString *result) {
		if (!result || [result hasPrefix:@"NONE"]) {
			MiaoAck(@"click NONE");
			MiaoToast(@"Nessun /video/ in pagina");
			return;
		}
		MiaoAck([NSString stringWithFormat:@"click %@", result]);
		MiaoToast(@"Video: nav JS");
		// Prova anche HID sul punto (popunder); la nav JS sopra apre il video comunque
		NSArray *parts = [result componentsSeparatedByString:@"|"];
		if (parts.count >= 2) {
			// secondo pezzo e' URL, non coords — HID opzionale al centro card
			CGRect b = UIScreen.mainScreen.bounds;
			MiaoHumanTapAt(CGPointMake(b.size.width * 0.5, MIN(340, b.size.height * 0.38)), ^{});
		}
	});
}

static void MiaoActSkip(void) {
	MiaoToast(@"Skip ads...");
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
		@"  b=btns.find(function(x){return /skip|salta/i.test((x.innerText||'')+'');});"
		@"}"
		@"if(!b) return 'NONE';"
		@"b.click();"
		@"return 'SKIP|'+(b.innerText||'').trim().slice(0,24);"
		@"})()";

	MiaoJS(js, ^(NSString *result) {
		if (!result || [result hasPrefix:@"NONE"]) {
			MiaoAck(@"skip NONE - retry HID zona");
			CGRect b = UIScreen.mainScreen.bounds;
			CGFloat y = MIN(70 + b.size.width * 9.0 / 16.0 + 28, b.size.height * 0.58);
			MiaoHumanTapAt(CGPointMake(b.size.width * 0.78, y), ^{});
			MiaoToast(@"Skip: nessun bottone");
			return;
		}
		MiaoAck([NSString stringWithFormat:@"skip %@", result]);
		MiaoToast(@"Skip OK");
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

static NSInteger MiaoCloseNonNoxTabs(void) {
	id bc = MiaoBrowser();
	NSArray *tabs = MiaoTabList(bc);
	NSInteger closed = 0;
	for (id tab in [tabs reverseObjectEnumerator]) {
		NSString *u = MiaoTabURL(tab);
		MiaoLog([NSString stringWithFormat:@"tab %@", u.length ? u : @"(empty)"]);
		if ([u.lowercaseString containsString:@"noxreel"]) continue;
		if (MiaoCloseTab(bc, tab)) closed++;
	}
	MiaoAck([NSString stringWithFormat:@"closeads %ld of %lu", (long)closed, (unsigned long)tabs.count]);
	return closed;
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
	} else if ([cmd isEqualToString:@"closeads"]) {
		NSInteger n = MiaoCloseNonNoxTabs();
		MiaoToast([NSString stringWithFormat:@"Ads chiuse %ld", (long)n]);
	} else if ([cmd isEqualToString:@"skipad"]) {
		MiaoActSkip();
	} else if ([cmd isEqualToString:@"human"]) {
		MiaoActHumanWatch();
	} else if ([cmd isEqualToString:@"closeextra"]) {
		NSInteger n = MiaoCloseNonNoxTabs();
		MiaoToast([NSString stringWithFormat:@"Extra %ld", (long)n]);
	} else if ([cmd isEqualToString:@"where"]) {
		MiaoActWhere(^(NSString *p) { MiaoToast(p ?: @"?"); });
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
	MiaoLog(@"safari ready 0.7");
	MiaoToast(@"Miao Safari ON");

	for (NSString *n in @[ @"ping", @"clickvideo", @"closeads", @"skipad", @"human", @"closeextra", @"where" ]) {
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
 2 JS: location.assign(/video/...)  — HID non apre i link su questo device
 3 Backup: SpringBoard openURL stesso video
 4 Skip via button.click() JS
 5 seek/scroll
 6 close ads best-effort
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

		// JS apre /video/ (funziona; HID no)
		MiaoAfter(7.0, ^{
			MiaoToast(@"Click/nav video...");
			MiaoSendCmd(@"clickvideo");
		});

		// Backup sicuro: openURL dal SpringBoard
		MiaoAfter(10.0, ^{
			MiaoToast(@"Backup openURL video");
			MiaoOpenURL(videoURL);
		});

		MiaoAfter(13.0, ^{ MiaoSendCmd(@"closeads"); });

		MiaoAfter(23.0, ^{
			MiaoToast(@"Skip...");
			MiaoSendCmd(@"skipad");
		});
		MiaoAfter(24.5, ^{ MiaoSendCmd(@"skipad"); });

		MiaoAfter(27.0, ^{ MiaoSendCmd(@"human"); });

		MiaoAfter(27.0 + watch, ^{
			MiaoSendCmd(@"closeextra");
			MiaoAfter(1.2, ^{ if (done) done(); });
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
	MiaoLog(@"session 0.7 js-nav");
	MiaoToast(@"Sessione 0.7...");
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
	if (MiaoIsSB()) MiaoToast(@"Miao 0.7 - 3x Vol");
	else if (MiaoIsSafari()) MiaoStartSafari();
}

