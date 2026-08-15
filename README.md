# Miao 0.9.2

## Il tap funziona
Il touch sintetizzato via UIKit dentro Safari (0.9.1) raggiunge WebKit e apre il
popunder. Le tre vie HID restano chiuse e servono solo da fallback:

| via | esito |
|---|---|
| `MiaoHID` in backboardd | la dylib non viene iniettata |
| `ClientDispatch` da SpringBoard | il server HID **e'** backboardd, non noi |
| `_enqueueHIDEvent:` in Safari | ignorato senza entitlement |

## Il loop (`adloop`)
Il popunder porta in primo piano la scheda ads, quindi dopo ogni click servono
pulizia e ritorno. Il loop gira **dentro Safari**, non a tempo da SpringBoard:

1. torna sulla scheda del sito e, se il tap ci ha portati su `/video/`, risale
   alla home con `history.back()`
2. sceglie una thumb casuale e la tappa con un touch umano
3. aspetta che l'impression sia registrata, poi chiude la scheda ads
4. ripeti, `LoopTaps` volte (default 5)

Quante schede ads sono state aperte finisce nel toast finale: `Loop fine 5 tap 3 ads`.

## Due bug del flusso, corretti
**La webview sbagliata.** `MiaoBestWebView` prendeva la webview piu' grande: quando
la scheda ads passa in primo piano quella e' la pagina dell'ad, quindi ogni comando
JS finiva sull'ad invece che sul sito. Ora la priorita' e' la webview del sito,
riconosciuta dall'host di `HomeURL`.

**Due thumb diverse.** La fase di scroll scegliera un elemento e la fase di tap ne
ripescava un altro per conto suo, quindi si tappava una thumb che poteva non essere
quella portata a centro schermo. Ora il target viene memorizzato in `__miaoTarget`
e il tap usa quello.

## Tap umano
- thumb casuale a ogni giro, non sempre la stessa
- punto casuale nella zona centrale del rect (56%), non il pixel esatto
- contatto 55-130 ms, con due micro-movimenti di 1-2 px
- fasi `Began` -> `Moved` -> `Moved` -> `Ended` su giri di runloop distinti
- pause fra le azioni sempre randomizzate

## Comandi
| comando | effetto |
|---|---|
| `adloop` | il loop completo |
| `backsite` | torna sulla scheda del sito |
| `closeads` | chiude le schede non del sito e torna al sito |
| `calib` | misura dove atterra il touch |
| `clickvideo` | un singolo click su thumb |

## Toast
- `Loop 3` -> giri rimanenti
- `UIK x,y` -> tap inviato
- `Ads +1` -> scheda ads rilevata, la chiudo
- `Video OK` -> navigazione avvenuta
- `Miss NO TOUCH` -> il touch non e' arrivato alla pagina

## Install
Userspace Reboot dopo update.
