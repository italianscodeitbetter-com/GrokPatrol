import 'package:flutter/material.dart';

import '../../core/theme.dart';
import '../../shared/ui.dart';

// Mattoni delle impostazioni: titolo del gruppo sopra, card con righe, nota sotto.

class SettingsGroup extends StatelessWidget {
  const SettingsGroup({super.key, this.title, this.header, this.note, required this.children});

  final String? title;
  final Widget? header;
  final String? note;
  final List<Widget> children;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 32),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Padding(
            padding: const EdgeInsets.only(left: 4, bottom: 10),
            child: header ?? Text(title ?? '', style: AppText.section),
          ),
          Container(
            decoration: BoxDecoration(
              color: Colors.white.withValues(alpha: 0.015),
              borderRadius: BorderRadius.circular(16),
              border: Border.all(color: AppColors.line),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                for (final (i, c) in children.indexed)
                  DecoratedBox(
                    decoration: BoxDecoration(
                      border: i == 0 ? null : const Border(top: BorderSide(color: AppColors.line)),
                    ),
                    child: c,
                  ),
              ],
            ),
          ),
          if (note != null)
            Padding(
              padding: const EdgeInsets.fromLTRB(4, 8, 4, 0),
              child: Text(note!, style: const TextStyle(fontSize: 13, height: 1.5, color: AppColors.faint)),
            ),
        ],
      ),
    );
  }
}

/// Riga etichetta + controllo. Con [below] il controllo va sotto: i campi larghi non stanno di fianco su un telefono.
class SettingsRow extends StatelessWidget {
  const SettingsRow({super.key, required this.label, this.hint, this.trailing, this.below});

  final String label;
  final String? hint;
  final Widget? trailing;
  final Widget? below;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(label, style: AppText.row),
                    if (hint != null) ...[const SizedBox(height: 2), Text(hint!, style: AppText.bodyMuted)],
                  ],
                ),
              ),
              if (trailing != null) ...[const SizedBox(width: 12), trailing!],
            ],
          ),
          if (below != null) ...[const SizedBox(height: 10), below!],
        ],
      ),
    );
  }
}

class ValueText extends StatelessWidget {
  const ValueText(this.text, {super.key});

  final String text;

  @override
  Widget build(BuildContext context) => Text(text, style: const TextStyle(fontSize: 15, color: AppColors.muted));
}

class SettingsTextField extends StatelessWidget {
  const SettingsTextField({super.key, required this.initialValue, this.keyboardType});

  final String initialValue;
  final TextInputType? keyboardType;

  @override
  Widget build(BuildContext context) {
    return TextFormField(
      initialValue: initialValue,
      keyboardType: keyboardType,
      style: const TextStyle(fontSize: 15),
      decoration: const InputDecoration(fillColor: AppColors.panel, filled: true),
    );
  }
}

/// Selettore con il proprio stato: come in web, la scelta resta finché la pagina è aperta.
class SettingsSelect<T> extends StatefulWidget {
  const SettingsSelect({super.key, required this.title, required this.initial, required this.options});

  final String title;
  final T initial;
  final List<(T, String)> options;

  @override
  State<SettingsSelect<T>> createState() => _SettingsSelectState<T>();
}

class _SettingsSelectState<T> extends State<SettingsSelect<T>> {
  late T _value = widget.initial;

  @override
  Widget build(BuildContext context) => SelectField<T>(
    title: widget.title,
    value: _value,
    options: widget.options,
    fill: AppColors.panel,
    onChanged: (v) => setState(() => _value = v),
  );
}

/// Riga per una chiave API. Per ora non salva né verifica nulla: lo stato resta nella pagina.
class KeyRow extends StatefulWidget {
  const KeyRow({super.key, required this.name, required this.hint, required this.placeholder});

  final String name;
  final String hint;
  final String placeholder;

  @override
  State<KeyRow> createState() => _KeyRowState();
}

class _KeyRowState extends State<KeyRow> {
  final _value = TextEditingController();
  String _status = 'Not connected';

  @override
  void dispose() {
    _value.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final has = _value.text.isNotEmpty;
    return SettingsRow(
      label: widget.name,
      hint: widget.hint,
      below: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          TextField(
            controller: _value,
            obscureText: true,
            autocorrect: false,
            enableSuggestions: false,
            style: AppText.code.copyWith(fontSize: 14),
            decoration: InputDecoration(hintText: widget.placeholder, fillColor: AppColors.panel),
            onChanged: (_) => setState(() {}),
          ),
          const SizedBox(height: 8),
          Row(
            children: [
              Expanded(child: Text(_status, style: AppText.bodyMuted)),
              GhostButton(
                label: 'Check',
                height: 36,
                onPressed: () => setState(() => _status = has ? 'Key not checked yet: not wired up' : 'Paste a key first'),
              ),
              const SizedBox(width: 8),
              GhostButton(label: 'Save', height: 36, onPressed: has ? () => setState(() => _status = 'Saved for this session only') : null),
            ],
          ),
        ],
      ),
    );
  }
}
