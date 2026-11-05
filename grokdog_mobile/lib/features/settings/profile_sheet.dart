import 'package:flutter/material.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

import '../../core/theme.dart';
import '../../data/console_store.dart';
import '../../data/mock_data.dart' show profile;
import '../../data/stores.dart';
import '../../shared/ui.dart';
import 'settings_page.dart';

void showProfileSheet(BuildContext context) {
  showModalBottomSheet<void>(context: context, useRootNavigator: true, isScrollControlled: true, builder: (_) => const _ProfileSheet());
}

/// Il profilo: su telefono raccoglie quello che in web sta in fondo alla sidebar (card GrokBot e menu).
class _ProfileSheet extends StatelessWidget {
  const _ProfileSheet();

  @override
  Widget build(BuildContext context) {
    void open(SettingsSection s) {
      final nav = Navigator.of(context, rootNavigator: true);
      nav.pop();
      nav.push(MaterialPageRoute<void>(builder: (_) => SettingsPage(section: s)));
    }

    Widget item(SettingsSection s) => ListTile(
      dense: true,
      leading: s == SettingsSection.grokbot ? const GrokBotIcon() : Icon(s.icon, size: 18, color: AppColors.muted),
      title: Text(s.label, style: AppText.body),
      onTap: () => open(s),
    );

    return SafeArea(
      child: ConstrainedBox(
        constraints: BoxConstraints(maxHeight: MediaQuery.sizeOf(context).height * 0.85),
        child: ListView(
          shrinkWrap: true,
          padding: const EdgeInsets.only(bottom: 8),
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
              child: Row(
                children: [
                  const UserAvatar(),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(profile.name, style: AppText.body),
                        Text(profile.shift, style: AppText.bodyMuted),
                      ],
                    ),
                  ),
                ],
              ),
            ),
            // il collegamento finto a GrokBot non ha senso accanto a quello vero
            if (!ConsoleStore.instance.isLive) const _GrokBotCard(),
            item(SettingsSection.server),
            item(SettingsSection.general),
            const Divider(height: 8, indent: 16, endIndent: 16, color: AppColors.line),
            item(SettingsSection.alerts),
            item(SettingsSection.bots),
            item(SettingsSection.grokbot),
            item(SettingsSection.cameras),
            const Divider(height: 8, indent: 16, endIndent: 16, color: AppColors.line),
            const ListTile(
              dense: true,
              enabled: false,
              leading: Icon(LucideIcons.logOut, size: 18, color: AppColors.faint),
              title: Text('Log out', style: AppText.bodyFaint),
              trailing: Text('Coming soon', style: AppText.bodyFaint),
            ),
          ],
        ),
      ),
    );
  }
}

/// «Connect» → un attimo di caricamento → conferma; collegato, la card sparisce.
/// La × la nasconde fino alla prossima apertura dell'app: finché GrokBot non è collegato torna.
class _GrokBotCard extends StatefulWidget {
  const _GrokBotCard();

  @override
  State<_GrokBotCard> createState() => _GrokBotCardState();
}

class _GrokBotCardState extends State<_GrokBotCard> {
  bool _asked = false;

  void _connect() {
    setState(() => _asked = true);
    GrokBotStore.instance.toggle();
  }

  void _confirmIfNeeded(GrokBotStatus status) {
    if (!_asked || status != GrokBotStatus.on) return;
    _asked = false;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      showDialog<void>(context: context, useRootNavigator: true, builder: (_) => const _ConnectedDialog());
    });
  }

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: GrokBotStore.instance,
      builder: (context, _) {
        final store = GrokBotStore.instance, status = store.status;
        _confirmIfNeeded(status);
        if (store.cardHidden || status == GrokBotStatus.on) return const SizedBox.shrink();
        final connecting = status == GrokBotStatus.connecting;
        return Container(
          margin: const EdgeInsets.fromLTRB(16, 0, 16, 12),
          padding: const EdgeInsets.all(12),
          decoration: BoxDecoration(
            color: AppColors.app.withValues(alpha: 0.4),
            borderRadius: BorderRadius.circular(12),
            border: Border.all(color: AppColors.line),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              // la × sta sopra l'immagine, non sulla foto
              Align(
                alignment: Alignment.centerRight,
                child: GestureDetector(
                  onTap: store.hideCard,
                  child: const Padding(
                    padding: EdgeInsets.only(left: 8, bottom: 4),
                    child: Icon(LucideIcons.x, size: 16, color: AppColors.muted, semanticLabel: 'Close'),
                  ),
                ),
              ),
              ClipRRect(
                borderRadius: BorderRadius.circular(8),
                child: Image.asset('assets/images/grokbot.png', fit: BoxFit.fitWidth, semanticLabel: 'GrokBot'),
              ),
              const SizedBox(height: 12),
              const Text('GrokBot', style: AppText.medium),
              const SizedBox(height: 4),
              const Text('Connect the dogs to GrokBot to control them directly from Grok.', style: AppText.bodyMuted),
              const SizedBox(height: 12),
              PrimaryButton(label: connecting ? 'Connecting…' : 'Connect', busy: connecting, onPressed: connecting ? null : _connect),
            ],
          ),
        );
      },
    );
  }
}

class _ConnectedDialog extends StatelessWidget {
  const _ConnectedDialog();

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      backgroundColor: AppColors.panel,
      surfaceTintColor: Colors.transparent,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(16),
        side: const BorderSide(color: AppColors.line),
      ),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          ClipRRect(borderRadius: BorderRadius.circular(8), child: Image.asset('assets/images/grokbot.png')),
          const SizedBox(height: 16),
          const Row(
            children: [
              Icon(LucideIcons.circleCheck, size: 20, color: AppColors.ok),
              SizedBox(width: 8),
              Text('GrokBot connected', style: AppText.section),
            ],
          ),
          const SizedBox(height: 6),
          const Text(
            'You can now drive the dogs and start missions directly from a Grok chat. You can disconnect it from Settings → GrokBot.',
            style: AppText.bodyMuted,
          ),
        ],
      ),
      actions: [PrimaryButton(label: 'Done', onPressed: () => Navigator.pop(context))],
    );
  }
}
