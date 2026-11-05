import 'package:flutter/material.dart';
import 'package:flutter_svg/flutter_svg.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

import '../core/theme.dart';
import '../data/models.dart';

// Mattoni condivisi: gli stessi di grokdog/src/components/ui.tsx.

/// Margini di una pagina a scorrimento. In fondo tiene conto della barra di vetro, sotto cui il contenuto passa.
EdgeInsets pagePadding(BuildContext context) => EdgeInsets.fromLTRB(16, 20, 16, 24 + MediaQuery.paddingOf(context).bottom);

class Logo extends StatelessWidget {
  const Logo({super.key, this.size = 20, this.color = AppColors.ink});

  final double size;
  final Color color;

  // stesso simbolo di Sidebar.tsx
  static const _svg =
      '<svg viewBox="0 0 24 24" xmlns="http://www.w3.org/2000/svg"><path fill="#fff" d="M24 7.417C8.882 8.287 1.89 14.75.321 16.28L0 16.583h2.797C10.356 9.005 21.222 7.663 24 7.417zm-17.046 6.35c-.472.321-.945.68-1.398 1.02l2.457 1.796h2.778zM2.948 10.8H.189l3.25 2.381c.473-.321 1.02-.661 1.512-.945Z"/></svg>';

  @override
  Widget build(BuildContext context) =>
      SvgPicture.string(_svg, width: size, height: size, colorFilter: ColorFilter.mode(color, BlendMode.srcIn), excludeFromSemantics: true);
}

class Panel extends StatelessWidget {
  const Panel({super.key, this.title, this.count, this.action, required this.child, this.padding = const EdgeInsets.all(16)});

  final String? title;

  /// Sta subito accanto al titolo; `action` va in fondo a destra.
  final int? count;
  final Widget? action;
  final Widget child;
  final EdgeInsets padding;

  @override
  Widget build(BuildContext context) {
    return Container(
      decoration: BoxDecoration(
        color: AppColors.panel,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: AppColors.line),
      ),
      clipBehavior: Clip.antiAlias,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        mainAxisSize: MainAxisSize.min,
        children: [
          if (title != null)
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
              decoration: const BoxDecoration(
                border: Border(bottom: BorderSide(color: AppColors.line)),
              ),
              child: Row(
                children: [
                  Text(title!, style: AppText.medium),
                  if (count != null) ...[const SizedBox(width: 8), CountChip(count!)],
                  const Spacer(),
                  ?action,
                ],
              ),
            ),
          Padding(padding: padding, child: child),
        ],
      ),
    );
  }
}

class Stat extends StatelessWidget {
  const Stat({super.key, required this.label, required this.value});

  final String label;
  final String value;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: AppColors.panel,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: AppColors.line),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          Text(label, style: AppText.bodyMuted),
          const SizedBox(height: 8),
          Text(
            value,
            style: const TextStyle(fontSize: 24, fontWeight: FontWeight.w500, letterSpacing: -0.3, fontFeatures: AppText.tabular),
          ),
        ],
      ),
    );
  }
}

enum Tone {
  red(AppColors.red400),
  amber(AppColors.amber300),
  green(AppColors.emerald400),
  gray(AppColors.muted),
  blue(AppColors.sky300);

  const Tone(this.color);
  final Color color;
}

class ToneBadge extends StatelessWidget {
  const ToneBadge({super.key, required this.tone, required this.label, this.color, this.icon});

  final Tone tone;
  final String label;

  /// Colore fuori tono (es. le etichette Automated/Custom delle missioni).
  final Color? color;
  final IconData? icon;

  @override
  Widget build(BuildContext context) {
    final c = color ?? tone.color;
    final gray = tone == Tone.gray && color == null;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
      decoration: BoxDecoration(
        color: gray ? Colors.white.withValues(alpha: 0.05) : c.withValues(alpha: 0.10),
        borderRadius: BorderRadius.circular(999),
        border: Border.all(color: gray ? Colors.white.withValues(alpha: 0.10) : c.withValues(alpha: 0.22)),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (icon != null) ...[Icon(icon, size: 14, color: c), const SizedBox(width: 6)],
          Flexible(
            child: Text(
              label,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(fontSize: 13, height: 1.4, fontWeight: FontWeight.w500, color: c),
            ),
          ),
        ],
      ),
    );
  }
}

const statusBadge = {
  EventStatus.inValutazione: (Tone.blue, 'Assessing'),
  EventStatus.inCoda: (Tone.blue, 'Queued'),
  EventStatus.missione: (Tone.amber, 'Mission'),
  EventStatus.verifica: (Tone.amber, 'Verifying'),
  EventStatus.alert: (Tone.red, 'Alert sent'),
  EventStatus.falsoAllarme: (Tone.gray, 'False alarm'),
  EventStatus.chiuso: (Tone.green, 'Closed'),
};

const _outcomeTone = {
  Outcome.anomalia: Tone.red,
  Outcome.falsoAllarme: Tone.gray,
  Outcome.inCorso: Tone.amber,
  Outcome.daVerificare: Tone.amber,
  Outcome.annullata: Tone.gray,
};

class StatusBadge extends StatelessWidget {
  const StatusBadge(this.status, {super.key});

  final EventStatus status;

  @override
  Widget build(BuildContext context) {
    final (tone, label) = statusBadge[status]!;
    return ToneBadge(tone: tone, label: label);
  }
}

class OutcomeBadge extends StatelessWidget {
  const OutcomeBadge(this.outcome, {super.key});

  final Outcome outcome;

  @override
  Widget build(BuildContext context) {
    return ToneBadge(tone: _outcomeTone[outcome]!, label: outcome.label);
  }
}

/// Bottone principale: bianco su scuro.
class PrimaryButton extends StatelessWidget {
  const PrimaryButton({super.key, required this.label, this.icon, this.onPressed, this.trailing, this.busy = false, this.height = 40});

  final String label;
  final IconData? icon;
  final IconData? trailing;
  final VoidCallback? onPressed;
  final double height;

  /// In attesa di una risposta: lo spinner prende il posto dell'icona.
  final bool busy;

  @override
  Widget build(BuildContext context) {
    final enabled = onPressed != null;
    return Opacity(
      opacity: enabled ? 1 : 0.4,
      child: Material(
        color: AppColors.ink,
        borderRadius: BorderRadius.circular(8),
        child: InkWell(
          onTap: onPressed,
          borderRadius: BorderRadius.circular(8),
          child: Container(
            height: height,
            padding: const EdgeInsets.symmetric(horizontal: 12),
            alignment: Alignment.center,
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                if (busy) ...[
                  const SizedBox.square(dimension: 14, child: CircularProgressIndicator(strokeWidth: 2, color: AppColors.app)),
                  const SizedBox(width: 8),
                ] else if (icon != null) ...[
                  Icon(icon, size: 16, color: AppColors.app),
                  const SizedBox(width: 8),
                ],
                Flexible(
                  child: Text(
                    label,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w500, color: AppColors.app),
                  ),
                ),
                if (trailing != null) ...[const SizedBox(width: 8), Icon(trailing, size: 16, color: AppColors.app)],
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// Bottone secondario con il bordo.
class GhostButton extends StatelessWidget {
  const GhostButton({super.key, required this.label, this.icon, this.onPressed, this.height = 40, this.color});

  final String label;
  final IconData? icon;
  final VoidCallback? onPressed;
  final double height;
  final Color? color;

  @override
  Widget build(BuildContext context) {
    final fg = onPressed == null ? AppColors.faint : (color ?? AppColors.ink);
    return Material(
      color: Colors.transparent,
      child: InkWell(
        onTap: onPressed,
        borderRadius: BorderRadius.circular(8),
        child: Container(
          height: height,
          padding: const EdgeInsets.symmetric(horizontal: 12),
          alignment: Alignment.center,
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(8),
            border: Border.all(color: AppColors.line),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              if (icon != null) ...[Icon(icon, size: 16, color: fg), const SizedBox(width: 8)],
              Flexible(
                child: Text(
                  label,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(fontSize: 14, color: fg),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// Riempitivo a righe diagonali dei video non ancora disponibili (il `repeating-linear-gradient` della web app).
class StripedPlaceholder extends StatelessWidget {
  const StripedPlaceholder({super.key, this.label, this.dark = false, this.child});

  final String? label;
  final bool dark;
  final Widget? child;

  @override
  Widget build(BuildContext context) {
    return CustomPaint(
      painter: _Stripes(dark ? const Color(0xFF141414) : const Color(0xFF1C1C1C), dark ? const Color(0xFF181818) : AppColors.panel),
      child: Stack(
        alignment: Alignment.center,
        children: [
          if (label != null) Text(label!, style: AppText.bodyFaint, textAlign: TextAlign.center),
          ?child,
        ],
      ),
    );
  }
}

class _Stripes extends CustomPainter {
  const _Stripes(this.a, this.b);

  final Color a, b;

  @override
  void paint(Canvas canvas, Size size) {
    canvas.clipRect(Offset.zero & size);
    canvas.drawColor(a, BlendMode.src);
    final paint = Paint()
      ..color = b
      ..strokeWidth = 12 * 1.2;
    for (double x = -size.height; x < size.width + size.height; x += 34) {
      canvas.drawLine(Offset(x, size.height), Offset(x + size.height, 0), paint);
    }
  }

  @override
  bool shouldRepaint(_Stripes old) => old.a != a || old.b != b;
}

/// Colore della batteria: verde, arancione sotto il 50%, rossa dal 30% in giù.
Color batteryColor(int battery) => battery <= 30
    ? AppColors.red400
    : battery < 50
    ? AppColors.accent
    : AppColors.ok;

/// Batteria disegnata + percentuale, l'unica dell'app; grigia se il robot è spento.
class BatteryTag extends StatelessWidget {
  const BatteryTag({super.key, required this.battery, this.off = false});

  /// null = il cane non l'ha ancora detto.
  final int? battery;
  final bool off;

  @override
  Widget build(BuildContext context) {
    final b = battery;
    if (b == null) return const Text('—', style: AppText.bodyFaint);
    final color = off ? AppColors.faint : batteryColor(b);
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        CustomPaint(size: const Size(23, 10), painter: _Battery(color, b)),
        const SizedBox(width: 6),
        Text(
          '$b%',
          style: AppText.code.copyWith(fontSize: 14, color: color),
          semanticsLabel: 'Battery $b%',
        ),
      ],
    );
  }
}

class _Battery extends CustomPainter {
  const _Battery(this.color, this.level);

  final Color color;
  final int level;

  @override
  void paint(Canvas canvas, Size size) {
    const w = 20.0;
    final border = Paint()
      ..color = color
      ..style = PaintingStyle.stroke;
    canvas.drawRRect(RRect.fromLTRBR(0.5, 0.5, w - 0.5, size.height - 0.5, const Radius.circular(3)), border);
    final fill = Paint()..color = color;
    canvas.drawRRect(RRect.fromLTRBR(2, 2, 2 + (w - 4) * level.clamp(0, 100) / 100, size.height - 2, const Radius.circular(1)), fill);
    canvas.drawRRect(RRect.fromLTRBR(w, 3, w + 2, size.height - 3, const Radius.circular(1)), fill);
  }

  @override
  bool shouldRepaint(_Battery old) => old.color != color || old.level != level;
}

/// Foto del robot, tonda e piccola. Spento = in grigio.
class RobotAvatar extends StatelessWidget {
  const RobotAvatar({super.key, this.off = false, this.size = 24});

  final bool off;
  final double size;

  @override
  Widget build(BuildContext context) {
    Widget image = Transform.scale(
      scale: 1.5,
      child: Image.asset('assets/images/robot-dog.png', fit: BoxFit.cover, alignment: const Alignment(-0.2, -0.1), cacheWidth: 150),
    );
    if (off) {
      image = Opacity(
        opacity: 0.4,
        child: ColorFiltered(colorFilter: const ColorFilter.mode(Colors.grey, BlendMode.saturation), child: image),
      );
    }
    return ExcludeSemantics(
      child: ClipOval(
        child: SizedBox.square(
          dimension: size,
          child: DecoratedBox(
            decoration: const BoxDecoration(
              gradient: RadialGradient(center: Alignment(-0.2, -0.1), radius: 1, colors: [AppColors.line, Color(0xFF141414)]),
            ),
            child: image,
          ),
        ),
      ),
    );
  }
}

/// Il numerino grigio accanto a un titolo («In progress 2», «Activity 26»).
class CountChip extends StatelessWidget {
  const CountChip(this.n, {super.key});

  final int n;

  @override
  Widget build(BuildContext context) => Text('$n', style: AppText.codeMuted.copyWith(fontSize: 14));
}

enum GrokBotIconStyle {
  /// Sfera vuota, come le icone Lucide.
  line,

  /// Sfera piena del colore dato, occhi bianchi o bucati.
  filled,
}

/// Il logo di Grok Bot: la sfera con i due occhi.
class GrokBotIcon extends StatelessWidget {
  const GrokBotIcon({
    super.key,
    this.size = 18,
    this.color = AppColors.muted,
    this.style = GrokBotIconStyle.filled,
    this.eyes = AppColors.app,
  });

  final double size;
  final Color color, eyes;
  final GrokBotIconStyle style;

  @override
  Widget build(BuildContext context) => CustomPaint(size: Size.square(size), painter: _GrokBot(color, eyes, style));
}

class _GrokBot extends CustomPainter {
  const _GrokBot(this.color, this.eyes, this.style);

  final Color color, eyes;
  final GrokBotIconStyle style;

  @override
  void paint(Canvas canvas, Size size) {
    canvas.scale(size.width / 24);
    final filled = style == GrokBotIconStyle.filled;
    canvas.drawCircle(
      const Offset(12, 12),
      filled ? 10.5 : 9,
      Paint()
        ..color = color
        ..style = filled ? PaintingStyle.fill : PaintingStyle.stroke
        ..strokeWidth = 2,
    );
    final eye = Paint()
      ..color = filled ? eyes : color
      ..strokeWidth = filled ? 2.4 : 2.7
      ..strokeCap = StrokeCap.round;
    canvas.drawLine(const Offset(8.9, 10.2), const Offset(10.3, 13.8), eye);
    canvas.drawLine(const Offset(13.6, 8.6), const Offset(14.6, 11), eye);
  }

  @override
  bool shouldRepaint(_GrokBot old) => old.color != color || old.eyes != eyes;
}

/// Titolo di pagina con l'azione a destra (il PageHeader della web app).
class PageHeader extends StatelessWidget {
  const PageHeader({super.key, required this.title, this.actions});

  final String title;
  final Widget? actions;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 20),
      child: Row(
        children: [
          Expanded(child: Text(title, style: AppText.title)),
          ?actions,
        ],
      ),
    );
  }
}

/// Scelta da un elenco in un foglio dal basso: su telefono è più comodo di un menu a tendina.
Future<T?> showChoiceSheet<T>(BuildContext context, {required String title, required List<(T, String)> options, required T value}) {
  return showModalBottomSheet<T>(
    context: context,
    useRootNavigator: true,
    isScrollControlled: true,
    builder: (ctx) => SafeArea(
      child: ConstrainedBox(
        constraints: BoxConstraints(maxHeight: MediaQuery.sizeOf(ctx).height * 0.6),
        child: ListView(
          shrinkWrap: true,
          padding: const EdgeInsets.fromLTRB(8, 0, 8, 8),
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(12, 0, 12, 8),
              child: Text(title, style: AppText.bodyMuted),
            ),
            for (final (v, label) in options)
              ListTile(
                dense: true,
                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
                title: Text(label, style: AppText.body),
                trailing: v == value ? const Icon(LucideIcons.check, size: 16, color: AppColors.accent) : null,
                onTap: () => Navigator.pop(ctx, v),
              ),
          ],
        ),
      ),
    ),
  );
}

/// Campo a selezione: come il `<select>` della web app.
class SelectField<T> extends StatelessWidget {
  const SelectField({
    super.key,
    required this.title,
    required this.value,
    required this.options,
    required this.onChanged,
    this.fill = AppColors.app,
  });

  final String title;
  final T value;
  final List<(T, String)> options;
  final ValueChanged<T> onChanged;
  final Color fill;

  @override
  Widget build(BuildContext context) {
    final current = options.where((o) => o.$1 == value).firstOrNull?.$2 ?? '';
    return Semantics(
      button: true,
      label: '$title: $current',
      excludeSemantics: true,
      child: Material(
        color: fill,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(8),
          side: const BorderSide(color: AppColors.line),
        ),
        clipBehavior: Clip.antiAlias,
        child: InkWell(
          onTap: () async {
            final v = await showChoiceSheet<T>(context, title: title, options: options, value: value);
            if (v != null) onChanged(v);
          },
          child: Container(
            height: 40,
            padding: const EdgeInsets.only(left: 12, right: 10),
            child: Row(
              children: [
                Expanded(
                  child: Text(current, style: AppText.body, maxLines: 1, overflow: TextOverflow.ellipsis),
                ),
                const Icon(LucideIcons.chevronDown, size: 16, color: AppColors.muted),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
