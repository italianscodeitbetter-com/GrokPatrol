#!/bin/bash
# Admin backend. DOG=sim (default, no 3D), DOG=mujoco (physics: then run ./sim.sh too) or DOG=go1 ./admin/run.sh
# The console is the Next app in admin/web (npm run dev -> http://localhost:3000).
cd "$(dirname "$0")/backend" || exit 1
if [ ! -x .venv/bin/python ]; then
  uv venv --python 3.12 .venv && uv pip install --python .venv/bin/python -r requirements.txt || exit 1
fi
mkdir -p certs data
IPS=$(ifconfig | awk '/inet /{print $2}' | grep -v '^127\.')
need=0
[ -f certs/cert.pem ] || need=1
for ip in $IPS; do
  openssl x509 -in certs/cert.pem -noout -text 2>/dev/null | grep -q "IP Address:$ip" || need=1
done
if [ $need = 1 ]; then
  SAN="DNS:localhost,IP:127.0.0.1"
  for ip in $IPS; do SAN="$SAN,IP:$ip"; done
  openssl req -x509 -newkey rsa:2048 -nodes -days 30 -keyout certs/key.pem -out certs/cert.pem \
    -subj "/CN=Ronda" -addext "subjectAltName=$SAN" >/dev/null 2>&1
fi
echo ""
echo "  Ronda admin · dog: ${DOG:-sim}"
echo "  Backend API:             http://localhost:${PORT:-8000}"
echo "  Console (Next app):      http://localhost:3000   (cd admin/web && npm run dev)"
for ip in $IPS; do echo "  Phones as cameras:       https://$ip:${HTTPS_PORT:-8443}/camera"; done
echo ""
exec .venv/bin/python -m app.serve
