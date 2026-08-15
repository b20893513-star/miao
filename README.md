# Miao 0.8.5

## `BB OFF` / `HID OFF`
Su Dopamine **backboardd spesso non viene iniettato** → MiaoHID non parte.  
Ora il worker HID gira in **SpringBoard** (lì Miao carica già, volume ok).

## Toast
- All’avvio SB: **`HID worker SB ON`**
- Al tap: **`HID-sb x,y`** (bene) oppure **`HID OFF (no worker)`** (respring/reboot)
- Prima: **`HIT`/`MISS`** da elementFromPoint

## Dopo install
1. Aggiorna 0.8.5  
2. **Userspace Reboot** (o almeno Respring se il worker SB basta)  
3. All’unlock dovresti vedere **HID worker SB ON**  
4. Poi 3× Vol su Safari/noxreel  

Se non vedi `HID worker SB ON`, Miao non e' in SpringBoard.
