#import <CoreGraphics/CoreGraphics.h>
#import <Foundation/Foundation.h>

#ifdef __cplusplus
extern "C" {
#endif

/// Simula un tap (down+up) alle coordinate in *points* (non pixel).
void MiaoPerformTap(CGFloat x, CGFloat y);

/// Tap con durata press in secondi (default ~0.05).
void MiaoPerformTapWithDuration(CGFloat x, CGFloat y, NSTimeInterval duration);

#ifdef __cplusplus
}
#endif
