# Miao 0.9.3

## Il bug del `NO TOUCH` dopo il popunder
Il tap UIKit funziona, ma dopo l'apertura della scheda ads lavoravamo su **due
contesti diversi**:

- le coordinate e la sonda JS venivano dalla webview del sito, che dopo il
  popunder e' in secondo piano
- il tap viene consegnato con un hit-test sulla finestra **visibile**, che in
  quel momento mostra la pagina dell'annuncio

Quindi il touch atterrava, ma sulla pagina dell'ad, e il listener che lo
aspettava stava sull'altra pagina. Da qui `CAL NO TOUCH` e il loop fermo.

## L'invariante
Non si tappa se la pagina da cui leggiamo le coordinate non e' anche quella in
primo piano. Meglio non tappare che tappare a caso: in quel caso arriva
`Tap NO: ad davanti` e il log riporta lo stato completo delle webview.

Prima si sistema lo stato, si **verifica**, e solo dopo si tappa. La verifica e'
la parte che mancava: prima ogni passo era a fiducia.

## Recupero della scheda giusta
`MiaoEnsureSiteFront` prova tre vie in ordine e controlla il risultato dopo
ognuna, invece di dare per riuscita la prima:

1. `window.close()` dentro la webview dell'ad. Funziona senza API private,
   perche' quella pagina e' stata aperta da uno script
2. le API private delle schede (`setActiveTabDocument:` e simili), che su iOS 16
   possono non rispondere
3. riapertura della home, che porta il sito davanti in ogni caso

## Contare gli ads senza API private
`MiaoAdTabCount` contava le schede tramite API private che possono tornare una
lista vuota, quindi non rilevava nulla. Ora conta le **webview**, che sono
sempre visibili nella gerarchia insieme al loro URL.

## Comando `state`
Scrive nel log lo stato reale: quante webview, l'URL di ognuna, quale e' visibile,
quale e' in primo piano e se e' quella del sito. E' la prima cosa da guardare
quando qualcosa non torna.

## Tap umano
- thumb casuale a ogni giro, punto casuale nella zona centrale del rect
- contatto 55-130 ms con due micro-movimenti di 1-2 px
- fasi `Began` -> `Moved` -> `Moved` -> `Ended` su giri di runloop distinti
- pause fra le azioni sempre randomizzate

## Comandi
| comando | effetto |
|---|---|
| `adloop` | il loop completo, `LoopTaps` volte |
| `state` | dump dello stato webview |
| `backsite` | recupera la scheda del sito |
| `calib` | misura dove atterra il touch |
| `clickvideo` | un singolo click su thumb |

## Toast
- `Loop 3` -> giri rimanenti
- `UIK x,y` -> tap inviato
- `Ads +1` -> pagina ads rilevata, la chiudo
- `Tap NO: ad davanti` -> tap bloccato dall'invariante
- `CAL ok d=dx,dy tr1` -> il touch arriva, `tr1` = `isTrusted`
- `WK 3 front=sito` -> risposta di `state`

## Install
Userspace Reboot dopo update.
