import 'dart:typed_data';

/// Taglia un flusso MJPEG nei singoli JPEG. I byte arrivano a pezzi qualsiasi: un fotogramma può stare
/// in più pezzi e un pezzo può contenerne più di uno.
class MjpegParser {
  static const _limit = 16 * 1024 * 1024; // oltre c'è qualcosa che non va: si riparte da zero

  var _buffer = Uint8List(0);
  int _start = -1; // dove inizia il JPEG in corso
  int _scan = 0; // fin qui è già stato controllato

  List<Uint8List> add(List<int> chunk) {
    final joined = Uint8List(_buffer.length + chunk.length)
      ..setAll(0, _buffer)
      ..setAll(_buffer.length, chunk);
    _buffer = joined;
    final frames = <Uint8List>[];
    var consumed = 0;
    for (var i = _scan; i + 1 < joined.length; i++) {
      if (joined[i] != 0xFF) continue;
      final next = joined[i + 1];
      if (_start < 0 && next == 0xD8) {
        _start = i;
      } else if (_start >= 0 && next == 0xD9) {
        frames.add(Uint8List.sublistView(joined, _start, i + 2));
        _start = -1;
        consumed = i + 2;
      }
    }
    // si tiene solo il JPEG in corso, o l'ultimo byte (può essere la metà di un marcatore)
    final keepFrom = _start >= 0 ? _start : (joined.length - 1).clamp(consumed, joined.length);
    _scan = joined.length > keepFrom ? joined.length - 1 - keepFrom : 0;
    _buffer = Uint8List.fromList(Uint8List.sublistView(joined, keepFrom));
    if (_start >= 0) _start = 0;
    if (_buffer.length > _limit) {
      _buffer = Uint8List(0);
      _start = -1;
      _scan = 0;
    }
    return frames;
  }
}
