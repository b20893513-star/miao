#import "MiaoAX.h"
#import <objc/message.h>

@implementation MiaoAXNode
- (CGPoint)center {
	return CGPointMake(CGRectGetMidX(self.frame), CGRectGetMidY(self.frame));
}
- (NSString *)description {
	return [NSString stringWithFormat:@"%@ \"%@\" id=%@ @%.0f,%.0f %.0fx%.0f",
			self.cls ?: @"?", self.label ?: @"", self.ident ?: @"-",
			self.frame.origin.x, self.frame.origin.y,
			self.frame.size.width, self.frame.size.height];
}
@end

static NSString *MiaoAXStr(id obj, SEL sel) {
	if (![obj respondsToSelector:sel]) return nil;
	id v = nil;
	@try { v = ((id (*)(id, SEL))objc_msgSend)(obj, sel); }
	@catch (NSException *ex) { return nil; }
	return ([v isKindOfClass:[NSString class]] && [v length]) ? v : nil;
}

static BOOL MiaoAXUsableFrame(CGRect f) {
	return f.size.width > 6 && f.size.height > 6 && f.size.width < 3000 && f.size.height < 3000;
}

/// Elementi accessibili che non sono view (array `accessibilityElements`).
static void MiaoAXCollectElements(UIView *host, NSMutableArray<MiaoAXNode *> *out) {
	NSArray *els = nil;
	@try { els = host.accessibilityElements; } @catch (NSException *ex) { (void)ex; }
	if (!els.count) return;
	UIWindow *win = host.window;
	for (id el in els) {
		if ([el isKindOfClass:[UIView class]]) continue; // le view le prende il walker
		CGRect scr = CGRectZero;
		@try { scr = [el accessibilityFrame]; } @catch (NSException *ex) { continue; }
		if (!MiaoAXUsableFrame(scr)) continue;
		CGRect fr = scr;
		if (win) {
			CGPoint o = [win convertPoint:scr.origin fromWindow:nil];
			fr = CGRectMake(o.x, o.y, scr.size.width, scr.size.height);
		}
		MiaoAXNode *n = [MiaoAXNode new];
		n.label = MiaoAXStr(el, @selector(accessibilityLabel));
		n.ident = MiaoAXStr(el, @selector(accessibilityIdentifier));
		n.cls = NSStringFromClass([el class]);
		n.frame = fr;
		if (n.label.length || n.ident.length) [out addObject:n];
	}
}

static void MiaoAXWalk(UIView *v, NSMutableArray<MiaoAXNode *> *out, NSInteger depth) {
	if (!v || depth > 60) return;
	if (v.tag == kMiaoAXIgnoreTag) return;
	if (v.hidden || v.alpha < 0.03) return;

	CGRect fr = [v convertRect:v.bounds toView:nil];
	if (MiaoAXUsableFrame(fr)) {
		NSString *label = MiaoAXStr(v, @selector(accessibilityLabel));
		NSString *ident = MiaoAXStr(v, @selector(accessibilityIdentifier));
		BOOL interactive = v.isAccessibilityElement || [v isKindOfClass:[UIControl class]];
		if (interactive && (label.length || ident.length)) {
			MiaoAXNode *n = [MiaoAXNode new];
			n.label = label;
			n.ident = ident;
			n.cls = NSStringFromClass([v class]);
			n.frame = fr;
			[out addObject:n];
		}
		MiaoAXCollectElements(v, out);
	}
	for (UIView *s in v.subviews) MiaoAXWalk(s, out, depth + 1);
}

NSArray<MiaoAXNode *> *MiaoAXNodes(void) {
	NSMutableArray<MiaoAXNode *> *out = [NSMutableArray array];
	NSMutableArray *wins = [NSMutableArray array];
	for (UIScene *sc in UIApplication.sharedApplication.connectedScenes) {
		if ([sc isKindOfClass:[UIWindowScene class]])
			[wins addObjectsFromArray:((UIWindowScene *)sc).windows];
	}
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations"
	if (!wins.count) [wins addObjectsFromArray:UIApplication.sharedApplication.windows];
#pragma clang diagnostic pop
	for (UIWindow *w in wins) MiaoAXWalk(w, out, 0);
	return out;
}

/// 3 = label uguale, 2 = inizia per, 1 = contiene. 0 = niente.
static NSInteger MiaoAXScore(NSString *hay, NSString *needle) {
	if (!hay.length || !needle.length) return 0;
	NSString *h = hay.lowercaseString;
	NSString *n = needle.lowercaseString;
	if ([h isEqualToString:n]) return 3;
	if ([h hasPrefix:n]) return 2;
	if ([h containsString:n]) return 1;
	return 0;
}

NSArray<MiaoAXNode *> *MiaoAXFindAll(NSArray<NSString *> *needles) {
	NSMutableArray *scored = [NSMutableArray array];
	for (MiaoAXNode *n in MiaoAXNodes()) {
		NSInteger best = 0;
		for (NSString *needle in needles) {
			best = MAX(best, MiaoAXScore(n.label, needle));
			best = MAX(best, MiaoAXScore(n.ident, needle));
		}
		if (best > 0) [scored addObject:@[ @(best), n ]];
	}
	// a pari punteggio vince il controllo piu' piccolo: e' il pulsante, non il contenitore
	[scored sortUsingComparator:^NSComparisonResult(NSArray *a, NSArray *b) {
		NSInteger sa = [a[0] integerValue], sb = [b[0] integerValue];
		if (sa != sb) return sa > sb ? NSOrderedAscending : NSOrderedDescending;
		CGRect fa = ((MiaoAXNode *)a[1]).frame, fb = ((MiaoAXNode *)b[1]).frame;
		CGFloat aa = fa.size.width * fa.size.height, ab = fb.size.width * fb.size.height;
		if (aa == ab) return NSOrderedSame;
		return aa < ab ? NSOrderedAscending : NSOrderedDescending;
	}];
	NSMutableArray *out = [NSMutableArray array];
	for (NSArray *pair in scored) [out addObject:pair[1]];
	return out;
}

MiaoAXNode *MiaoAXFind(NSArray<NSString *> *needles) {
	return MiaoAXFindAll(needles).firstObject;
}

NSString *MiaoAXDump(void) {
	NSArray<MiaoAXNode *> *nodes = MiaoAXNodes();
	NSMutableString *s = [NSMutableString stringWithFormat:@"ax %lu elementi", (unsigned long)nodes.count];
	for (MiaoAXNode *n in nodes) [s appendFormat:@"\n  %@", n];
	return s;
}
