import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:grokpatrol/data/ronda/mjpeg.dart';

/// Un JPEG finto: basta che inizi e finisca con i suoi marcatori.
List<int> jpeg(int n) => [0xFF, 0xD8, n, n, 0xFF, 0x00, n, 0xFF, 0xD9];

List<int> part(int n) => [...'--frame\r\nContent-Type: image/jpeg\r\n\r\n'.codeUnits, ...jpeg(n), 13, 10];

void main() {
  test('un fotogramma intero', () {
    final frames = MjpegParser().add(part(1));
    expect(frames.single, jpeg(1));
  });

  test('più fotogrammi nello stesso pezzo', () {
    final frames = MjpegParser().add([...part(1), ...part(2), ...part(3)]);
    expect(frames, [jpeg(1), jpeg(2), jpeg(3)]);
  });

  test('qualsiasi taglio dei byte dà gli stessi fotogrammi', () {
    final all = [...part(1), ...part(2), ...part(3)];
    for (var size = 1; size < all.length; size++) {
      final parser = MjpegParser();
      final frames = <Uint8List>[];
      for (var i = 0; i < all.length; i += size) {
        frames.addAll(parser.add(all.sublist(i, (i + size).clamp(0, all.length))));
      }
      expect(frames, [jpeg(1), jpeg(2), jpeg(3)], reason: 'pezzi da $size byte');
    }
  });

  test('i dati fra un fotogramma e l\'altro si ignorano', () {
    expect(MjpegParser().add([1, 2, 3, 0xFF, 4, ...jpeg(5), 9, 9]), [jpeg(5)]);
  });

  test('un fotogramma finisce anche se il primo pezzo è già stato consumato', () {
    final parser = MjpegParser();
    expect(parser.add([0xFF, 0xD8, 1]), isEmpty);
    expect(parser.add([2, 3]), isEmpty);
    expect(parser.add([0xFF]), isEmpty);
    expect(parser.add([0xD9]).single, [0xFF, 0xD8, 1, 2, 3, 0xFF, 0xD9]);
  });
}
