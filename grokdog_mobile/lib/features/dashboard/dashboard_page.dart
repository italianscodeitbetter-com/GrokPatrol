import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

import '../../core/nav.dart';
import '../../core/theme.dart';
import '../../data/console_store.dart';
import '../../data/dog_drive.dart';
import '../../data/models.dart';
import '../../data/ronda/ronda_link.dart';
import '../../shared/live_image.dart';
import '../../shared/ui.dart';
import '../missions/mission_detail_page.dart';
import 'controls_sheet.dart';
import 'dog_view.dart';
import 'map_view.dart';

const _stateLabel = {
  DogState.missione: (Tone.amber, 'On mission'),
  DogState.ronda: (Tone.blue, 'On patrol'),
  DogState.base: (Tone.gray, 'At base'),
  DogState.spento: (Tone.gray, 'Off'),
};

/// La planimetria 3D a tutta area: si gira con un dito, si sposta e si ingrandisce con due.
/// In alto, su una riga, ora e turno a sinistra e allarme, comandi e notifiche a destra.
/// Sotto, i bot in colonna a sinistra e la legenda a destra.
/// Quello che si legge soltanto lascia passare i tocchi: più area possibile per muovere la mappa col dito.
class DashboardPage extends StatefulWidget {
  const DashboardPage({super.key, required this.visible, required this.onImmersive});

  /// La scheda è quella mostrata: altrimenti la mappa si ferma.
  final bool visible;

  /// Vista del cane a tutto schermo: la shell nasconde le sue barre.
  final ValueChanged<bool> onImmersive;

  @override
  State<DashboardPage> createState() => _DashboardPageState();
}

class _DashboardPageState extends State<DashboardPage> with RouteAware {
  // spazio occupato dagli overlay col pannello dei bot aperto: azioni sopra, pannello sotto
  static const _topInset = 100.0;
  static const _bottomInset = 24.0;
  static const _panelHeight = 240.0;

  /// A pannello chiuso: sotto la legenda. Sotto resta del margine di proposito, la pianta è alta
  /// quanto larga e con tutto lo spazio libero uscirebbe dai lati dello schermo.
  static const _restInsets = (top: 190.0, bottom: 125.0);

  static const _portrait = [DeviceOrientation.portraitUp]; // quella di tutta l'app, vedi main.dart

  ConsoleStore get _store => ConsoleStore.instance;

  late final MapController _map = MapController(
    insets: _restInsets,
    onCamera: (id) {
      // sul telefono non c'è spazio per più riquadri: la card della telecamera prende il posto degli altri
      setState(() {
        _camera = _store.cameras.where((c) => c.id == id).firstOrNull;
        _botsOpen = false;
        _following = null;
      });
      _map.setFollowing(null);
      _syncInsets();
      _syncFrames();
    },
    onDog: _toggleFollow,
    onSpot: (id) => sendDogTo(context, id),
  );
  final _pipKey = GlobalKey();
  final _camKey = GlobalKey();
  final _mapKey = GlobalKey();

  bool _botsOpen = false;
  String? _selectedBot;
  final _query = TextEditingController();
  String? _following;
  MapPoint? _camera;
  bool _cameraFull = false;
  bool _rotatingBack = false;
  String? _openDogId;
  bool _openWithControl = false;
  bool _covered = false;

  Dog? get _openDog => _store.dogs.where((d) => d.id == _openDogId).firstOrNull;
  Dog? get _followedDog => _store.dogs.where((d) => d.id == _following).firstOrNull;

  /// Con il video vero del cane a tutto schermo la scena 3D sotto non serve.
  bool get _dogVideo => _openDogId != null && _store.dogHasVideo;

  @override
  void initState() {
    super.initState();
    _store.mapEpoch.addListener(_onNewMap);
  }

  /// Passaggio fra demo e server: la scena si ricostruisce e quello che era aperto non vale più.
  void _onNewMap() {
    if (!mounted) return;
    setState(() {
      _following = null;
      _camera = null;
      _botsOpen = false;
    });
    if (_openDogId != null) _closeLive();
    if (_cameraFull) _closeCamera();
    _syncInsets();
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final route = ModalRoute.of(context);
    if (route is PageRoute) routeObserver.subscribe(this, route);
    _syncInsets();
    final portrait = MediaQuery.orientationOf(context) == Orientation.portrait;
    if (_rotatingBack && portrait) {
      _rotatingBack = false;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) widget.onImmersive(false);
      });
    }
  }

  /// La mappa arriva fino in fondo, sotto la barra di vetro: la pianta si inquadra nello spazio che resta libero.
  void _syncInsets() {
    final bar = MediaQuery.paddingOf(context).bottom;
    _map.setInsets(
      _botsOpen ? (top: _topInset, bottom: bar + _bottomInset + _panelHeight) : (top: _restInsets.top, bottom: bar + _restInsets.bottom),
    );
  }

  @override
  void didUpdateWidget(DashboardPage old) {
    super.didUpdateWidget(old);
    if (old.visible != widget.visible) _syncActive();
  }

  @override
  void didPushNext() {
    _covered = true;
    // una pagina aperta sopra (da un allarme) non deve ritrovarsi in orizzontale
    if (_cameraFull) _closeCamera();
    _syncActive();
  }

  @override
  void didPopNext() {
    _covered = false;
    _syncActive();
  }

  // con un video vero a tutto schermo la scena 3D sotto non serve
  void _syncActive() => _map.setActive(widget.visible && !_covered && !_dogVideo && !(_cameraFull && _store.isLive));

  @override
  void dispose() {
    routeObserver.unsubscribe(this);
    _store.mapEpoch.removeListener(_onNewMap);
    if (_cameraFull) unawaited(SystemChrome.setPreferredOrientations(_portrait));
    _query.dispose();
    _map.dispose();
    super.dispose();
  }

  /// Il pannello aperto o chiuso cambia lo spazio libero: la pianta si rimette tutta lì dentro.
  void _botsChanged() {
    _syncInsets();
    _syncFrames();
    if (_following == null) _map.reset();
  }

  void _pickBot(String id) {
    setState(() {
      if (_botsOpen && _selectedBot == id) {
        _botsOpen = false;
      } else {
        _selectedBot = id;
        _botsOpen = true;
        _query.clear();
        // il pannello prende il posto dei riquadri
        _camera = null;
      }
    });
    _botsChanged();
  }

  void _closeBots() {
    setState(() => _botsOpen = false);
    _botsChanged();
  }

  void _toggleFollow(String id) {
    final panel = _botsOpen;
    setState(() {
      _following = _following == id ? null : id;
      if (_following != null) {
        _camera = null;
        _botsOpen = false;
      }
    });
    _map.setFollowing(_following);
    _syncInsets();
    _syncFrames();
    if (panel != _botsOpen && _following == null) _map.reset();
  }

  void _closeFollow() {
    setState(() => _following = null);
    _map
      ..setFollowing(null)
      ..setPov(null)
      ..reset();
  }

  /// Dopo il disegno: i riquadri sono buchi nelle card, lì sotto la scena disegna le riprese.
  void _syncFrames() => WidgetsBinding.instance.addPostFrameCallback((_) {
    if (!mounted || _openDogId != null) return;
    final host = _mapKey.currentContext?.findRenderObject() as RenderBox?;
    if (host == null) return;
    Rect? rectOf(GlobalKey key) {
      final box = key.currentContext?.findRenderObject() as RenderBox?;
      return box == null ? null : box.localToGlobal(Offset.zero, ancestor: host) & box.size;
    }

    final pip = rectOf(_pipKey);
    if (_following == null || pip == null) {
      _map.setPov(null);
    } else {
      _map.setPov(_following, rect: pip);
    }
    _map.setCamPov(_store.isLive ? null : _camera?.id, rect: rectOf(_camKey));
  });

  /// A tutto schermo il video va in orizzontale: in verticale se ne vedrebbe solo un quarto.
  void _openCamera() {
    _rotatingBack = false;
    setState(() => _cameraFull = true);
    widget.onImmersive(true);
    unawaited(SystemChrome.setPreferredOrientations(const [DeviceOrientation.landscapeLeft, DeviceOrientation.landscapeRight]));
    _syncActive();
    _syncFrames();
  }

  void _closeCamera() {
    setState(() => _cameraFull = false);
    unawaited(SystemChrome.setPreferredOrientations(_portrait));
    // le barre tornano a rotazione finita: quella nativa, se nasce in orizzontale, resta fuori posto
    if (MediaQuery.orientationOf(context) == Orientation.portrait) {
      widget.onImmersive(false);
    } else {
      _rotatingBack = true;
    }
    _syncActive();
    _syncFrames();
  }

  void _openLive(Dog dog, {bool control = false}) {
    setState(() {
      _openDogId = dog.id;
      _openWithControl = control;
    });
    widget.onImmersive(true);
    _map.setPov(dog.id, cover: true);
    _syncActive();
  }

  void _closeLive() {
    setState(() => _openDogId = null);
    widget.onImmersive(false);
    _map.setDrive(null, const {});
    _store.drive(null);
    _map.setPov(null);
    _syncActive();
    _syncFrames();
  }

  void _drive(Set<Move>? held) {
    if (_store.isLive) return _store.drive(held);
    final id = _openDogId;
    if (id != null || held == null) _map.setDrive(held == null ? null : id, held ?? const {});
  }

  @override
  Widget build(BuildContext context) => ListenableBuilder(listenable: _store, builder: (context, _) => _buildPage());

  Widget _buildPage() {
    final open = _openDog, video = _dogVideo, camera = _cameraFull ? _camera : null;
    return PopScope(
      canPop: open == null && camera == null,
      onPopInvokedWithResult: (didPop, _) {
        if (didPop) return;
        camera == null ? _closeLive() : _closeCamera();
      },
      child: Stack(
        key: _mapKey,
        fit: StackFit.expand,
        children: [
          MapView(controller: _map),
          if (video) const LiveImage(camera: 'dog', label: 'Dog camera offline'),
          if (open != null)
            DogView(
              key: ValueKey('${open.id}-$_openWithControl'),
              dog: open,
              initialControl: _openWithControl,
              onClose: _closeLive,
              onDrive: _drive,
            )
          else if (camera != null)
            _CameraFullView(camera: camera, frameKey: _camKey, onMoved: _syncFrames, onClose: _closeCamera)
          else
            ..._overlay(),
        ],
      ),
    );
  }

  List<Widget> _overlay() {
    final followed = _followedDog, bottom = MediaQuery.paddingOf(context).bottom;
    // la legenda lascia il posto a quello che si apre in basso
    final legend = !_botsOpen && _camera == null && followed == null;
    return [
      Positioned(
        left: 12,
        right: 12,
        top: 12,
        bottom: 12 + bottom + (_botsOpen ? _panelHeight : 0),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            if (_store.isLive && _store.link == LinkState.offline) ...[const _OfflineNote(), const SizedBox(height: 8)],
            Row(
              spacing: 8,
              children: [
                // sui telefoni stretti l'orologio si riduce un po' invece di perdere il testo
                const Expanded(
                  child: IgnorePointer(
                    child: FittedBox(fit: BoxFit.scaleDown, alignment: Alignment.centerLeft, child: _ShiftClock()),
                  ),
                ),
                if (_store.isLive) const _LiveActions(),
                const _NotificationsBell(),
              ],
            ),
            const SizedBox(height: 8),
            Expanded(
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  // se lo spazio non basta i bot scorrono
                  _BotsColumn(bots: _store.fleet, open: _botsOpen, selected: _selectedBot, onPick: _pickBot),
                  if (legend) const IgnorePointer(child: _Legend()),
                ],
              ),
            ),
          ],
        ),
      ),
      Positioned(
        left: 12,
        right: 12,
        bottom: 12 + bottom,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          mainAxisSize: MainAxisSize.min,
          spacing: 8,
          children: [
            if (_camera case final cam?)
              Align(
                alignment: Alignment.centerLeft,
                child: _CameraCard(
                  camera: cam,
                  frameKey: _camKey,
                  onMoved: _syncFrames,
                  onExpand: _openCamera,
                  onClose: () {
                    setState(() => _camera = null);
                    _syncFrames();
                  },
                ),
              ),
            if (followed != null)
              Align(
                alignment: Alignment.centerLeft,
                child: _FollowCard(
                  key: ValueKey(followed.id),
                  dog: followed,
                  pipKey: _pipKey,
                  onMoved: _syncFrames,
                  onOpen: () => _openLive(followed),
                  onControl: () => _openLive(followed, control: true),
                  onClose: _closeFollow,
                ),
              ),
            if (_botsOpen)
              _BotsPanel(
                bots: _store.fleet,
                query: _query,
                selected: _selectedBot,
                following: _following,
                onClose: _closeBots,
                onFollow: _toggleFollow,
                onLive: _openLive,
                onChanged: () => setState(() {}),
              ),
          ],
        ),
      ),
    ];
  }
}

/// Il server non risponde: l'operatore deve saperlo subito, i comandi non arrivano.
class _OfflineNote extends StatelessWidget {
  const _OfflineNote();

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
      decoration: BoxDecoration(
        color: const Color(0xFF3A1A1C),
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: AppColors.red400.withValues(alpha: 0.3)),
      ),
      child: const Text(
        "Can't reach the server, retrying. Commands won't reach the dog.",
        textAlign: TextAlign.center,
        style: TextStyle(fontSize: 13, color: AppColors.red400),
      ),
    );
  }
}

/// Allarme e comandi, accanto alle notifiche: ci sono solo collegati al server.
class _LiveActions extends StatelessWidget {
  const _LiveActions();

  // ascolta da sé: un widget const non si ridisegna con il padre, e qui c'è lo stato dell'allarme
  @override
  Widget build(BuildContext context) => ListenableBuilder(listenable: ConsoleStore.instance, builder: (context, _) => _row(context));

  Widget _row(BuildContext context) {
    final store = ConsoleStore.instance;
    final a = store.alarm;
    final armed = a?.armed == true;
    final (label, color) = a?.active == true
        ? ('Armed', AppColors.red400)
        : armed
        ? ('Arming ${a?.exitDelay} s', AppColors.amber300)
        : ('Alarm off', AppColors.muted);
    return Row(
      mainAxisSize: MainAxisSize.min,
      spacing: 8,
      children: [
        _RoundAction(
          icon: armed ? LucideIcons.shieldCheck : LucideIcons.shieldOff,
          label: label,
          color: color,
          // senza testo l'allarme acceso deve vedersi lo stesso
          border: armed ? color.withValues(alpha: 0.6) : AppColors.line,
          onTap: () => runCommand(() => store.command(armed ? 'disarm' : 'arm', {'by': 'mobile'})),
        ),
        _RoundAction(icon: LucideIcons.slidersHorizontal, label: 'Controls', onTap: () => showControls(context)),
      ],
    );
  }
}

/// Azione tonda con la sola icona, per lasciare libera la mappa: il nome compare tenendola premuta.
class _RoundAction extends StatelessWidget {
  const _RoundAction({
    required this.icon,
    required this.label,
    required this.onTap,
    this.color = AppColors.ink,
    this.border = AppColors.line,
  });

  final IconData icon;
  final String label;
  final VoidCallback onTap;
  final Color color, border;

  @override
  Widget build(BuildContext context) {
    return Tooltip(
      message: label,
      excludeFromSemantics: true,
      child: Material(
        color: AppColors.app.withValues(alpha: 0.96),
        shape: CircleBorder(side: BorderSide(color: border)),
        clipBehavior: Clip.antiAlias,
        child: InkWell(
          onTap: onTap,
          child: SizedBox.square(
            dimension: 40,
            child: Icon(icon, size: 18, color: color, semanticLabel: label),
          ),
        ),
      ),
    );
  }
}

/// I bot come icone tonde, uno sotto l'altro. Tocco → si apre il pannello su quel bot.
class _BotsColumn extends StatelessWidget {
  const _BotsColumn({required this.bots, required this.open, required this.selected, required this.onPick});

  final List<Dog> bots;
  final bool open;
  final String? selected;
  final ValueChanged<String> onPick;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(4),
      decoration: BoxDecoration(
        color: AppColors.app.withValues(alpha: 0.96),
        borderRadius: BorderRadius.circular(99),
        border: Border.all(color: AppColors.line),
      ),
      child: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          spacing: 6,
          children: [for (final d in bots) _BotIcon(dog: d, active: open && selected == d.id, onTap: () => onPick(d.id))],
        ),
      ),
    );
  }
}

class _BotIcon extends StatelessWidget {
  const _BotIcon({required this.dog, required this.active, required this.onTap});

  final Dog dog;
  final bool active;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final off = dog.state == DogState.spento;
    return Semantics(
      button: true,
      selected: active,
      label: '${dog.name}${off ? ', off' : ''}',
      excludeSemantics: true,
      child: GestureDetector(
        onTap: onTap,
        child: SizedBox.square(
          dimension: 36,
          child: Stack(
            clipBehavior: Clip.none,
            children: [
              Container(
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  border: Border.all(color: active ? AppColors.accent : Colors.transparent, width: 2),
                ),
                child: Center(child: RobotAvatar(off: off, size: 32)),
              ),
              Positioned(
                right: -1,
                bottom: -1,
                child: Container(
                  width: 12,
                  height: 12,
                  decoration: BoxDecoration(
                    color: off ? AppColors.faint : batteryColor(dog.battery ?? 100),
                    shape: BoxShape.circle,
                    border: Border.all(color: AppColors.app, width: 2),
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// Le card dei bot, con la ricerca: scorrono in orizzontale per lasciare libera la mappa.
class _BotsPanel extends StatelessWidget {
  const _BotsPanel({
    required this.bots,
    required this.query,
    required this.selected,
    required this.following,
    required this.onClose,
    required this.onFollow,
    required this.onLive,
    required this.onChanged,
  });

  final List<Dog> bots;
  final TextEditingController query;
  final String? selected, following;
  final VoidCallback onClose, onChanged;
  final ValueChanged<String> onFollow;
  final void Function(Dog dog, {bool control}) onLive;

  @override
  Widget build(BuildContext context) {
    final q = query.text.trim().toLowerCase();
    final listed = q.isEmpty ? bots : bots.where((d) => '${d.name} ${d.task}'.toLowerCase().contains(q)).toList();
    // il bot scelto per primo: è quello appena toccato
    final ordered = [...listed.where((d) => d.id == selected), ...listed.where((d) => d.id != selected)];
    final width = MediaQuery.sizeOf(context).width - 24;
    return Container(
      padding: const EdgeInsets.all(8),
      decoration: BoxDecoration(
        color: AppColors.app.withValues(alpha: 0.9),
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: AppColors.line),
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              Expanded(
                child: SizedBox(
                  height: 36,
                  child: TextField(
                    controller: query,
                    style: AppText.body,
                    onChanged: (_) => onChanged(),
                    decoration: const InputDecoration(
                      hintText: 'Search bots',
                      contentPadding: EdgeInsets.symmetric(vertical: 8),
                      prefixIcon: Icon(LucideIcons.search, size: 16, color: AppColors.muted),
                      prefixIconConstraints: BoxConstraints(minWidth: 34),
                    ),
                  ),
                ),
              ),
              const SizedBox(width: 8),
              Text('${listed.length}', style: AppText.codeFaint),
              IconButton(
                onPressed: onClose,
                tooltip: 'Close bots',
                visualDensity: VisualDensity.compact,
                icon: const Icon(LucideIcons.x, size: 16, color: AppColors.muted),
              ),
            ],
          ),
          const SizedBox(height: 8),
          SizedBox(
            height: 164,
            child: ordered.isEmpty
                ? Center(child: Text('No bots match “${query.text.trim()}”.', style: AppText.bodyMuted))
                : ListView.separated(
                    key: ValueKey(selected),
                    scrollDirection: Axis.horizontal,
                    itemCount: ordered.length,
                    separatorBuilder: (_, _) => const SizedBox(width: 8),
                    itemBuilder: (_, i) {
                      final d = ordered[i];
                      return SizedBox(
                        width: ordered.length == 1 ? width - 18 : width - 46,
                        child: _DogCard(
                          dog: d,
                          selected: selected == d.id,
                          followed: following == d.id,
                          onFollow: () => onFollow(d.id),
                          onLive: () => onLive(d),
                        ),
                      );
                    },
                  ),
          ),
        ],
      ),
    );
  }
}

class _ShiftClock extends StatefulWidget {
  const _ShiftClock();

  @override
  State<_ShiftClock> createState() => _ShiftClockState();
}

class _ShiftClockState extends State<_ShiftClock> {
  late final Timer _timer;

  @override
  void initState() {
    super.initState();
    _timer = Timer.periodic(const Duration(seconds: 1), (_) => setState(() {}));
  }

  @override
  void dispose() {
    _timer.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final n = DateTime.now();
    String two(int v) => v.toString().padLeft(2, '0');
    Widget sep() => Container(width: 1, height: 14, margin: const EdgeInsets.symmetric(horizontal: 8), color: AppColors.line);
    return Container(
      height: 32,
      padding: const EdgeInsets.symmetric(horizontal: 10),
      decoration: BoxDecoration(
        color: AppColors.app.withValues(alpha: 0.96),
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: AppColors.line),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Text('${two(n.hour)}:${two(n.minute)}:${two(n.second)}', style: AppText.code),
          for (final part in ConsoleStore.instance.shiftParts) ...[
            sep(),
            Flexible(
              child: Text(
                part,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(fontSize: 12, color: AppColors.muted),
              ),
            ),
          ],
        ],
      ),
    );
  }
}

/// Cosa si vede sulla mappa e, staccati, gli eventi: gli stessi colori e la stessa icona della scena.
/// Senza card, sulla mappa: l'ombra tiene leggibile il testo quando passa sopra i muri.
class _Legend extends StatelessWidget {
  const _Legend();

  Widget _item(Widget mark, String label) => Row(
    mainAxisSize: MainAxisSize.min,
    children: [
      SizedBox.square(dimension: 14, child: Center(child: mark)),
      const SizedBox(width: 6),
      Text(
        label,
        style: const TextStyle(
          fontSize: 12,
          height: 1.6,
          color: AppColors.muted,
          shadows: [Shadow(color: AppColors.app, blurRadius: 4)],
        ),
      ),
    ],
  );

  @override
  Widget build(BuildContext context) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _item(
          Container(
            width: 8,
            height: 8,
            decoration: BoxDecoration(
              color: AppColors.accent,
              shape: BoxShape.circle,
              boxShadow: [BoxShadow(color: AppColors.accent.withValues(alpha: 0.5), blurRadius: 6)],
            ),
          ),
          'Dog',
        ),
        _item(
          Container(
            width: 9,
            height: 9,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              border: Border.all(color: AppColors.accent, width: 1.5),
            ),
          ),
          'Patrol point',
        ),
        _item(const Icon(LucideIcons.video, size: 13, color: AppColors.muted), 'Camera'),
        const SizedBox(height: 6),
        _item(const Icon(LucideIcons.mapPin, size: 13, color: AppColors.red400), 'High priority'),
        _item(const Icon(LucideIcons.mapPin, size: 13, color: AppColors.amber300), 'Medium / low'),
      ],
    );
  }
}

class _DogCard extends StatelessWidget {
  const _DogCard({required this.dog, required this.selected, required this.followed, required this.onFollow, required this.onLive});

  final Dog dog;
  final bool selected, followed;
  final VoidCallback onFollow, onLive;

  @override
  Widget build(BuildContext context) {
    final (tone, label) = _stateLabel[dog.state]!;
    // spento: card in grigio, niente Follow né Live view
    final off = dog.state == DogState.spento;
    return Container(
      clipBehavior: Clip.antiAlias,
      decoration: BoxDecoration(
        color: AppColors.app.withValues(alpha: 0.92),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: selected ? AppColors.accent.withValues(alpha: 0.6) : AppColors.line),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          SizedBox(
            width: 84,
            child: Stack(
              fit: StackFit.expand,
              children: [
                const DecoratedBox(
                  decoration: BoxDecoration(
                    gradient: RadialGradient(center: Alignment(-0.2, -0.1), radius: 1, colors: [AppColors.line, Color(0xFF141414)]),
                  ),
                ),
                Opacity(
                  opacity: off ? 0.4 : 1,
                  child: Image.asset(
                    'assets/images/robot-dog.png',
                    fit: BoxFit.cover,
                    alignment: const Alignment(-0.2, -0.1),
                    cacheWidth: 300,
                  ),
                ),
                const DecoratedBox(
                  decoration: BoxDecoration(
                    gradient: LinearGradient(
                      begin: Alignment.centerRight,
                      end: Alignment(0.2, 0),
                      colors: [AppColors.app, Color(0x00121212)],
                    ),
                  ),
                ),
              ],
            ),
          ),
          Expanded(
            child: Padding(
              padding: const EdgeInsets.fromLTRB(4, 10, 10, 10),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Container(
                        width: 8,
                        height: 8,
                        decoration: BoxDecoration(color: off ? AppColors.faint : AppColors.ok, shape: BoxShape.circle),
                      ),
                      const SizedBox(width: 8),
                      Expanded(
                        child: Text(dog.name, maxLines: 1, overflow: TextOverflow.ellipsis, style: off ? AppText.bodyMuted : AppText.body),
                      ),
                    ],
                  ),
                  const SizedBox(height: 2),
                  Text(dog.task, maxLines: 1, overflow: TextOverflow.ellipsis, style: AppText.bodyMuted),
                  const Spacer(),
                  Row(
                    children: [
                      Flexible(
                        child: ToneBadge(tone: tone, label: label),
                      ),
                      const Spacer(),
                      BatteryTag(battery: dog.battery, off: off),
                    ],
                  ),
                  const SizedBox(height: 8),
                  Row(
                    children: [
                      Expanded(
                        child: _CardButton(
                          label: followed ? 'Following' : 'Follow',
                          icon: LucideIcons.footprints,
                          selected: followed,
                          onTap: off ? null : onFollow,
                        ),
                      ),
                      const SizedBox(width: 6),
                      Expanded(
                        child: _CardButton(label: 'Live view', icon: LucideIcons.video, onTap: off ? null : onLive),
                      ),
                    ],
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _CardButton extends StatelessWidget {
  const _CardButton({required this.label, required this.icon, required this.onTap, this.selected = false});

  final String label;
  final IconData icon;
  final VoidCallback? onTap;
  final bool selected;

  @override
  Widget build(BuildContext context) {
    final fg = selected ? AppColors.ink : AppColors.muted;
    return Opacity(
      opacity: onTap == null ? 0.4 : 1,
      child: Material(
        color: selected ? AppColors.accent.withValues(alpha: 0.10) : Colors.transparent,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(8),
          side: BorderSide(color: selected ? AppColors.accent.withValues(alpha: 0.6) : AppColors.line),
        ),
        clipBehavior: Clip.antiAlias,
        child: InkWell(
          onTap: onTap,
          child: SizedBox(
            height: 36,
            child: Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Icon(icon, size: 15, color: fg),
                const SizedBox(width: 6),
                Flexible(
                  child: Text(
                    label,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(fontSize: 13, color: fg),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _CardHeader extends StatelessWidget {
  const _CardHeader({required this.title, required this.closeLabel, required this.onClose, this.onExpand});

  final String title;
  final String closeLabel;
  final VoidCallback onClose;
  final VoidCallback? onExpand;

  @override
  Widget build(BuildContext context) {
    return Container(
      color: AppColors.app,
      padding: const EdgeInsets.only(left: 12, right: 4),
      height: 40,
      child: Row(
        children: [
          const ToneBadge(tone: Tone.red, label: '● LIVE'),
          const SizedBox(width: 8),
          Expanded(
            child: Text(title, maxLines: 1, overflow: TextOverflow.ellipsis, style: AppText.body),
          ),
          if (onExpand != null)
            IconButton(
              onPressed: onExpand,
              tooltip: 'Full screen',
              visualDensity: VisualDensity.compact,
              icon: const Icon(LucideIcons.maximize2, size: 16, color: AppColors.muted),
            ),
          IconButton(
            onPressed: onClose,
            tooltip: closeLabel,
            visualDensity: VisualDensity.compact,
            icon: const Icon(LucideIcons.x, size: 16, color: AppColors.muted),
          ),
        ],
      ),
    );
  }
}

/// Avvisa quando la card si sposta: la scena deve sapere dov'è il buco.
mixin _MovingFrame<T extends StatefulWidget> on State<T> {
  VoidCallback get onMoved;

  @override
  void didUpdateWidget(T old) {
    super.didUpdateWidget(old);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) onMoved();
    });
  }
}

/// Mentre segui un cane: la sua telecamera di bordo. Il riquadro è trasparente, la disegna la scena sotto.
/// Sotto: apri a tutto schermo o prendi il controllo; la X in alto chiude e torna alla vista iniziale.
class _FollowCard extends StatefulWidget {
  const _FollowCard({
    super.key,
    required this.dog,
    required this.pipKey,
    required this.onMoved,
    required this.onOpen,
    required this.onControl,
    required this.onClose,
  });

  final Dog dog;
  final GlobalKey pipKey;
  final VoidCallback onMoved, onOpen, onControl, onClose;

  @override
  State<_FollowCard> createState() => _FollowCardState();
}

class _FollowCardState extends State<_FollowCard> with _MovingFrame {
  @override
  VoidCallback get onMoved => widget.onMoved;

  @override
  Widget build(BuildContext context) {
    final w = (MediaQuery.sizeOf(context).width - 24).clamp(0.0, 300.0);
    return ClipRRect(
      borderRadius: BorderRadius.circular(12),
      child: Container(
        width: w,
        decoration: BoxDecoration(
          border: Border.all(color: AppColors.accent.withValues(alpha: 0.6)),
          borderRadius: BorderRadius.circular(12),
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            _CardHeader(title: '${widget.dog.name} view', closeLabel: 'Close view', onClose: widget.onClose),
            SizedBox(key: widget.pipKey, height: (w - 2) * 9 / 16),
            Container(
              color: AppColors.app,
              padding: const EdgeInsets.all(8),
              child: Row(
                children: [
                  Expanded(
                    child: GhostButton(
                      label: 'Open',
                      icon: LucideIcons.maximize2,
                      height: 34,
                      color: AppColors.muted,
                      onPressed: widget.onOpen,
                    ),
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: PrimaryButton(label: 'Take control', height: 34, onPressed: widget.onControl),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// Una telecamera fissa: dal vivo il suo video, nella demo la ripresa simulata nella scena 3D.
class _CameraCard extends StatefulWidget {
  const _CameraCard({required this.camera, required this.frameKey, required this.onMoved, required this.onExpand, required this.onClose});

  final MapPoint camera;
  final GlobalKey frameKey;
  final VoidCallback onMoved, onExpand, onClose;

  @override
  State<_CameraCard> createState() => _CameraCardState();
}

class _CameraCardState extends State<_CameraCard> with _MovingFrame {
  @override
  VoidCallback get onMoved => widget.onMoved;

  @override
  Widget build(BuildContext context) {
    final store = ConsoleStore.instance, cam = widget.camera;
    final w = (MediaQuery.sizeOf(context).width - 24).clamp(0.0, 300.0);
    return ClipRRect(
      borderRadius: BorderRadius.circular(12),
      child: Container(
        width: w,
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(12),
          border: Border.all(color: AppColors.line),
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            _CardHeader(
              title: '${cam.id} · ${store.roomName(cam.roomId)}',
              closeLabel: 'Close camera view',
              onClose: widget.onClose,
              onExpand: widget.onExpand,
            ),
            SizedBox(
              key: widget.frameKey,
              height: (w - 2) * 9 / 16,
              child: store.isLive
                  ? LiveImage(camera: cam.id, label: 'Camera ${cam.id} offline')
                  : Align(
                      alignment: Alignment.topLeft,
                      child: Container(
                        margin: const EdgeInsets.all(8),
                        padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                        decoration: BoxDecoration(color: AppColors.app.withValues(alpha: 0.6), borderRadius: BorderRadius.circular(4)),
                        child: Text(cam.id, style: AppText.code),
                      ),
                    ),
            ),
          ],
        ),
      ),
    );
  }
}

/// La telecamera a tutto schermo: dal vivo il suo video, nella demo un buco sopra la ripresa disegnata dalla scena.
class _CameraFullView extends StatefulWidget {
  const _CameraFullView({required this.camera, required this.frameKey, required this.onMoved, required this.onClose});

  final MapPoint camera;
  final GlobalKey frameKey;
  final VoidCallback onMoved, onClose;

  @override
  State<_CameraFullView> createState() => _CameraFullViewState();
}

class _CameraFullViewState extends State<_CameraFullView> with _MovingFrame {
  @override
  VoidCallback get onMoved => widget.onMoved;

  @override
  Widget build(BuildContext context) {
    final store = ConsoleStore.instance, cam = widget.camera;
    return Semantics(
      scopesRoute: true,
      explicitChildNodes: true,
      label: '${cam.id} full screen',
      child: Stack(
        fit: StackFit.expand,
        children: [
          SizedBox.expand(
            key: widget.frameKey,
            // intero, non ritagliato: ai bordi dell'inquadratura può esserci quello che serve vedere.
            // Nella demo il fondo trasparente ferma i tocchi: sotto c'è la mappa
            child: store.isLive
                ? ColoredBox(
                    color: Colors.black,
                    child: LiveImage(camera: cam.id, label: 'Camera ${cam.id} offline', fit: BoxFit.contain),
                  )
                : const ColoredBox(color: Colors.transparent),
          ),
          Align(
            alignment: Alignment.topCenter,
            child: DecoratedBox(
              decoration: const BoxDecoration(
                // anche su un video chiaro i testi si devono leggere
                gradient: LinearGradient(
                  begin: Alignment.topCenter,
                  end: Alignment.bottomCenter,
                  colors: [Color(0xB3000000), Color(0x00000000)],
                ),
              ),
              child: SafeArea(
                bottom: false,
                child: Padding(
                  padding: const EdgeInsets.fromLTRB(16, 12, 12, 24),
                  child: Row(
                    children: [
                      const ToneBadge(tone: Tone.red, label: '● LIVE'),
                      const SizedBox(width: 8),
                      Expanded(
                        child: Text(
                          '${cam.id} · ${store.roomName(cam.roomId)}',
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: AppText.body,
                        ),
                      ),
                      Material(
                        color: Colors.black.withValues(alpha: 0.5),
                        borderRadius: BorderRadius.circular(8),
                        clipBehavior: Clip.antiAlias,
                        child: IconButton(
                          onPressed: widget.onClose,
                          tooltip: 'Close full screen',
                          constraints: const BoxConstraints.tightFor(width: 40, height: 40),
                          padding: EdgeInsets.zero,
                          icon: const Icon(LucideIcons.minimize2, size: 18, color: AppColors.ink),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

// le attività più recenti prima; nei dati finti «nuove» = quelle dopo le 11:00 finché non apri il pannello
List<LogRow> _activity() {
  final rows = ConsoleStore.instance.activity;
  return ConsoleStore.instance.isLive ? rows : ([...rows]..sort((a, b) => b.time.compareTo(a.time)));
}

const _unreadFrom = '11:00:00';

class _NotificationsBell extends StatefulWidget {
  const _NotificationsBell();

  @override
  State<_NotificationsBell> createState() => _NotificationsBellState();
}

class _NotificationsBellState extends State<_NotificationsBell> {
  bool _seen = false;

  @override
  void initState() {
    super.initState();
    showActivityPanel.addListener(_openFromLink);
  }

  @override
  void dispose() {
    showActivityPanel.removeListener(_openFromLink);
    super.dispose();
  }

  /// Un link da Telegram per un evento senza missione apre le notifiche.
  void _openFromLink() {
    if (mounted) _open();
  }

  int get _unread {
    final store = ConsoleStore.instance;
    if (store.isLive) return store.unread;
    return _seen ? 0 : _activity().where((a) => a.time.compareTo(_unreadFrom) >= 0).length;
  }

  void _open() {
    setState(() => _seen = true);
    ConsoleStore.instance.markActivityRead();
    showModalBottomSheet<void>(context: context, useRootNavigator: true, isScrollControlled: true, builder: (_) => const _ActivitySheet());
  }

  @override
  Widget build(BuildContext context) => ListenableBuilder(listenable: ConsoleStore.instance, builder: (context, _) => _bell());

  Widget _bell() {
    final unread = _unread;
    return Stack(
      clipBehavior: Clip.none,
      children: [
        _RoundAction(icon: LucideIcons.bell, label: unread > 0 ? 'Activity, $unread new' : 'Activity', onTap: _open),
        if (unread > 0)
          Positioned(
            right: -4,
            top: -4,
            child: IgnorePointer(
              child: Container(
                constraints: const BoxConstraints(minWidth: 20),
                height: 20,
                padding: const EdgeInsets.symmetric(horizontal: 4),
                alignment: Alignment.center,
                decoration: BoxDecoration(color: AppColors.red500, borderRadius: BorderRadius.circular(10)),
                child: Text(
                  '$unread',
                  style: const TextStyle(fontFamily: AppText.mono, fontSize: 12, fontWeight: FontWeight.w500, color: Colors.white),
                ),
              ),
            ),
          ),
      ],
    );
  }
}

class _ActivitySheet extends StatelessWidget {
  const _ActivitySheet();

  @override
  Widget build(BuildContext context) {
    return SafeArea(
      child: ConstrainedBox(
        constraints: BoxConstraints(maxHeight: MediaQuery.sizeOf(context).height * 0.75),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Container(
              padding: const EdgeInsets.fromLTRB(16, 0, 8, 4),
              decoration: const BoxDecoration(
                border: Border(bottom: BorderSide(color: AppColors.line)),
              ),
              child: Row(
                children: [
                  const Expanded(child: Text('Activity', style: AppText.medium)),
                  TextButton(
                    onPressed: () {
                      Navigator.of(context, rootNavigator: true).pop();
                      showReportsActivity.value++;
                    },
                    child: const Text('View all', style: TextStyle(fontSize: 14, color: AppColors.muted)),
                  ),
                ],
              ),
            ),
            Flexible(
              child: ListenableBuilder(
                listenable: ConsoleStore.instance,
                builder: (context, _) {
                  final rows = _activity();
                  if (rows.isEmpty) {
                    return const Padding(
                      padding: EdgeInsets.all(24),
                      child: Text('Nothing yet in this shift.', textAlign: TextAlign.center, style: AppText.bodyMuted),
                    );
                  }
                  return ListView.separated(
                    shrinkWrap: true,
                    itemCount: rows.length,
                    separatorBuilder: (_, _) => const Divider(height: 1, color: AppColors.line),
                    itemBuilder: (context, i) => _ActivityRow(row: rows[i]),
                  );
                },
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _ActivityRow extends StatelessWidget {
  const _ActivityRow({required this.row});

  final LogRow row;

  @override
  Widget build(BuildContext context) {
    final mission = ConsoleStore.instance.missionOf(row);
    final ids = {if (row.eventId.isNotEmpty) row.eventId, ?mission?.id}.join(' · ');
    final content = Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Container(
            margin: const EdgeInsets.only(top: 6),
            width: 8,
            height: 8,
            decoration: BoxDecoration(color: AppColors.accent.withValues(alpha: 0.8), shape: BoxShape.circle),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Expanded(child: Text(row.step.label, style: AppText.body)),
                    Text(row.time, style: AppText.codeMuted),
                  ],
                ),
                const SizedBox(height: 2),
                Text(row.detail, style: AppText.bodyMuted),
                const SizedBox(height: 2),
                if (ids.isNotEmpty) Text(ids, style: AppText.codeFaint),
              ],
            ),
          ),
        ],
      ),
    );
    if (mission == null) return content;
    return InkWell(
      onTap: () {
        final nav = Navigator.of(context, rootNavigator: true);
        nav.pop();
        nav.push(MaterialPageRoute<void>(builder: (_) => MissionDetailPage(mission: mission)));
      },
      child: content,
    );
  }
}
