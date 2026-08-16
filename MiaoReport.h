#import <Foundation/Foundation.h>

/**
 Esiti delle sessioni in un formato che si possa leggere da un altro processo.

 Il tweak scrive una riga JSON per evento (JSON Lines) e il pannello la rilegge:
 niente stato condiviso in memoria, niente IPC da mantenere, e il file resta
 leggibile anche quando Safari e' stato ucciso a meta' sessione. I dati restano
 sul dispositivo: nessuna informazione viene aggiunta alle pagine visitate.
 */

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

#ifdef __cplusplus
extern "C" {
#endif

#pragma mark - Scrittura (tweak)

/// Apre una sessione e restituisce il suo id. `seed` 0 = generato qui.
NSString *MiaoReportBegin(NSString *kind, uint32_t seed);

/// Registra un passo. La durata e' il tempo dal passo precedente, misurato qui
/// per non doverla passare da ogni punto del flusso.
void MiaoReportStep(NSString *name, BOOL ok, NSString *detail);

/// Chiude la sessione aperta. Senza questa la sessione resta "in corso".
void MiaoReportEnd(BOOL ok, NSString *verdict);

/// Id della sessione aperta, nil se nessuna.
NSString *MiaoReportSid(void);

/// Seed della sessione aperta: le pause e le ampiezze dei gesti derivano da qui,
/// cosi' una sessione che fallisce si puo' rigiocare identica.
uint32_t MiaoReportSeed(void);

#pragma mark - Lettura (pannello)

/// Le ultime `maxSessions` sessioni, dalla piu' recente alla piu' vecchia.
NSArray<MiaoRunReport *> *MiaoReportRead(NSInteger maxSessions);

void MiaoReportClear(void);

#ifdef __cplusplus
}
#endif
