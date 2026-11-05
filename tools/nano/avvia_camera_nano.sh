#!/bin/bash
# Da eseguire SULLA NANO DELLA TESTA: libera le camere e avvia lo stream.
pkill -f camerarosnode
sleep 2
if pgrep -f camerarosnode >/dev/null; then
  echo "camerarosnode e' ancora attivo, riprovo con kill -9"; pkill -9 -f camerarosnode; sleep 1
fi
python3 ~/stream_nano.py "${1:-0}" ${2}
