#import <CoreGraphics/CoreGraphics.h>
#import <Foundation/Foundation.h>

#ifdef __cplusplus
extern "C" {
#endif

/// Tap semplice down/up (points).
void MiaoPerformTap(CGFloat x, CGFloat y);

/// Tap con durata press.
void MiaoPerformTapWithDuration(CGFloat x, CGFloat y, NSTimeInterval duration);

/// Gesto stile dito: down → micro-move → up (più vicino a touch trusted).
/// Bloccante: chiamare da queue background, MAI da SpringBoard.
void MiaoPerformHumanTap(CGFloat x, CGFloat y);

#ifdef __cplusplus
}
#endif
