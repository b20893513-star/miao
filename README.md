# Miao 0.9.1

## Perche' l'HID non poteva funzionare
La calibrazione 0.9.0 ha risposto in modo definitivo: `CAL NO TOUCH`, cioe' l'evento
HID non arrivava mai al contenuto web. Le tre strade HID sono chiuse su questo setup:

| via | esito |
|---|---|
| `MiaoHID` in backboardd | la dylib non viene iniettata (`HID? backboardd OFF`) |
| `IOHIDEventSystemClientDispatchEvent` da SpringBoard | il server HID **e'** backboardd, non noi |
| `_enqueueHIDEvent:` in Safari | ignorato senza entitlement |

## La via che funziona: touch UIKit dentro Safari
Invece di iniettare hardware, sintetizziamo una `UITouch` e la consegniamo con
`-[UIApplication sendEvent:]` **dentro il processo Safari**. Il touch entra nel
dispatch normale di UIKit, viene hit-testato e consegnato al gesture recognizer di
WebKit: il web process lo vede come touch reale, con `isTrusted` e user gesture
valida. Non serve ne' HID ne' entitlement.

## Tap umano
Il sito non deve distinguere il tap da un dito:

- punto casuale nella zona centrale della thumbnail (56% del rect), non il pixel esatto
- durata del contatto casuale tra 55 e 130 ms
- due micro-movimenti di 1-2 px tra down e up (un dito non sta mai fermo)
- fasi `Began` → `Moved` → `Moved` → `Ended` su giri di runloop distinti, come un touch reale

## Toast
- `UIK x,y` → tap UIKit inviato (percorso buono)
- `CAL ok d=dx,dy tr1` → il touch arriva alla pagina, `tr1` = `isTrusted`
- `CAL NO TOUCH` → non arriva: leggi `miao-ack.txt` per il motivo (`uikit tap fail: ...`)
- `HID-sb x,y` / `HID OFF` → siamo caduti nel fallback, il tap UIKit e' fallito
- `Miss @x,y tr1` → touch arrivato ma nel punto sbagliato
- `Video OK` → navigazione avvenuta

## Install
Userspace Reboot dopo update.
