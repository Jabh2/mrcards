import 'package:flutter/material.dart';
import 'qc_theme.dart';

bool qcReduce(BuildContext c, bool animationsEnabled) =>
    MediaQuery.of(c).disableAnimations || !animationsEnabled;

Duration qcFast(BuildContext c, bool enabled) =>
    qcReduce(c, enabled) ? Duration.zero : QCTokens.animFast;
Duration qcMed(BuildContext c, bool enabled) =>
    qcReduce(c, enabled) ? Duration.zero : QCTokens.animMed;

/// Pop: scale 1 -> 1.06 -> 1 (180ms)
class QCPop extends StatefulWidget {
  const QCPop({super.key, required this.child, this.trigger = 0});
  final Widget child;
  final int trigger;
  @override
  State<QCPop> createState() => _QCPopState();
}

class _QCPopState extends State<QCPop> with SingleTickerProviderStateMixin {
  late AnimationController _c;
  @override
  void initState() {
    super.initState();
    _c = AnimationController(vsync: this, duration: QCTokens.animFast);
  }

  @override
  void didUpdateWidget(covariant QCPop old) {
    super.didUpdateWidget(old);
    if (widget.trigger != old.trigger) _c.forward(from: 0);
  }

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext c) => ScaleTransition(
    scale: TweenSequence<double>([
      TweenSequenceItem(tween: Tween<double>(begin: 1, end: 1.06).chain(CurveTween(curve: Curves.easeOut)), weight: 50),
      TweenSequenceItem(tween: Tween<double>(begin: 1.06, end: 1).chain(CurveTween(curve: Curves.easeIn)), weight: 50),
    ]).animate(_c),
    child: widget.child,
  );
}

/// Shake horizontal corto
class QCShake extends StatefulWidget {
  const QCShake({super.key, required this.child, this.trigger = 0});
  final Widget child;
  final int trigger;
  @override
  State<QCShake> createState() => _QCShakeState();
}

class _QCShakeState extends State<QCShake> with SingleTickerProviderStateMixin {
  late AnimationController _c;
  late Animation<double> _anim;
  @override
  void initState() {
    super.initState();
    _c = AnimationController(vsync: this, duration: const Duration(milliseconds: 300));
    _anim = TweenSequence<double>([
      TweenSequenceItem(tween: Tween(begin: 0, end: -6), weight: 1),
      TweenSequenceItem(tween: Tween(begin: -6, end: 6), weight: 1),
      TweenSequenceItem(tween: Tween(begin: 6, end: -4), weight: 1),
      TweenSequenceItem(tween: Tween(begin: -4, end: 4), weight: 1),
      TweenSequenceItem(tween: Tween(begin: 4, end: 0), weight: 1),
    ]).animate(CurvedAnimation(parent: _c, curve: Curves.easeInOut));
  }

  @override
  void didUpdateWidget(covariant QCShake old) {
    super.didUpdateWidget(old);
    if (widget.trigger != old.trigger) _c.forward(from: 0);
  }

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext c) => AnimatedBuilder(
    animation: _anim,
    builder: (_, child) => Transform.translate(
      offset: Offset(_anim.value, 0),
      child: child,
    ),
    child: widget.child,
  );
}
