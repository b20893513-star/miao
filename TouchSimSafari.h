#import <CoreGraphics/CoreGraphics.h>
#import <Foundation/Foundation.h>

#ifdef __cplusplus
extern "C" {
#endif

/// Tap trusted in-process Safari (WebKitTestRunner style):
/// IOHID + BKSHIDEventSetDigitizerInfo + UIApplication _enqueueHIDEvent:
/// Coordinate = punti finestra (non normalizzate 0..1).
/// Ritorna YES se enqueue riuscito.
BOOL MiaoSafariTrustedTapWindow(CGFloat x, CGFloat y);

#ifdef __cplusplus
}
#endif
