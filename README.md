# Miao 0.11.1

Tutto quello che il sito puo' vedere arriva da un dito: `UITouch` sintetizzate
dentro Safari e mandate a `sendEvent:`, quindi hit-test, gesture recognizer e
web content le trattano come touch reali. Il JavaScript resta solo dove non
tocca nulla: leggere posizioni e stato.

Da questa versione ogni passo del run ha un **esito misurato**, i risultati
finiscono in file di eventi (Documents + Preferences + path rootless) e si
guardano dall'**app Miao** sulla home.

## Pannello (app Miao)
Icona sulla home, nessun SSH. Mostra le ultime 30 sessioni: per ognuna ora,
esito, durata, numero di passi, quanti falliti e il seed; toccandola si aprono i
passi con esito, durata in millisecondi e dettaglio. In basso: **Avvia** (1, 3,
5, 10, 25 o 50 sessioni), **Stop**, **Diagnosi**, **Pulisci**.

L'app e' firmata con `no-sandbox` / `no-container`: senza quello non legge i
file che scrive il tweak. Il `postinst` ri-applica le entitlements con `ldid`
dopo l'installazione. Se la lista e' vuota, **Diagnosi** dice se il problema e'
lettura, scrittura o file vuoto.

I comandi vanno a SpringBoard su `miao-sbcmd.txt` (e un fallback in Preferences)
+ notifica. I dati restano sul dispositivo: alle pagine visitate non viene
aggiunto nulla.

## Esiti per passo
Ogni passo scrive una riga in `/var/mobile/Documents/miao-events.jsonl`:

`sito-davanti`, `home-pronta`, `scroll`, `scelta-video`, `scroll-video`,
`tap-video`, `popunder`, `chiudi-ads`, `ritorno-sito`, `pagina-video`,
`tap-video-2`, `skip`, `teardown`.

Il criterio di riuscita del run e' **il video che parte**, non "ho tappato lo
skip": prima si dichiarava OK anche quando il tap veniva rifiutato.

## Motore di gesti (`TouchSimUIKit`)
Un solo driver per tap e trascinamenti, con le fasi su giri di runloop distinti
— se si accodano tutte insieme i gesture recognizer non avanzano e
`UIScrollView` non calcola nessuna velocita'.

- **tap**: 55-130 ms di pressione, deriva di 1-2 pt
- **swipe**: un punto ogni ~16 ms con scarto del 20%, oscillazione laterale
  perpendicolare al movimento, e profilo di velocita' `t^1.32`: parte da fermo e
  **si stacca ancora in corsa**, cosi' l'inerzia la mette la pagina. Uno scroll
  che si ferma esattamente dove finisce il dito non lo produce nessuna mano
- **impronta**: `majorRadius` 8.5-14.5 pt che varia ad ogni frame. Un touch con
  raggio 0 non esiste. `force` resta 0: l'11 Pro Max non ha 3D Touch
- se la view sparisce a metà gesto il touch viene **annullato**, non teletrasportato

## Un passaggio solo (`run`)
1. sito in primo piano e **home caricata** (`readyState` piu' almeno un video in
   lista, con ritentativi): con i tempi fissi il run partiva su un DOM vuoto e
   dava "nessun video in pagina" su un sito che funziona
2. **swipe** esplorativo di 200-500 px
3. si sceglie un video a caso tra quelli entro un paio di schermate, e ci si
   arriva con altri swipe che correggono il tiro (flick se e' lontano,
   trascinamento lento se e' vicino, max 4 passate)
4. pausa per guardare la miniatura, poi tap — **questo primo tap se lo prende
   il popunder**
5. sull'ad si resta qualche secondo e si scorre un po', come chi ci finisce per
   sbaglio; poi si chiude la scheda dalla UI di Safari
6. ri-tap sullo **stesso** video: adesso si entra
7. attesa che lo skip si sblocchi, tap, e verifica che il video sia `playing`
8. **teardown**: nessuna pagina esterna aperta e sito davanti, cosi' il run dopo
   non parte sullo stato lasciato dal precedente

SpringBoard non scandisce i passi a orologio: manda `run` e aspetta il verdetto
(`runend`), con un tetto di 120 s perche' Safari puo' morire.

## Quale pagina stiamo guardando
Due domande diverse, due webview diverse:

- **agire sul sito** → la webview del sito, anche se la scheda e' in secondo piano
- **sapere dove siamo** → la webview in primo piano

Chiedere "che path e'?" alla webview del sito mentre davanti c'e' un ad dava
sempre la risposta attesa, ed e' cosi' che il run si credeva sul video mentre era
sull'annuncio, aspettando uno skip che in una scheda in background non si sblocca
mai (WebKit sospende timer e `requestAnimationFrame`).

Il confronto dell'host si fa sull'**host parsato**, non con `containsString`: le
URL di redirect degli ads portano il dominio del publisher nei parametri
(`...&ref=noxreel.uk`) e finivano classificate come pagine del sito, mandando
all'aria ogni decisione successiva. Una pagina estranea viene riconosciuta anche
quando l'URL non e' ancora committed, perche' i popunder passano per
`about:blank`.

## Chiusura della scheda ads
Prima la strada nativa, quella che fa una persona: tap su **Schede**, tap sulla
**X** della scheda che non e' la nostra, tap sulla nostra per rientrare. I
controlli si trovano per etichetta accessibility (italiano e inglese), il frame
arriva in coordinate finestra e il tap e' un touch reale.

Se la UI non e' come ce l'aspettiamo si esce senza fare danni e si passa a
`window.close()` nella webview dell'ad, poi alle API private delle schede, poi
alla riapertura della home. Ogni passo verifica il proprio effetto.

Il comando `ax` stampa tutti i controlli visibili con etichetta, identifier e
frame: serve a leggere i nomi veri su questo device invece di indovinarli.

## Indietro
Swipe dal bordo sinistro (0.28-0.42 s, rilasciato in corsa). Se la pagina non
cambia, tap sul pulsante **Indietro** della barra. `history.back()` non si usa
piu': e' una chiamata che un dito non puo' fare.

## Nessuna traccia in pagina
- niente `window.__miaoTarget`: il video scelto viaggia come **indice nel DOM**
- niente `scrollIntoView`, `window.scrollBy`, `el.click()`,
  `removeAttribute('disabled')`, `v.currentTime`, `v.play()`
- la sonda diagnostica si installa solo con `Debug = 1` (o durante `calib`), con
  un nome di proprieta' casuale per sessione, e alla fine rimuove i listener e
  cancella la proprieta'. La calibrazione si fa una volta: il risultato resta in
  `miao-cal.plist` e non viene ripetuta
- la calibrazione aspetta il DOM: su una pagina ancora vuota la sonda veniva
  installata su un documento che il load sostituiva subito, e la misura diceva
  "nessun touch" quando invece il touch era arrivato

## Attesa dello skip
Cercato nel documento e negli iframe (il preroll VAST sta in `/x/pr`), pronto
solo se non e' `disabled`, non ha `pointer-events: none`, non e' semi-trasparente
e **non contiene cifre**: un countdown in corso mostra un numero, tipo "Salta tra
5". Dopo 25 tentativi si tappa quello che c'e', dopo 40 si esce. Se davanti c'e'
una pagina esterna non si aspetta: si chiude e si torna sul sito.

## Invariante sul tap
Non si tappa se la pagina da cui leggiamo le coordinate non e' anche quella in
primo piano: dopo un popunder il touch atterrerebbe sull'annuncio. In quel caso
esce `Tap NO: ad davanti`, l'esito del tap **viene propagato** al passo e nel log
finisce lo stato completo delle webview.

## Comandi
| comando | effetto |
|---|---|
| `run` | il passaggio completo |
| `ax` | tutti i controlli nativi con etichetta e frame |
| `scroll` | uno swipe di prova, riporta `scrollY` |
| `back` | swipe dal bordo, con fallback sul pulsante |
| `state` | dump webview: URL, visibilita', primo piano |
| `backsite` | recupera la scheda del sito |
| `calib` | misura dove atterra il touch |
| `clean` | rimuove la sonda dalla pagina |
| `human` | 1-3 swipe lenti con pause, il tempo sulla pagina |
| `closeextra` | chiude le pagine estranee e torna sul sito |
| `adloop` | vecchio loop a `LoopTaps` click, fuori dal flusso normale |

Dal pannello: `session N` e `stop` (notifiche `com.noxlab.miao.session` e
`.stop`, con `miao-sbcmd.txt` per il numero).

## Preferenze
`/var/mobile/Library/Preferences/com.noxlab.miao.plist`

| chiave | default | cosa fa |
|---|---|---|
| `HomeURL` | `https://noxreel.uk/` | sito da aprire |
| `Cycles` | 1 | passaggi per sessione avviata col volume |
| `WaitSeconds` | 14 | tempo di visione dopo lo skip |
| `LoopTaps` | 5 | click di `adloop` |
| `Debug` | 0 | installa la sonda e logga di piu' |

## File
| percorso | cosa contiene |
|---|---|
| `Documents/miao-events.jsonl` | esiti per passo (primario) |
| `Preferences/com.noxlab.miao.events.jsonl` | stesso log, fallback |
| `miao-events.err` | ultimo errore di scrittura eventi |
| `miao-loaded.txt` | log testuale della sessione corrente |
| `miao-ack.txt` | messaggi lunghi (dump webview, dump accessibility) |
| `miao-cal.plist` | correzione delle coordinate misurata da `calib` |
| `miao-postinst.txt` | esito install + entitlements del pannello |

## Install
Userspace Reboot dopo update. L'icona del pannello compare dopo `uicache`, che
il `postinst` esegue da solo.
