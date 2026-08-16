# Legge l'ultima sessione Miao dal telefono via SSH.
# Uso:
#   .\scripts\pull-session.ps1
#   .\scripts\pull-session.ps1 -Host 192.168.1.78
param(
  [string]$PhoneHost = $env:PHONE_HOST,
  [string]$User = $(if ($env:PHONE_USER) { $env:PHONE_USER } else { "mobile" }),
  [int]$Port = $(if ($env:PHONE_PORT) { [int]$env:PHONE_PORT } else { 22 }),
  [string]$Key = "$env:USERPROFILE\.ssh\miao_phone"
)

if (-not $PhoneHost) {
  Write-Host "Imposta PHONE_HOST o passa -Host IP" -ForegroundColor Yellow
  exit 1
}
if (-not (Test-Path $Key)) {
  Write-Host "Chiave assente: $Key" -ForegroundColor Red
  exit 1
}

$ssh = @(
  "-i", $Key,
  "-p", "$Port",
  "-o", "ConnectTimeout=10",
  "-o", "StrictHostKeyChecking=accept-new",
  "${User}@${PhoneHost}"
)

# Safari (sandbox) scrive su path JB; SpringBoard su Documents.
# Preferiamo JB se presente e piu' ricco.
$remote = @'
echo "=== HOST $(hostname) $(date) ==="
JB=/var/jb/var/mobile/Library/Miao/events.jsonl
DOC=/var/mobile/Documents/miao-events.jsonl
PREF=/var/mobile/Library/Preferences/com.noxlab.miao.events.jsonl
EVENTS=""
if [ -f "$JB" ]; then EVENTS="$JB"; elif [ -f "$DOC" ]; then EVENTS="$DOC"; else EVENTS="$PREF"; fi
echo "=== EVENTS PATH: $EVENTS ==="
ls -la "$JB" "$DOC" "$PREF" 2>/dev/null || true
echo "=== FILES ==="
ls -la /var/mobile/Documents/miao* 2>/dev/null || true
ls -la /var/jb/var/mobile/Library/Miao/ 2>/dev/null || true
echo "=== EVENTS (ultime 120 righe) ==="
tail -n 120 "$EVENTS" 2>/dev/null || echo "(no events)"
echo "=== ACK (ultime 40) ==="
tail -n 40 /var/mobile/Documents/miao-ack.txt 2>/dev/null || echo "(no ack)"
echo "=== LOG (ultime 60) ==="
tail -n 60 /var/mobile/Documents/miao-loaded.txt 2>/dev/null || echo "(no log)"
echo "=== POSTINST ==="
tail -n 20 /var/mobile/Documents/miao-postinst.txt 2>/dev/null || true
'@

Write-Host ">> ssh ${User}@${PhoneHost}:${Port}"
& ssh @ssh $remote
exit $LASTEXITCODE
