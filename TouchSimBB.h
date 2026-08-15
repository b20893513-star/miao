#import <CoreGraphics/CoreGraphics.h>
#import <Foundation/Foundation.h>

#ifdef __cplusplus
extern "C" {
#endif

/// Coords NORMALIZZATE 0..1 (path backboardd / SimulateTouch).
void MiaoPerformHumanTapNorm(CGFloat nx, CGFloat ny);

/// Coords SCHERMO in points + contextId CAWindowServer (path SpringBoard → Safari).
void MiaoPerformHumanTapScreen(CGFloat x, CGFloat y);

#ifdef __cplusplus
}
#endif
