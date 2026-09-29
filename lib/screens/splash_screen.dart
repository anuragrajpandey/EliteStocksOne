import 'dart:async';

import 'package:flutter/material.dart';

import '../theme.dart';

/// Keeps the real app mounted and initializing beneath a short launch screen.
class LaunchGate extends StatefulWidget {
  const LaunchGate({
    super.key,
    required this.child,
    this.startup,
    this.minimumDuration = const Duration(milliseconds: 900),
  });

  final Widget child;
  final Future<void>? startup;
  final Duration minimumDuration;

  @override
  State<LaunchGate> createState() => _LaunchGateState();
}

class _LaunchGateState extends State<LaunchGate> {
  bool _showSplash = true;

  @override
  void initState() {
    super.initState();
    _finishLaunch();
  }

  Future<void> _finishLaunch() async {
    final startup = widget.startup;
    await Future.wait([
      Future<void>.delayed(widget.minimumDuration),
      if (startup != null) _guardStartup(startup),
    ]);
    if (mounted) setState(() => _showSplash = false);
  }

  Future<void> _guardStartup(Future<void> startup) async {
    try {
      await startup;
    } catch (error, stack) {
      debugPrint('Launch preparation failed: $error\\n$stack');
    }
  }

  @override
  Widget build(BuildContext context) {
    return Stack(
      fit: StackFit.expand,
      children: [
        widget.child,
        AnimatedSwitcher(
          duration: const Duration(milliseconds: 260),
          reverseDuration: const Duration(milliseconds: 220),
          transitionBuilder: (child, animation) =>
              FadeTransition(opacity: animation, child: child),
          child: _showSplash
              ? const LaunchSplash(key: ValueKey('lumen-launch-splash'))
              : const SizedBox.shrink(key: ValueKey('lumen-launch-complete')),
        ),
      ],
    );
  }
}

/// Simple branded launch screen using the supplied EliteStocks TV icon.
class LaunchSplash extends StatelessWidget {
  const LaunchSplash({super.key});

  @override
  Widget build(BuildContext context) {
    final size = MediaQuery.sizeOf(context);
    final iconSize = size.shortestSide < 560 ? 150.0 : 210.0;

    return const Material(
      color: Color(0xFF070909),
      child: Center(
        child: _EliteStocksLaunchIcon(),
      ),
    );
  }
}

class _EliteStocksLaunchIcon extends StatelessWidget {
  const _EliteStocksLaunchIcon();

  @override
  Widget build(BuildContext context) {
    final size = MediaQuery.sizeOf(context);
    final iconSize = size.shortestSide < 560 ? 150.0 : 210.0;

    return Image(
      image: const AssetImage('assets/EliteStocksTVicon.png'),
      width: iconSize,
      height: iconSize,
      fit: BoxFit.contain,
      filterQuality: FilterQuality.high,
      semanticLabel: 'EliteStocks TV',
    );
  }
}

/// A neutral session operation state.
class SessionLoading extends StatelessWidget {
  const SessionLoading({super.key, required this.message});

  final String message;

  @override
  Widget build(BuildContext context) {
    final tv = MediaQuery.sizeOf(context).shortestSide >= 560;
    final markSize = tv ? 84.0 : 64.0;
    return Material(
      color: const Color(0xFF070909),
      child: SafeArea(
        child: Center(
          child: Semantics(
            liveRegion: true,
            label: message,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Image.asset(
                  'assets/EliteStocksTVicon.png',
                  width: markSize * 1.5,
                  height: markSize * 1.5,
                  fit: BoxFit.contain,
                  filterQuality: FilterQuality.high,
                  semanticLabel: 'EliteStocks TV',
                ),
                SizedBox(height: tv ? 28 : 22),
                Text(
                  message,
                  style: TextStyle(
                    color: const Color(0xFFA2A6A3),
                    fontFamily: 'SpaceGrotesk',
                    fontSize: tv ? 13 : 11,
                    fontWeight: FontWeight.w600,
                    letterSpacing: tv ? 2.8 : 2.2,
                  ),
                ),
                const SizedBox(height: 18),
                SizedBox(
                  width: tv ? 240 : 190,
                  child: const LinearProgressIndicator(
                    minHeight: 2,
                    backgroundColor: Color(0xFF252A26),
                    color: defaultAccent,
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
