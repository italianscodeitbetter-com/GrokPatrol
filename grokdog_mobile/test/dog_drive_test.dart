import 'package:fake_async/fake_async.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:grokpatrol/data/dog_drive.dart';

void main() {
  group('velocità', () {
    test('un tasto', () {
      expect(driveVector({Move.avanti}), (vx: 0.4, vy: 0.0, wz: 0.0));
      expect(driveVector({Move.indietro}), (vx: -0.25, vy: 0.0, wz: 0.0));
      expect(driveVector({Move.sinistra}).vy, greaterThan(0), reason: 'sul server la y è a sinistra');
      expect(driveVector({Move.ruotaSx}).wz, greaterThan(0), reason: 'antiorario');
      expect(driveVector({Move.ruotaDx}).wz, lessThan(0));
    });

    test('due tasti si sommano, opposti si annullano', () {
      expect(driveVector({Move.avanti, Move.ruotaSx}), (vx: 0.4, vy: 0.0, wz: 0.8));
      expect(driveVector({Move.sinistra, Move.destra}).vy, 0);
    });

    test('stop e nessun tasto non muovono nulla', () {
      expect(driveVector({Move.stop}), (vx: 0.0, vy: 0.0, wz: 0.0));
      expect(driveVector(const {}), (vx: 0.0, vy: 0.0, wz: 0.0));
    });
  });

  group('DogDriver', () {
    test('ripete il comando finché il tasto è premuto, entro il tempo morto del server', () {
      fakeAsync((t) {
        final sent = <DriveVector>[];
        final d = DogDriver(sent.add)..hold({Move.avanti});
        expect(sent.length, 1, reason: 'parte subito');
        t.elapse(const Duration(milliseconds: 550));
        expect(sent.length, greaterThanOrEqualTo(6));
        d.release();
      });
    });

    test('rilasciato non manda più nulla: il server ferma il cane in 0,6 s', () {
      fakeAsync((t) {
        final sent = <DriveVector>[];
        final d = DogDriver(sent.add)..hold({Move.avanti});
        d.release();
        final n = sent.length;
        t.elapse(const Duration(seconds: 2));
        expect(sent.length, n);
        expect(d.driving, isFalse);
      });
    });

    test('cambiare tasto cambia comando, senza timer doppi', () {
      fakeAsync((t) {
        final sent = <DriveVector>[];
        final d = DogDriver(sent.add)
          ..hold({Move.avanti})
          ..hold({Move.ruotaSx});
        sent.clear();
        t.elapse(const Duration(milliseconds: 300));
        expect(sent.length, 3);
        expect(sent.every((v) => v.vx == 0 && v.wz == 0.8), isTrue);
        d.release();
      });
    });

    test('una combinazione che si annulla non tiene il cane in moto', () {
      fakeAsync((t) {
        final sent = <DriveVector>[];
        final d = DogDriver(sent.add)..hold({Move.sinistra, Move.destra});
        t.elapse(const Duration(seconds: 1));
        expect(sent, isEmpty);
        expect(d.driving, isFalse);
      });
    });
  });
}
