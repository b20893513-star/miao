#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <objc/runtime.h>
#import <objc/message.h>
#import <notify.h>
#import <unistd.h>
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
static NSString *const kHidPath = @"/var/mobile/Documents/miao-hid.txt";
static BOOL gBackboardStarted = NO;
static NSTimeInterval gLastHid = 0;

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

/// Chiede un tap HID a backboardd (trusted). Safari/SB non dispatchano HID.
static void MiaoRequestHidTap(CGPoint pt) {
	id dis = MiaoPrefs()[@"DisableBackboardHID"];
	if (dis && [dis boolValue]) {
		MiaoLog(@"HID disabled by prefs");
		return;
	}
	CGRect b = UIScreen.mainScreen.bounds;
	if (b.size.width < 1) b = CGRectMake(0, 0, 414, 896);
	pt.x = MAX(8, MIN(b.size.width - 8, pt.x));
	pt.y = MAX(40, MIN(b.size.height - 8, pt.y));
	NSString *body = [NSString stringWithFormat:@"%.2f,%.2f\n%.0f", pt.x, pt.y, [[NSDate date] timeIntervalSince1970]];
	[body writeToFile:kHidPath atomically:YES encoding:NSUTF8StringEncoding error:nil];
	notify_post("com.noxlab.miao.hidtap");
	MiaoLog([NSString stringWithFormat:@"hid-req %.0f,%.0f", pt.x, pt.y]);
	MiaoToast([NSString stringWithFormat:@"HID %.0f,%.0f", pt.x, pt.y]);
}

static void MiaoConsumeHidFile(void) {
	if (!MiaoIsBackboardd()) return;
	NSString *raw = [NSString stringWithContentsOfFile:kHidPath encoding:NSUTF8StringEncoding error:nil];
	if (raw.length < 3) return;
	[[NSFileManager defaultManager] removeItemAtPath:kHidPath error:nil];
	NSString *line = [[raw componentsSeparatedByCharactersInSet:[NSCharacterSet newlineCharacterSet]] firstObject];
	NSArray *p = [line componentsSeparatedByString:@","];
	if (p.count < 2) return;
	CGFloat x = [p[0] doubleValue];
	CGFloat y = [p[1] doubleValue];
	NSTimeInterval now = NSDate.date.timeIntervalSince1970;
	if (now - gLastHid < 0.55) {
		MiaoLog(@"hid debounce");
		return;
	}
	gLastHid = now;
	MiaoLog([NSString stringWithFormat:@"hid-exec %.0f,%.0f", x, y]);
	MiaoPerformHumanTap(x, y);
}

void MiaoStartBackboardd(void) {
	if (gBackboardStarted || !MiaoIsBackboardd()) return;
	gBackboardStarted = YES;
	MiaoLog(@"backboardd listener start");
	int token = 0;
	notify_register_dispatch("com.noxlab.miao.hidtap", &token,
		dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_HIGH, 0),
		^(__unused int t) { MiaoConsumeHidFile(); });
	// poll backup
	dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
		while (YES) {
			MiaoConsumeHidFile();
			usleep(400000);
		}
	});
}

/// HID via backboardd (non locale Safari).
static void MiaoHumanTapAt(CGPoint pt, void (^done)(void)) {
	if (pt.x < 1 || pt.y < 1) {
		if (done) done();
		return;
	}
	MiaoRequestHidTap(pt);
	if (done) {
		dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.25 * NSEC_PER_SEC)), dispatch_get_main_queue(), done);
	}
}

#pragma mark - Safari actions (human)

static void MiaoActReady(void (^done)(BOOL ok)) {
	MiaoJS(@"(function(){return document.querySelectorAll('a[href*=\"/video/\"]').length+'|'+location.href;})()", ^(NSString *r) {
		BOOL ok = r && ![r hasPrefix:@"0|"];
		if (done) done(ok);
	});
}

static void MiaoActClickVideo(void) {
	MiaoToast(@"Thumb HID...");
	// 1) coordinate DOM  2) tap HID via backboardd (trusted)  3) JS solo se dopo 2.8s ancora in home
	NSString *js =
		@"(function(){"
		@"var as=[].slice.call(document.querySelectorAll('a[href*=\"/video/\"]'));"
		@"if(!as.length) return 'NONE';"
		@"var a=null;"
		@"for(var i=0;i<as.length;i++){"
		@"  var r=as[i].getBoundingClientRect();"
		@"  if(r.width>=50&&r.height>=50&&r.top>=60&&r.bottom<=window.innerHeight-10){a=as[i];break;}"
		@"}"
		@"if(!a) a=as[0];"
		@"a.scrollIntoView({block:'center'});"
		@"var r=a.getBoundingClientRect();"
		@"var href=a.href||a.getAttribute('href')||'';"
		@"if(href&&href.indexOf('http')!==0) href=location.origin+href;"
		@"return Math.round(r.left+r.width/2)+','+Math.round(r.top+r.height/2)+'|'+href;"
		@"})()";

	MiaoJS(js, ^(NSString *result) {
		if (!result || [result hasPrefix:@"NONE"]) {
			MiaoAck(@"click NONE");
			MiaoToast(@"Nessun thumb");
			return;
		}
		NSArray *parts = [result componentsSeparatedByString:@"|"];
		CGPoint pt = MiaoParseXY(parts.firstObject);
		NSString *href = parts.count > 1 ? parts[1] : nil;
		MiaoAck([NSString stringWithFormat:@"thumb %@", result]);
		MiaoRequestHidTap(pt);
		// secondo tap dopo breve pause (a volte serve)
		dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.7 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
			MiaoRequestHidTap(pt);
		});
		// fallback JS solo se HID non ha navigato
		if (href.length) {
			dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(3.0 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
				MiaoJS(@"(function(){return location.pathname;})()", ^(NSString *path) {
					if (path && [path containsString:@"/video/"]) {
						MiaoAck(@"HID navigated OK");
						MiaoToast(@"Video OK (HID?)");
						return;
					}
					MiaoAck(@"HID miss -> JS nav");
					MiaoToast(@"Fallback JS video");
					NSString *go = [NSString stringWithFormat:
						@"(function(){location.assign('%@');return 'JS';})()",
						[[href stringByReplacingOccurrencesOfString:@"'" withString:@"\\'"]
							stringByReplacingOccurrencesOfString:@"\\" withString:@"\\\\"]];
					MiaoJS(go, ^(NSString *r) { MiaoAck(r ?: @"js"); });
				});
			});
		}
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
			MiaoRequestHidTap(CGPointMake(b.size.width * 0.82, y));
			MiaoToast(@"Skip HID zona");
			return;
		}
		NSArray *parts = [result componentsSeparatedByString:@"|"];
		if (parts.count >= 2) {
			CGPoint pt = MiaoParseXY(parts[1]);
			if (pt.x > 1) MiaoRequestHidTap(pt);
		}
		MiaoAck([NSString stringWithFormat:@"skip %@", result]);
		MiaoToast(@"Skip OK+HID");
	});
}

/// Click ads: CTA preroll, learn more, exo real-href, area player ads
static void MiaoActClickAd(void) {
	MiaoToast(@"Click ads...");
	NSString *js =
		@"(function(){"
		@"function visible(el){"
		@"  if(!el) return false;"
		@"  var r=el.getBoundingClientRect();"
		@"  return r.width>12&&r.height>12&&r.bottom>0&&r.top<window.innerHeight;"
		@"}"
		@"function go(el,tag){"
		@"  if(!el||!visible(el)) return null;"
		@"  try{el.scrollIntoView({block:'center'});}catch(e){}"
		@"  try{el.click();}catch(e){}"
		@"  try{el.dispatchEvent(new MouseEvent('click',{bubbles:true,cancelable:true,view:window}));}catch(e){}"
		@"  var h=el.getAttribute('real-href')||el.href||el.getAttribute('href')||'';"
		@"  return tag+'|'+(h||((el.innerText||'').trim())).toString().slice(0,80);"
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
		@"  '[class*=\"preroll\"] a[href]',"
		@"  'a[target=\"_blank\"]'"
		@"];"
		@"for(var s=0;s<sels.length;s++){"
		@"  var nodes=[].slice.call(document.querySelectorAll(sels[s]));"
		@"  for(var i=0;i<nodes.length;i++){"
		@"    var el=nodes[i];"
		@"    var h=(el.getAttribute('real-href')||el.href||'').toLowerCase();"
		@"    var t=((el.innerText||'')+'').toLowerCase();"
		@"    if(/noxreel\\.uk/.test(h)&&!/click|out|go|redirect/.test(h)) continue;"
		@"    if(/skip|salta/.test(t)) continue;"
		@"    var r=go(el,'AD');"
		@"    if(r) return r;"
		@"  }"
		@"}"
		@"var ctaRe=/learn\\s*more|visit|scopri|visita|continua|click\\s*here|vai\\s*al\\s*sito|annuncio|advertiser/i;"
		@"var btns=[].slice.call(document.querySelectorAll('a,button,[role=button]'));"
		@"for(var j=0;j<btns.length;j++){"
		@"  if(ctaRe.test((btns[j].innerText||'')+'')){"
		@"    var r2=go(btns[j],'CTA');"
		@"    if(r2) return r2;"
		@"  }"
		@"}"
		@"// area creativo HTML preroll (div sopra Skip)"
		@"var player=document.querySelector('[data-nox-preroll],iframe[data-nox-preroll],iframe[title=\"preroll\"]');"
		@"if(player){var r3=go(player,'PREROLL'); if(r3) return r3;}"
		@"var box=document.querySelector('.relative.aspect-video, [class*=\"aspect-video\"]');"
		@"if(box){"
		@"  var mid=box.querySelector('a,button,div');"
		@"  if(mid&&!/skip|salta/i.test((mid.innerText||'')+'')){"
		@"    var r4=go(mid,'PLAYER');"
		@"    if(r4) return r4;"
		@"  }"
		@"  try{box.click(); return 'PLAYER-BOX';}catch(e){}"
		@"}"
		@"// iframe same-origin ads"
		@"var ifr=document.querySelectorAll('iframe');"
		@"for(var k=0;k<ifr.length;k++){"
		@"  try{"
		@"    var doc=ifr[k].contentDocument||(ifr[k].contentWindow&&ifr[k].contentWindow.document);"
		@"    if(!doc) continue;"
		@"    var a=doc.querySelector('a[href],button,[real-href]');"
		@"    if(a){a.click(); return 'IFRAME-AD|'+(a.href||a.getAttribute('real-href')||'').toString().slice(0,60);}"
		@"  }catch(e){}"
		@"}"
		@"return 'NONE';"
		@"})()";

	MiaoJS(js, ^(NSString *result) {
		if (!result || [result hasPrefix:@"NONE"]) {
			MiaoAck(@"clickad NONE");
			CGRect b = UIScreen.mainScreen.bounds;
			// tap centro player (spesso creativo ads)
			MiaoHumanTapAt(CGPointMake(b.size.width * 0.5, MIN(200, b.size.height * 0.28)), ^{});
			MiaoToast(@"Ads miss -> HID player");
			return;
		}
		MiaoAck([NSString stringWithFormat:@"clickad %@", result]);
		MiaoToast([NSString stringWithFormat:@"Ads %@", [[result componentsSeparatedByString:@"|"] firstObject]]);
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

	for (NSString *n in @[ @"ping", @"clickvideo", @"clickad", @"closeads", @"skipad", @"human", @"closeextra", @"where" ]) {
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

		// Backup openURL solo tardi (dopo chance HID/popunder)
		MiaoAfter(14.5, ^{
			MiaoToast(@"Backup openURL?");
			MiaoOpenURL(videoURL);
		});

		MiaoAfter(13.0, ^{ MiaoSendCmd(@"closeads"); });

		// Click ads (CTA / exo / player) prima dello Skip
		MiaoAfter(16.0, ^{ MiaoSendCmd(@"clickad"); });
		MiaoAfter(19.0, ^{ MiaoSendCmd(@"clickad"); });

		// Skip: bottone abilitato verso fine countdown (~10s). Forziamo enable+click.
		MiaoAfter(22.0, ^{ MiaoSendCmd(@"skipad"); });
		MiaoAfter(23.5, ^{ MiaoSendCmd(@"skipad"); });
		MiaoAfter(25.0, ^{ MiaoSendCmd(@"skipad"); });

		MiaoAfter(27.5, ^{ MiaoSendCmd(@"human"); });

		MiaoAfter(27.5 + watch, ^{
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
	MiaoLog(@"session 0.8 backboardd-hid");
	MiaoToast(@"Sessione 0.8 HID...");
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
	if (MiaoIsSB()) MiaoToast(@"Miao 0.8 - 3x Vol");
	else if (MiaoIsSafari()) MiaoStartSafari();
	else if (MiaoIsBackboardd()) MiaoStartBackboardd();
}

