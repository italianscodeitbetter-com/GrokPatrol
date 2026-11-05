import 'dart:async';

enum Move {
  avanti('Forward'),
  indietro('Back'),
  sinistra('Left'),
  destra('Right'),
  ruotaSx('Turn left'),
  ruotaDx('Turn right'),
  stop('Stop');

  const Move(this.label);
  final String label;

  /// Il nome che usa la scena 3D (uguale a DogView.tsx).
  String get wire => switch (this) {
    Move.ruotaSx => 'ruota-sx',
    Move.ruotaDx => 'ruota-dx',
    _ => name,
  };
}

typedef DriveVector = ({double vx, double vy, double wz});

/// Velocità per i tasti tenuti premuti: m/s e rad/s, gli stessi valori dei tasti della console.
/// Il server le limita comunque ai suoi massimi (VMAX, WMAX).
DriveVector driveVector(Set<Move> held) {
  var vx = 0.0, vy = 0.0, wz = 0.0;
  if (held.contains(Move.avanti)) vx += 0.4;
  if (held.contains(Move.indietro)) vx -= 0.25;
  if (held.contains(Move.sinistra)) vy += 0.25;
  if (held.contains(Move.destra)) vy -= 0.25;
  if (held.contains(Move.ruotaSx)) wz += 0.8;
  if (held.contains(Move.ruotaDx)) wz -= 0.8;
  return (vx: vx, vy: vy, wz: wz);
}

/// Ripete il comando di guida finché un tasto è premuto. Il server tiene buono ogni comando per 0,6 s
/// e poi il cane si ferma da solo: se il telefono perde la rete o l'app si chiude, il cane non resta in moto.
class DogDriver {
  DogDriver(this._send, {this.every = const Duration(milliseconds: 100)});

  final void Function(DriveVector) _send;
  final Duration every;
  Timer? _timer;

  bool get driving => _timer != null;

  void hold(Set<Move> moves) {
    _timer?.cancel();
    _timer = null;
    final v = driveVector(moves);
    if (v.vx == 0 && v.vy == 0 && v.wz == 0) return;
    _send(v);
    _timer = Timer.periodic(every, (_) => _send(v));
  }

  void release() {
    _timer?.cancel();
    _timer = null;
  }
}
