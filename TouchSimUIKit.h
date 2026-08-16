#import <UIKit/UIKit.h>

#ifdef __cplusplus
extern "C" {
#endif

/**
 Gesti sintetizzati dentro Safari a livello UIKit (UITouch + sendEvent:).
 Non passano dall'HID: il touch entra nel dispatch normale di UIKit, viene
 hit-testato e consegnato al gesture recognizer di WebKit, quindi il web
 process lo vede come touch reale (`isTrusted`, user gesture valida).
 Funzionano anche sulla UI nativa di Safari, non solo sul contenuto web.

 Coordinate in punti FINESTRA. `why` (opzionale) riceve una diagnosi.
 */

/// Tap: down, micro-drift, up.
BOOL MiaoUIKitHumanTap(CGPoint winPt, NSString **why);

/**
 Trascinamento con profilo di velocita' umano: parte da fermo, accelera e viene
 rilasciato ancora in movimento, cosi' e' `UIScrollView` ad applicare l'inerzia.
 `done` viene chiamato al rilascio del dito (l'inerzia continua dopo).
 */
BOOL MiaoUIKitSwipe(CGPoint from, CGPoint to, NSTimeInterval duration,
					NSString **why, void (^done)(void));

#ifdef __cplusplus
}
#endif
