#import <UIKit/UIKit.h>

#ifdef __cplusplus
extern "C" {
#endif

/**
 Tap umano sintetizzato dentro Safari a livello UIKit (UITouch + sendEvent:).
 Non passa dall'HID: il touch entra nel dispatch normale di UIKit, viene
 hit-testato e consegnato al gesture recognizer di WebKit, quindi il web
 process lo vede come touch reale (`isTrusted`, user gesture valida).

 `winPt` in coordinate FINESTRA. Ritorna NO se le API private mancano;
 `why` (opzionale) riceve una diagnosi.
 */
BOOL MiaoUIKitHumanTap(CGPoint winPt, NSString **why);

#ifdef __cplusplus
}
#endif
