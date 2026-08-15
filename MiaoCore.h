#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>

void MiaoLog(NSString *note);
void MiaoAfter(NSTimeInterval sec, void (^block)(void));
void MiaoVol(void);
void MiaoBoot(void);
void MiaoStartSafari(void);
void MiaoStartBackboardd(void);
BOOL MiaoIsSB(void);
BOOL MiaoIsSafari(void);
BOOL MiaoIsBackboardd(void);
