#import <Foundation/Foundation.h>

/**
 Esiti delle sessioni in un formato che si possa leggere da un altro processo.

 Il tweak scrive una riga JSON per evento (JSON Lines) e il pannello la rilegge.
 I dati restano sul dispositivo: nessuna informazione viene aggiunta alle pagine.
 */

/// Path primario (Documents mobile). Su Dopamine l'app lo legge solo con
/// no-container / no-sandbox; c'e' anche un path di fallback in Preferences.
extern NSString *const kMiaoEventsPath;

/// Un passo della sessione con il suo esito misurato.
@interface MiaoStepInfo : NSObject
@property (nonatomic, copy) NSString *name;
@property (nonatomic) BOOL ok;
@property (nonatomic) NSTimeInterval ms;
@property (nonatomic, copy) NSString *detail;
@property (nonatomic) NSTimeInterval at;
@end

/// Una sessione: i passi in ordine piu' il verdetto finale.
@interface MiaoRunReport : NSObject
@property (nonatomic, copy) NSString *sid;
@property (nonatomic, copy) NSString *kind;
@property (nonatomic) uint32_t seed;
@property (nonatomic) NSTimeInterval start;
/// 0 quando la sessione non ha ancora chiuso (o e' morta a meta').
@property (nonatomic) NSTimeInterval end;
@property (nonatomic) BOOL ok;
@property (nonatomic, copy) NSString *verdict;
@property (nonatomic, strong) NSMutableArray<MiaoStepInfo *> *steps;
- (NSTimeInterval)durationMs;
- (NSInteger)failedCount;
@end

/// Diagnosi leggibile: path usati, byte, ultimo errore di I/O, se si puo' scrivere.
@interface MiaoReportDiag : NSObject
@property (nonatomic, copy) NSString *primaryPath;
@property (nonatomic, copy) NSString *fallbackPath;
@property (nonatomic, copy) NSString *activePath;
@property (nonatomic) unsigned long long bytes;
@property (nonatomic) NSInteger lineCount;
@property (nonatomic) NSInteger sessionCount;
@property (nonatomic) BOOL canRead;
@property (nonatomic) BOOL canWrite;
@property (nonatomic, copy) NSString *lastError;
@property (nonatomic, copy) NSString *summary;
@end

#ifdef __cplusplus
extern "C" {
#endif

#pragma mark - Scrittura (tweak)

/// Assicura cartelle/file e permessi 0666. Idempotente.
void MiaoReportEnsure(void);

/// Apre una sessione e restituisce il suo id. `seed` 0 = generato qui.
NSString *MiaoReportBegin(NSString *kind, uint32_t seed);

/// Registra un passo. La durata e' il tempo dal passo precedente.
void MiaoReportStep(NSString *name, BOOL ok, NSString *detail);

/// Chiude la sessione aperta.
void MiaoReportEnd(BOOL ok, NSString *verdict);

NSString *MiaoReportSid(void);
uint32_t MiaoReportSeed(void);

/// Ultimo errore di scrittura (stringa vuota se ok).
NSString *MiaoReportLastWriteError(void);

#pragma mark - Lettura (pannello)

NSArray<MiaoRunReport *> *MiaoReportRead(NSInteger maxSessions);
MiaoReportDiag *MiaoReportDiagnose(void);
void MiaoReportClear(void);

#ifdef __cplusplus
}
#endif
