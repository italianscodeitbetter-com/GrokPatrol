import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

import 'core/deep_link.dart';
import 'core/nav.dart';
import 'core/theme.dart';
import 'data/console_store.dart';
import 'data/ronda/ronda_link.dart';
import 'features/automation/automation_page.dart';
import 'features/dashboard/dashboard_page.dart';
import 'features/missions/deep_link_page.dart';
import 'features/missions/missions_page.dart';
import 'features/reports/reports_page.dart';
import 'features/settings/profile_sheet.dart';
import 'features/settings/settings_page.dart';
import 'shared/alert_banner.dart';
import 'shared/glass_tab_bar.dart';
import 'shared/ui.dart';

class GrokPatrolApp extends StatelessWidget {
  const GrokPatrolApp({super.key});

  @override
  Widget build(BuildContext context) {
    return AnnotatedRegion<SystemUiOverlayStyle>(
      value: SystemUiOverlayStyle.light,
      child: MaterialApp(
        title: 'GrokPatrol',
        debugShowCheckedModeBanner: false,
        theme: buildTheme(),
        navigatorObservers: [routeObserver],
        scaffoldMessengerKey: rootMessengerKey,
        // sopra a tutto: un alert si deve vedere da qualsiasi pagina
        builder: (context, child) => Stack(children: [?child, const AlertBanner()]),
        // niente `home`: con un link da Telegram all'avvio la pila è [Shell, missione], vedi _initialRoutes
        onGenerateInitialRoutes: _initialRoutes,
        onGenerateRoute: _generateRoute,
        onUnknownRoute: (settings) => closingRoute(settings, message: unknownLinkMessage),
      ),
    );
  }
}

Route<void> _shellRoute() =>
    MaterialPageRoute<void>(settings: const RouteSettings(name: Navigator.defaultRouteName), builder: (_) => const Shell());

/// All'avvio da freddo: la rotta viene dal link che ha aperto l'app (grokpatrol://open/mission/x → /mission/x).
/// Le schede stanno sempre sotto, così indietro dal dettaglio si torna all'app e non a una pagina vuota.
List<Route<dynamic>> _initialRoutes(String initialRoute) {
  final link = parseDeepLink(initialRoute);
  if (link == null && initialRoute.isNotEmpty && initialRoute != Navigator.defaultRouteName) {
    WidgetsBinding.instance.addPostFrameCallback((_) => showMessage(unknownLinkMessage));
  }
  return [_shellRoute(), if (link != null) deepLinkRoute(link, settings: RouteSettings(name: initialRoute))];
}

/// Con l'app già aperta Flutter fa pushNamed con il percorso del link. Le schede ci sono già dall'avvio:
/// "/" (grokpatrol://open senza percorso) riporta solo l'app in primo piano.
Route<dynamic>? _generateRoute(RouteSettings settings) {
  final name = settings.name ?? '';
  if (name.isEmpty || name == Navigator.defaultRouteName) return closingRoute(settings);
  final link = parseDeepLink(name);
  return link == null ? null : deepLinkRoute(link, settings: settings);
}

/// Le quattro voci della sidebar diventano la barra in basso. Le pagine restano vive: la mappa non si ricarica.
class Shell extends StatefulWidget {
  const Shell({super.key});

  @override
  State<Shell> createState() => _ShellState();
}

class _ShellState extends State<Shell> {
  static const _destinations = [
    GlassTabItem('Dashboard', LucideIcons.layoutDashboard),
    GlassTabItem('Automation', LucideIcons.bot),
    GlassTabItem('Missions', LucideIcons.route),
    GlassTabItem('Reports', LucideIcons.fileText),
  ];

  int _tab = 0;
  bool _immersive = false;

  void _select(int i) => setState(() => _tab = i);

  @override
  void initState() {
    super.initState();
    showReportsActivity.addListener(_openReports);
    showMissions.addListener(_openMissions);
    showActivityPanel.addListener(_openDashboard);
  }

  @override
  void dispose() {
    showReportsActivity.removeListener(_openReports);
    showMissions.removeListener(_openMissions);
    showActivityPanel.removeListener(_openDashboard);
    super.dispose();
  }

  void _openReports() => _select(3);
  void _openMissions() => _select(2);
  void _openDashboard() => _select(0);

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppColors.side,
      // il vetro ha senso solo se sotto ci passa il contenuto
      extendBody: GlassTabBar.supported,
      appBar: _immersive ? null : const _TopBar(),
      body: IndexedStack(
        index: _tab,
        children: [
          DashboardPage(visible: _tab == 0, onImmersive: (v) => setState(() => _immersive = v)),
          const AutomationPage(),
          const MissionsPage(),
          const ReportsPage(),
        ],
      ),
      bottomNavigationBar: _immersive
          ? null
          : GlassTabBar.supported
          ? GlassTabBar(items: _destinations, selected: _tab, onSelected: _select)
          : _MaterialTabBar(items: _destinations, selected: _tab, onSelected: _select),
    );
  }
}

/// Pagina attiva bianca, le altre al 60%: gli stessi colori della barra nativa.
Color _tabColor(Set<WidgetState> states) => states.contains(WidgetState.selected) ? Colors.white : Colors.white.withValues(alpha: 0.6);

/// Android e iOS prima del 26: il Liquid Glass non esiste, resta la barra opaca.
class _MaterialTabBar extends StatelessWidget {
  const _MaterialTabBar({required this.items, required this.selected, required this.onSelected});

  final List<GlassTabItem> items;
  final int selected;
  final ValueChanged<int> onSelected;

  @override
  Widget build(BuildContext context) {
    return DecoratedBox(
      decoration: const BoxDecoration(
        border: Border(top: BorderSide(color: AppColors.line)),
      ),
      child: NavigationBarTheme(
        data: NavigationBarThemeData(
          height: 60,
          backgroundColor: AppColors.side,
          surfaceTintColor: Colors.transparent,
          indicatorColor: AppColors.active,
          iconTheme: WidgetStateProperty.resolveWith((s) => IconThemeData(size: 20, color: _tabColor(s))),
          labelTextStyle: WidgetStateProperty.resolveWith((s) => TextStyle(fontSize: 12, color: _tabColor(s))),
        ),
        child: NavigationBar(
          selectedIndex: selected,
          onDestinationSelected: onSelected,
          destinations: [for (final d in items) NavigationDestination(icon: Icon(d.icon), label: d.title)],
        ),
      ),
    );
  }
}

class _TopBar extends StatelessWidget implements PreferredSizeWidget {
  const _TopBar();

  @override
  Size get preferredSize => const Size.fromHeight(48);

  @override
  Widget build(BuildContext context) {
    return Container(
      decoration: const BoxDecoration(
        color: AppColors.side,
        border: Border(bottom: BorderSide(color: AppColors.line)),
      ),
      child: SafeArea(
        bottom: false,
        child: SizedBox(
          height: 48,
          child: Row(
            children: [
              const SizedBox(width: 16),
              const Logo(),
              const SizedBox(width: 10),
              const Expanded(child: Text('GrokPatrol', style: AppText.medium)),
              const _LinkPill(),
              Semantics(
                container: true,
                button: true,
                label: 'Profile and settings',
                excludeSemantics: true,
                onTap: () => showProfileSheet(context),
                child: GestureDetector(
                  onTap: () => showProfileSheet(context),
                  behavior: HitTestBehavior.opaque,
                  child: const Padding(padding: EdgeInsets.symmetric(horizontal: 12, vertical: 7), child: UserAvatar(size: 32)),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// Da dove vengono i dati: su una console di sorveglianza non deve esserci mai dubbio.
class _LinkPill extends StatelessWidget {
  const _LinkPill();

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: ConsoleStore.instance,
      builder: (context, _) {
        final store = ConsoleStore.instance;
        final (text, color) = switch ((store.mode, store.link)) {
          (ConsoleMode.demo, _) => ('Demo data', AppColors.faint),
          (ConsoleMode.connecting, _) => ('Connecting…', AppColors.amber300),
          (_, LinkState.live) => ('Live', AppColors.ok),
          (_, LinkState.polling) => ('Live · polling', AppColors.amber300),
          (_, LinkState.offline) => ('Offline', AppColors.red400),
        };
        return Semantics(
          button: true,
          label: 'Server: $text',
          excludeSemantics: true,
          child: GestureDetector(
            behavior: HitTestBehavior.opaque,
            onTap: () =>
                Navigator.of(context).push(MaterialPageRoute<void>(builder: (_) => const SettingsPage(section: SettingsSection.server))),
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 8),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Container(
                    width: 7,
                    height: 7,
                    decoration: BoxDecoration(color: color, shape: BoxShape.circle),
                  ),
                  const SizedBox(width: 6),
                  Text(text, style: const TextStyle(fontSize: 12, color: AppColors.muted)),
                ],
              ),
            ),
          ),
        );
      },
    );
  }
}
