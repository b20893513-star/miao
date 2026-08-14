#import <CoreGraphics/CoreGraphics.h>
#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/// Simula un tap (down+up) alle coordinate in *points* (non pixel).
/// Destinato a SpringBoard / Home. Non iniettare in Safari in v0.
void MiaoPerformTap(CGFloat x, CGFloat y);

/// Tap con durata press in secondi (default ~0.05).
void MiaoPerformTapWithDuration(CGFloat x, CGFloat y, NSTimeInterval duration);

NS_ASSUME_NONNULL_END
