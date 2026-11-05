#!/bin/bash
# Public address for the phones, through an ngrok tunnel to this Mac. Use it when the Mac is on the dog's
# wifi and the phones are elsewhere (museum wifi, 4G). Ronda must be running (./run.sh).
cd "$(dirname "$0")"
if ! curl -s 127.0.0.1:4040/api/tunnels >/dev/null 2>&1; then
  nohup ngrok http "${PORT:-8000}" --log=stdout > data/ngrok.log 2>&1 &
  for i in 1 2 3 4 5 6 7 8 9 10; do sleep 1; curl -s 127.0.0.1:4040/api/tunnels >/dev/null 2>&1 && break; done
fi
URL=$(curl -s 127.0.0.1:4040/api/tunnels | python3 -c "import sys,json; t=json.load(sys.stdin).get('tunnels',[]); print(next((x['public_url'] for x in t if x['public_url'].startswith('https')), ''))")
PIN=$(grep '^RONDA_PIN=' secrets/.env | cut -d= -f2)
if [ -z "$URL" ]; then echo "Tunnel not up: see data/ngrok.log"; exit 1; fi
echo ""
echo "  Phones as cameras:   $URL/camera"
echo "  Console from away:   $URL"
echo "  PIN:                 $PIN"
echo "  Or scan the QR code: console on the Mac, Cameras → Phones."
echo "  Stop the tunnel:     pkill -f 'ngrok http'"
echo ""
