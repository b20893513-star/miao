#import <UIKit/UIKit.h>

/// Le nostre view (toast) hanno questo tag: la ricerca le salta.
typedef NS_ENUM(NSInteger, MiaoAXTag) {
	kMiaoAXIgnoreTag = 0x4D49
};

/// Un controllo nativo trovato nella gerarchia, con frame in coordinate FINESTRA.
@interface MiaoAXNode : NSObject
@property (nonatomic, copy) NSString *label;
@property (nonatomic, copy) NSString *ident;
@property (nonatomic, copy) NSString *cls;
@property (nonatomic) CGRect frame;
@property (nonatomic, readonly) CGPoint center;
@end

#ifdef __cplusplus
extern "C" {
#endif

/// Tutti gli elementi accessibili visibili adesso.
NSArray<MiaoAXNode *> *MiaoAXNodes(void);

/// Il match migliore per una delle stringhe (confronto case-insensitive).
MiaoAXNode *MiaoAXFind(NSArray<NSString *> *needles);

/// Tutti i match, dal migliore al peggiore.
NSArray<MiaoAXNode *> *MiaoAXFindAll(NSArray<NSString *> *needles);

/// Dump leggibile: serve a scoprire come si chiamano davvero i pulsanti
/// su questo device e in questa lingua, invece di indovinare.
NSString *MiaoAXDump(void);

#ifdef __cplusplus
}
#endif
