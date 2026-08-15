# Miao 0.9.0

## Fix vero
Le costanti dei campi digitizer IOKit erano **sbagliate**: i raggi del dito e la
pressione finivano su `AuxiliaryPressure`, `Twist` e `TiltY`. L'evento HID partiva
malformato, quindi il tap non veniva riconosciuto come touch reale.

Valori corretti (base = `11 << 16` = 720896):

| campo | offset |
|---|---|
| EventMask | 7 |
| Range | 8 |
| Touch | 9 |
| Pressure | 10 |
| MajorRadius | 20 |
| MinorRadius | 21 |
| IsDisplayIntegrated | 25 |

Inoltre l'evento ora ricalca SimulateTouch: hand identity 1, `EventMask`/`Range`/`Touch`
impostati sul parent dopo l'append, coordinate finger **sempre normalizzate 0..1**
(nessun path che mandava coords assolute).

## Calibrazione (`calib`)
Basta indovinare la conversione viewport→schermo. Ora c'e' una sonda:

1. si registra un listener JS su `touchstart`/`click`
2. si tappa un punto **senza link** noto
3. si legge dove il touch e' atterrato davvero

Il delta misurato viene salvato in `/var/mobile/Documents/miao-cal.plist` e applicato
ai tap successivi. Gira automaticamente alla prima sessione.

Toast:
- `CAL ok d=dx,dy tr1` → l'HID **arriva** alla pagina, offset corretto (`tr1` = `isTrusted`)
- `CAL NO TOUCH` → l'HID **non** raggiunge il web content: il problema e' l'injection, non le coordinate

## Toast
- `HID worker SB ON` all'unlock
- `HIT` / `MISS` (elementFromPoint) poi `HID-sb x,y`
- `Video OK` se naviga
- `Miss @x,y tr1` → il touch e' arrivato ma nel punto sbagliato
- `Miss NO TOUCH` → il touch non e' arrivato affatto

## Install
Userspace Reboot dopo update.
