Scripts that run on the Go1's head Jetson Nano (unitree@192.168.123.13), from the team's go1_kit.
`avvia_camera_nano.sh` stops Unitree's `camerarosnode` (it holds the cameras) and starts `stream_nano.py`,
an MJPEG server on port 8080. Ronda copies them and starts them from the console (Cameras → Start dog
camera). Until the dog reboots, the front camera no longer feeds Unitree's obstacle detection.
