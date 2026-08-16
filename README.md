# Miao 0.10.0

Tutto quello che il sito puo' vedere arriva da un dito: `UITouch` sintetizzate
dentro Safari e mandate a `sendEvent:`, quindi hit-test, gesture recognizer e
web content le trattano come touch reali. Il JavaScript resta solo dove non
tocca nulla: leggere posizioni e stato.

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

## Un passaggio solo (`run`)
1. sito in primo piano e sulla home
2. **swipe** esplorativo di 200-500 px
3. si sceglie un video a caso tra quelli entro un paio di schermate, e ci si
   arriva con altri swipe che correggono il tiro (flick se e' lontano,
   trascinamento lento se e' vicino, max 4 passate)
4. pausa per guardare la miniatura, poi tap — **questo primo tap se lo prende
   il popunder**
5. sull'ad si resta qualche secondo e si scorre un po', come chi ci finisce per
   sbaglio; poi si chiude la scheda dalla UI di Safari
6. ri-tap sullo **stesso** video: adesso si entra
7. attesa che lo skip si sblocchi, poi tap sullo skip

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

## Attesa dello skip
Cercato nel documento e negli iframe (il preroll VAST sta in `/x/pr`), pronto
solo se non e' `disabled`, non ha `pointer-events: none`, non e' semi-trasparente
e **non contiene cifre**: un countdown in corso mostra un numero, tipo "Salta tra
5". Dopo 25 tentativi si tappa quello che c'e', dopo 40 si esce.

## Invariante sul tap
Non si tappa se la pagina da cui leggiamo le coordinate non e' anche quella in
primo piano: dopo un popunder il touch atterrerebbe sull'annuncio. In quel caso
esce `Tap NO: ad davanti` e nel log finisce lo stato completo delle webview.

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
| `adloop` | vecchio loop a `LoopTaps` click, fuori dal flusso normale |

## Preferenze
`/var/mobile/Library/Preferences/com.noxlab.miao.plist`

| chiave | default | cosa fa |
|---|---|---|
| `HomeURL` | `https://noxreel.uk/` | sito da aprire |
| `Cycles` | 1 | quanti passaggi per sessione |
| `WaitSeconds` | 14 | tempo di visione dopo lo skip |
| `LoopTaps` | 5 | click di `adloop` |
| `Debug` | 0 | installa la sonda e logga di piu' |

## Install
Userspace Reboot dopo update.
