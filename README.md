# Miao 0.9.4

## Un passaggio solo (`run`)
Niente piu' loop: la sessione fa un giro lineare, e ogni passo verifica il
proprio effetto prima del successivo.

1. sito in primo piano e sulla home
2. scroll umano di 180-440 px
3. tap su una thumb casuale — **questo primo tap se lo prende il popunder**
4. la pagina ads viene chiusa con `window.close()` e si torna al sito
5. ri-tap sulla **stessa** thumb: adesso si entra nel video
6. attesa che lo skip si sblocchi, poi tap sullo skip

Il doppio tap non e' una ripetizione difensiva: e' il comportamento reale del
popunder, che consuma il primo click. Il target resta memorizzato in
`__miaoTarget`, quindi il secondo tap va sullo stesso video.

## Attesa dello skip
Lo skip viene cercato nel documento e dentro gli iframe (il preroll VAST sta in
`/x/pr`), e considerato pronto solo se non e' `disabled`, non ha
`pointer-events: none`, non e' semi-trasparente e **non contiene cifre**: un
countdown ancora in corso mostra un numero, tipo "Salta tra 5".

Si controlla ogni secondo circa. Dopo 25 tentativi si tappa comunque quello che
c'e', dopo 40 si esce con `skip mai sbloccato`, cosi' non resta appeso.

## Invariante sul tap
Non si tappa se la pagina da cui leggiamo le coordinate non e' anche quella in
primo piano: dopo un popunder il touch atterrerebbe sull'annuncio. In quel caso
esce `Tap NO: ad davanti` e nel log finisce lo stato completo delle webview.

## Recupero della scheda
`MiaoEnsureSiteFront` prova in ordine e verifica dopo ogni tentativo:

1. `window.close()` nella webview dell'ad, senza API private, perche' quella
   pagina l'ha aperta uno script
2. le API private delle schede, che su iOS 16 possono non rispondere
3. riapertura della home

## Comandi
| comando | effetto |
|---|---|
| `run` | il passaggio completo |
| `state` | dump webview: URL, visibilita', primo piano |
| `backsite` | recupera la scheda del sito |
| `calib` | misura dove atterra il touch |
| `adloop` | vecchio loop a `LoopTaps` click, fuori dal flusso normale |

## Toast in sequenza
`Run...` -> `Scroll...` -> `Click video` -> `Ads +1, chiudo` ->
`Ri-click video (1)` -> `Sul video` -> `Attendo skip (5)` -> `Skip!` ->
`Run OK skip fatto, playing|/video/...`

Se qualcosa si ferma: `Run stop: <motivo>` dice a che passo, e
`/var/mobile/Documents/miao-ack.txt` ha il dettaglio.

## Install
Userspace Reboot dopo update.
