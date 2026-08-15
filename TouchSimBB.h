#import <CoreGraphics/CoreGraphics.h>
#import <Foundation/Foundation.h>

#ifdef __cplusplus
extern "C" {
#endif

/// Gesto dito con coordinate NORMALIZZATE 0..1 (niente UIKit / UIScreen).
void MiaoPerformHumanTapNorm(CGFloat nx, CGFloat ny);

#ifdef __cplusplus
}
#endif
