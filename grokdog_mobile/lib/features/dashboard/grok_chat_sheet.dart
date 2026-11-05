import 'package:flutter/material.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

import '../../core/nav.dart';
import '../../core/theme.dart';
import '../../data/console_store.dart';
import '../../data/ronda/ronda_client.dart';
import '../../data/ronda/ronda_models.dart';

void showGrokChat(BuildContext context) {
  showModalBottomSheet<void>(context: context, useRootNavigator: true, isScrollControlled: true, builder: (_) => const _GrokChatSheet());
}

/// La console in linguaggio naturale di Grok: «ronda sala 1», «cos'è successo negli ultimi 10 minuti?».
class _GrokChatSheet extends StatefulWidget {
  const _GrokChatSheet();

  @override
  State<_GrokChatSheet> createState() => _GrokChatSheetState();
}

class _GrokChatSheetState extends State<_GrokChatSheet> {
  final _input = TextEditingController();
  bool _busy = false;

  @override
  void dispose() {
    _input.dispose();
    super.dispose();
  }

  Future<void> _send() async {
    final text = _input.text.trim();
    if (text.isEmpty || _busy) return;
    _input.clear();
    setState(() => _busy = true);
    try {
      await ConsoleStore.instance.ask(text);
    } on RondaFailure catch (e) {
      showMessage(e.message);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final height = MediaQuery.sizeOf(context).height * 0.72;
    return Padding(
      padding: EdgeInsets.only(bottom: MediaQuery.viewInsetsOf(context).bottom),
      child: SafeArea(
        child: SizedBox(
          height: height,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              const Padding(
                padding: EdgeInsets.fromLTRB(16, 0, 16, 10),
                child: Text('Ask Grok', style: AppText.medium),
              ),
              const Divider(height: 1, color: AppColors.line),
              Expanded(
                child: ListenableBuilder(
                  listenable: ConsoleStore.instance,
                  builder: (context, _) {
                    final chat = ConsoleStore.instance.chat;
                    if (chat.isEmpty) {
                      return const Center(
                        child: Padding(
                          padding: EdgeInsets.all(24),
                          child: Text(
                            'Try “patrol”, “go home”, “arm the alarm” or “what happened in the last 10 minutes?”',
                            textAlign: TextAlign.center,
                            style: AppText.bodyMuted,
                          ),
                        ),
                      );
                    }
                    return ListView.separated(
                      reverse: true,
                      padding: const EdgeInsets.all(16),
                      itemCount: chat.length,
                      separatorBuilder: (_, _) => const SizedBox(height: 8),
                      itemBuilder: (_, i) => _Bubble(chat[chat.length - 1 - i]),
                    );
                  },
                ),
              ),
              if (_busy) const LinearProgressIndicator(minHeight: 1, color: AppColors.accent, backgroundColor: Colors.transparent),
              Padding(
                padding: const EdgeInsets.fromLTRB(12, 8, 12, 12),
                child: Row(
                  children: [
                    Expanded(
                      child: TextField(
                        controller: _input,
                        style: AppText.body,
                        textInputAction: TextInputAction.send,
                        decoration: const InputDecoration(hintText: 'Type a command'),
                        onSubmitted: (_) => _send(),
                      ),
                    ),
                    const SizedBox(width: 8),
                    IconButton.filled(
                      onPressed: _busy ? null : _send,
                      tooltip: 'Send',
                      style: IconButton.styleFrom(backgroundColor: AppColors.ink, foregroundColor: AppColors.app),
                      icon: const Icon(LucideIcons.arrowUp, size: 18),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _Bubble extends StatelessWidget {
  const _Bubble(this.message);

  final ChatMessage message;

  @override
  Widget build(BuildContext context) {
    final user = message.role == 'user';
    return Align(
      alignment: user ? Alignment.centerRight : Alignment.centerLeft,
      child: ConstrainedBox(
        constraints: BoxConstraints(maxWidth: MediaQuery.sizeOf(context).width * 0.8),
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
          decoration: BoxDecoration(color: user ? AppColors.active : AppColors.app, borderRadius: BorderRadius.circular(12)),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              SelectableText(message.text, style: AppText.body),
              if (message.actions.isNotEmpty) ...[
                const SizedBox(height: 4),
                Text(message.actions.map((a) => a.replaceAll('_', ' ')).join(' · '), style: AppText.codeFaint),
              ],
            ],
          ),
        ),
      ),
    );
  }
}
