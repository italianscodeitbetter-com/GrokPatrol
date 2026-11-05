import '../data/models.dart';

// I link degli alert su Telegram: il bottone apre una pagina https del backend, che rimanda a
// grokpatrol://open/mission/<id> oppure grokpatrol://open/event/<id>.
// Flutter toglie schema e host e passa al Navigator solo il percorso (/mission/<id>): qui si accettano tutti e due,
// così la stessa funzione serve per il link intero e per la rotta. Solo Dart: si prova senza telefono (test/deep_link_test.dart).

const deepLinkScheme = 'grokpatrol';
const deepLinkHost = 'open';

enum DeepLinkKind { mission, event }

class DeepLink {
  const DeepLink(this.kind, this.id);

  final DeepLinkKind kind;

  /// L'id del server, così com'è (m-348f5, ev-1f3da).
  final String id;

  /// La rotta del Navigator, la stessa che arriva dal sistema.
  String get route => '/${kind.name}/$id';

  @override
  bool operator ==(Object other) => other is DeepLink && other.kind == kind && other.id == id;

  @override
  int get hashCode => Object.hash(kind, id);

  @override
  String toString() => 'DeepLink(${kind.name}, $id)';
}

final _idPattern = RegExp(r'^[A-Za-z0-9][A-Za-z0-9._:-]{0,79}$');

/// Da `grokpatrol://open/mission/m-348f5`, o dalla rotta `/mission/m-348f5`, al link. null se non è uno dei nostri.
DeepLink? parseDeepLink(String link) {
  final uri = Uri.tryParse(link.trim());
  if (uri == null) return null;
  if (uri.hasScheme) {
    if (uri.scheme != deepLinkScheme || uri.host != deepLinkHost) return null;
  } else if (uri.hasAuthority) {
    return null;
  }
  final parts = uri.pathSegments.where((s) => s.isNotEmpty).toList();
  if (parts.length != 2) return null;
  final kind = switch (parts[0].toLowerCase()) {
    'mission' || 'missions' => DeepLinkKind.mission,
    'event' || 'events' => DeepLinkKind.event,
    _ => null,
  };
  final id = parts[1];
  if (kind == null || !_idPattern.hasMatch(id)) return null;
  return DeepLink(kind, id);
}

/// La missione a cui porta il link: per un evento, quella partita da lui. null se non c'è (ancora).
Mission? missionForLink(DeepLink link, Iterable<Mission> missions) => switch (link.kind) {
  DeepLinkKind.mission => missions.where((m) => m.id == link.id).firstOrNull,
  DeepLinkKind.event => missions.where((m) => m.eventId == link.id).firstOrNull,
};
