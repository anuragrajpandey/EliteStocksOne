import 'dart:async';
import 'dart:io' show Platform;
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:media_kit/media_kit.dart';
import 'package:window_manager/window_manager.dart';
import 'catalog_cache.dart';
import 'demo_catalog.dart';
import 'downloads.dart';
import 'device_profile.dart';
import 'diagnostics.dart';
import 'home_config.dart';
import 'models.dart';
import 'multi_source.dart';
import 'network_path.dart';
import 'playback.dart';
import 'playback_mode.dart';
import 'responsive.dart';
import 'session.dart';
import 'split.dart';
import 'stats.dart';
import 'store.dart';
import 'viewing_profiles.dart';
import 'library.dart';
import 'legal.dart';
import 'theme.dart';
import 'updater.dart';
import 'widgets.dart';
import 'xtream.dart';
import 'screens/login_screen.dart';
import 'screens/legal_screen.dart';
import 'screens/player_host.dart';
import 'screens/shell.dart';
import 'screens/splash_screen.dart';
import 'screens/viewer_picker_screen.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  final previousFlutterError = FlutterError.onError;
  FlutterError.onError = (details) {
    AppDiagnostics.instance.record(
      'App',
      'Framework error (${details.exception.runtimeType})',
    );
    if (previousFlutterError != null) {
      previousFlutterError(details);
    } else {
      FlutterError.presentError(details);
    }
  };
  final previousPlatformError = PlatformDispatcher.instance.onError;
  PlatformDispatcher.instance.onError = (error, stack) {
    AppDiagnostics.instance.record(
      'App',
      'Unhandled error (${error.runtimeType})',
    );
    return previousPlatformError?.call(error, stack) ?? false;
  };
  await DeviceProfile.detect();
  await Updater.instance.initialize();
  await NetworkPathMonitor.instance.initialize();
  AppDiagnostics.instance.record(
    'App',
    DeviceProfile.isTelevision ? 'Started on television' : 'Started',
  );
  if (!kIsWeb && Platform.isAndroid && !DeviceProfile.isTelevision) {
    await SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge);
  }
  // Catalog artwork is decoded to tile-sized buffers. Keep a generous but
  // bounded cache so large libraries cannot crowd video playback out of RAM.
  final imageCache = PaintingBinding.instance.imageCache;
  if (!kIsWeb && Platform.isAndroid) {
    imageCache.maximumSize = DeviceProfile.isTelevision ? 220 : 400;
    imageCache.maximumSizeBytes =
        (DeviceProfile.isTelevision ? 64 : 128) * 1024 * 1024;
  } else {
    imageCache.maximumSize = 700;
    imageCache.maximumSizeBytes = 224 * 1024 * 1024;
  }
  // Desktop: enable window control (used for real fullscreen in the player).
  if (!kIsWeb && (Platform.isMacOS || Platform.isWindows || Platform.isLinux)) {
    await windowManager.ensureInitialized();
  }
  MediaKit.ensureInitialized(); // libmpv — native TS/MKV/HLS playback
  final startup = DemoCatalog.preparePlayback();

  // Never show a blank/white error screen — paint errors on the dark canvas.
  ErrorWidget.builder = (details) => Container(
    color: bg,
    alignment: Alignment.center,
    padding: const EdgeInsets.all(24),
    child: Text(
      details.exceptionAsString(),
      textAlign: TextAlign.center,
      style: TextStyle(color: dangerInk, fontSize: 13),
    ),
  );

  runApp(LumenApp(startup: startup));
  if (const bool.fromEnvironment('LUMEN_LOG_FOCUS')) {
    FocusManager.instance.addListener(() {
      final focus = FocusManager.instance.primaryFocus;
      final path = <String>[
        ?focus?.debugLabel,
        ...?focus?.ancestors.map((node) => node.debugLabel).whereType<String>(),
      ];
      debugPrint('LUMEN_FOCUS ${path.join(' > ')}');
    });
  }
  // Android playback uses the native Media3 Activity first. Do not
  // prewarm libmpv on Android, because the embedded decoder is only a fallback
  // there and initializing it at launch wastes memory and can trigger native
  // decoder/texture failures before the user even starts playback.
  if (!kIsWeb && !Platform.isAndroid) {
    WidgetsBinding.instance.addPostFrameCallback(
      (_) => PlaybackController.instance.prewarm(),
    );
  }
}

class LumenApp extends StatelessWidget {
  const LumenApp({
    super.key,
    this.startup,
    this.minimumSplashDuration = const Duration(milliseconds: 1850),
  });

  final Future<void>? startup;
  final Duration minimumSplashDuration;
  static final RemoteFocusTraversalPolicy _remoteFocusPolicy =
      RemoteFocusTraversalPolicy();

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      // Rebuild on theme-mode AND accent-colour changes.
      animation: ThemeController.instance.listenable,
      builder: (context, _) {
        final mode = ThemeController.instance.mode.value;
        final accent = ThemeController.instance.accent.value;
        return MaterialApp(
          title: 'EliteStocks One',
          debugShowCheckedModeBanner: false,
          navigatorKey: rootNavKey,
          theme: buildTheme(lightPaletteFor(accent)),
          darkTheme: buildTheme(darkPaletteFor(accent)),
          themeMode: mode,
          // Flip instantly (no lerp) — our global palette getters switch at once,
          // and a non-const home forces the whole subtree to re-read them.
          themeAnimationDuration: Duration.zero,
          // The player floats above every screen (full-screen or docked mini).
          // A bare Overlay (+ Material) gives the controls an Overlay (seek
          // slider) and a text style, while passing clicks through wherever the
          // player isn't painting — so the app stays interactive (e.g. while the
          // mini is docked).
          builder: (context, child) {
            return TelevisionDensityViewport(
              child: LumenPaletteScope(
                mode: mode,
                child: FocusTraversalGroup(
                  policy: _remoteFocusPolicy,
                  child: RemoteFocusVisibility(
                    child: AnimatedBuilder(
                      animation: PlaybackController.instance,
                      child: Stack(
                        children: [
                          AnimatedBuilder(
                            animation: PlaybackController.instance,
                            child: child ?? const SizedBox.shrink(),
                            builder: (context, app) {
                              final playback = PlaybackController.instance;
                              return ExcludeFocus(
                                excluding:
                                    playback.hasMedia && !playback.minimized,
                                child: app!,
                              );
                            },
                          ),
                          const Positioned.fill(child: _PlayerOverlayLayer()),
                        ],
                      ),
                      builder: (context, stack) {
                        final playback = PlaybackController.instance;
                        final playerOwnsBack =
                            playback.hasMedia && !playback.minimized;
                        return PopScope(
                          canPop: !playerOwnsBack,
                          onPopInvokedWithResult: (didPop, _) {
                            if (!didPop) PlayerHost.handleSystemBack();
                          },
                          child: stack!,
                        );
                      },
                    ),
                  ),
                ),
              ),
            );
          },
          home: LaunchGate(
            startup: startup,
            minimumDuration: minimumSplashDuration,
            child: const SessionGate(),
          ),
        );
      },
    );
  }
}

/// Owns the persistent player [OverlayEntry] for exactly as long as its
/// [Overlay] exists.
///
/// Keeping the entry inside a prebuilt AnimatedBuilder child allowed Flutter
/// to briefly reuse it while rebuilding the root for a different TV density.
/// A 4K viewport change could then try to mount one entry in two overlays.
class _PlayerOverlayLayer extends StatefulWidget {
  const _PlayerOverlayLayer();

  @override
  State<_PlayerOverlayLayer> createState() => _PlayerOverlayLayerState();
}

class _PlayerOverlayLayerState extends State<_PlayerOverlayLayer> {
  late final OverlayEntry _entry;

  @override
  void initState() {
    super.initState();
    _entry = OverlayEntry(
      maintainState: true,
      opaque: false,
      builder: (_) => PlayerHost.overlay(),
    );
  }

  @override
  void dispose() {
    if (_entry.mounted) _entry.remove();
    _entry.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Material(
      type: MaterialType.transparency,
      child: Overlay(initialEntries: [_entry]),
    );
  }
}

/// Publishes the semantic palette below MaterialApp's MediaQuery.
///
/// Keeping this as a widget makes System brightness changes observable and
/// regression-testable. Resolving above MaterialApp has no MediaQuery and can
/// leave palette-backed cards on the previous brightness.
class LumenPaletteScope extends StatelessWidget {
  const LumenPaletteScope({super.key, required this.mode, required this.child});

  final ThemeMode mode;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    resolvePalette(mode, MediaQuery.platformBrightnessOf(context));
    return child;
  }
}

/// Decides login vs main shell based on stored credentials.
typedef ProfileStateActivator =
    Future<void> Function(XtreamCredentials? credentials);

class CatalogLoadingScreen extends StatelessWidget {
  const CatalogLoadingScreen({
    super.key,
    required this.progress,
    required this.onRetry,
    this.error,
  });

  final CatalogPreloadProgress progress;
  final String? error;
  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) {
    final percent = (progress.percent.clamp(0.0, 1.0) * 100).round();
    final failed = error != null;
    return Scaffold(
      backgroundColor: Colors.black,
      body: SafeArea(
        child: Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 620),
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 28, vertical: 32),
              child: Container(
                padding: const EdgeInsets.fromLTRB(28, 30, 28, 28),
                decoration: BoxDecoration(
                  color: const Color(0xE6111517),
                  borderRadius: BorderRadius.circular(24),
                  border: Border.all(color: Colors.white24),
                ),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Icon(
                      failed
                          ? Icons.error_outline_rounded
                          : Icons.library_music_outlined,
                      color: Colors.white,
                      size: 46,
                    ),
                    const SizedBox(height: 22),
                    Text(
                      failed ? 'Playlist loading failed' : 'Loading your playlist',
                      textAlign: TextAlign.center,
                      style: const TextStyle(
                        color: Colors.white,
                        fontSize: 26,
                        fontWeight: FontWeight.w800,
                        letterSpacing: -0.5,
                      ),
                    ),
                    const SizedBox(height: 8),
                    Text(
                      failed ? error! : progress.stage,
                      textAlign: TextAlign.center,
                      style: const TextStyle(
                        color: Colors.white70,
                        fontSize: 14,
                        height: 1.45,
                      ),
                    ),
                    const SizedBox(height: 24),
                    if (!failed) ...[
                      Row(
                        children: [
                          Expanded(
                            child: ClipRRect(
                              borderRadius: BorderRadius.circular(99),
                              child: LinearProgressIndicator(
                                value: progress.percent.clamp(0.0, 1.0).toDouble(),
                                minHeight: 8,
                                color: Colors.white,
                                backgroundColor: Colors.white12,
                              ),
                            ),
                          ),
                          const SizedBox(width: 14),
                          Text(
                            '$percent%',
                            style: const TextStyle(
                              color: Colors.white,
                              fontSize: 16,
                              fontWeight: FontWeight.w800,
                            ),
                          ),
                        ],
                      ),
                      const SizedBox(height: 24),
                      Row(
                        children: [
                          Expanded(
                            child: _CatalogCount(
                              label: 'MOVIES',
                              value: progress.movies,
                            ),
                          ),
                          const SizedBox(width: 10),
                          Expanded(
                            child: _CatalogCount(
                              label: 'SHOWS',
                              value: progress.series,
                            ),
                          ),
                          const SizedBox(width: 10),
                          Expanded(
                            child: _CatalogCount(
                              label: 'TV CHANNELS',
                              value: progress.live,
                            ),
                          ),
                        ],
                      ),
                    ] else ...[
                      const SizedBox(height: 8),
                      const Icon(
                        Icons.refresh_rounded,
                        color: Colors.white54,
                        size: 34,
                      ),
                    ],
                    const SizedBox(height: 26),
                    Container(
                      padding: const EdgeInsets.all(14),
                      decoration: BoxDecoration(
                        color: Colors.white.withValues(alpha: 0.07),
                        borderRadius: BorderRadius.circular(14),
                        border: Border.all(color: Colors.white12),
                      ),
                      child: const Row(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Icon(
                            Icons.warning_amber_rounded,
                            color: Colors.white,
                            size: 20,
                          ),
                          SizedBox(width: 10),
                          Expanded(
                            child: Text(
                              'Caution: while loading your playlist, do not switch or close EliteStocks One.',
                              style: TextStyle(
                                color: Colors.white70,
                                fontSize: 12.5,
                                height: 1.45,
                              ),
                            ),
                          ),
                        ],
                      ),
                    ),
                    if (failed) ...[
                      const SizedBox(height: 18),
                      OutlinedButton.icon(
                        onPressed: onRetry,
                        style: OutlinedButton.styleFrom(
                          foregroundColor: Colors.white,
                          backgroundColor: Colors.white.withValues(alpha: 0.08),
                          side: const BorderSide(color: Colors.white38),
                          padding: const EdgeInsets.symmetric(vertical: 14),
                        ),
                        icon: const Icon(Icons.refresh_rounded),
                        label: const Text(
                          'Retry loading',
                          style: TextStyle(fontWeight: FontWeight.w700),
                        ),
                      ),
                    ],
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _CatalogCount extends StatelessWidget {
  const _CatalogCount({required this.label, required this.value});

  final String label;
  final int value;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(vertical: 13, horizontal: 8),
      decoration: BoxDecoration(
        color: Colors.white.withValues(alpha: 0.055),
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: Colors.white12),
      ),
      child: Column(
        children: [
          Text(
            value.toString(),
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: const TextStyle(
              color: Colors.white,
              fontSize: 19,
              fontWeight: FontWeight.w800,
            ),
          ),
          const SizedBox(height: 4),
          Text(
            label,
            textAlign: TextAlign.center,
            style: const TextStyle(
              color: Colors.white54,
              fontSize: 9.5,
              fontWeight: FontWeight.w700,
              letterSpacing: 0.8,
            ),
          ),
        ],
      ),
    );
  }
}

class SessionGate extends StatefulWidget {
  final ProfileStateActivator? profileActivator;

  const SessionGate({super.key, this.profileActivator});

  @override
  State<SessionGate> createState() => _SessionGateState();
}

class _SessionGateState extends State<SessionGate> {
  XtreamCredentials? _creds;
  List<XtreamCredentials> _viewerProfiles = const [];
  bool _legalAccepted = false;
  bool _loading = true;
  bool _selectingViewer = false;
  String _loadingLabel = 'RESTORING YOUR SESSION';
  int _sessionChange = 0;
  bool _exitDialogOpen = false;
  CatalogPreloadProgress? _catalogProgress;
  String? _catalogLoadError;
  Timer? _catalogRefreshTimer;
  bool _catalogRefreshInFlight = false;
  late final AppLifecycleListener _catalogLifecycle;

  @override
  void initState() {
    super.initState();
    _catalogLifecycle = AppLifecycleListener(onResume: _checkCatalogRefreshDue);
    _bootstrap();
  }

  Future<void> _bootstrap() async {
    final values = await Future.wait<dynamic>([
      Store.active(),
      LegalAcceptance.isAccepted(),
      ThemeController.instance.load(),
      PlaybackModeController.instance.load(),
      ViewingProfiles.instance.load(),
    ]);
    final credentials = values[0] as XtreamCredentials?;
    final viewerProfiles = credentials == null
        ? <XtreamCredentials>[]
        : await Store.viewerProfiles(credentials);
    final legalAccepted = values[1] as bool;

    if (!mounted) return;
    setState(() {
      _creds = credentials;
      _viewerProfiles = viewerProfiles;
      _legalAccepted = legalAccepted;
      _loading = credentials != null;
      _loadingLabel = credentials == null
          ? 'RESTORING YOUR SESSION'
          : 'LOADING YOUR LIBRARY';
      _selectingViewer = false;
      _catalogProgress = credentials == null
          ? null
          : const CatalogPreloadProgress(
              stage: 'Preparing your library',
              percent: 0,
              movies: 0,
              series: 0,
              live: 0,
            );
      _catalogLoadError = null;
    });

    AppDiagnostics.instance.record(
      'Session',
      credentials == null
          ? 'Restored signed-out session'
          : 'Restored ' + AppDiagnostics.sourceLabel(credentials) + ' session',
    );

    if (credentials == null) {
      if (mounted) setState(() => _loading = false);
      return;
    }

    await _activateProfileState(credentials);
    if (!mounted || _creds != credentials) return;

    final client = _client ??= viewerProfiles.length > 1
        ? MultiSourceXtreamClient(credentials, viewerProfiles)
        : XtreamClient(credentials);
    activeClient = client;

    final complete = await CatalogCache.instance.hasCompletedInitialLoad(client);
    if (!complete) {
      final loaded = await _loadCatalogBeforeEntering(client);
      if (!mounted || _creds != credentials || !loaded) return;
    } else {
      setState(() {
        _loading = false;
        _loadingLabel = 'RESTORING YOUR SESSION';
        _catalogProgress = null;
      });
      await _scheduleCatalogRefresh(client);
    }

    if (!mounted || _creds != credentials) return;
    final profiles = await Store.viewerProfiles(credentials);
    if (mounted && !_sameViewerProfiles(_viewerProfiles, profiles)) {
      setState(() => _viewerProfiles = profiles);
    }
  }

  Future<bool> _loadCatalogBeforeEntering(XtreamClient client) async {
    if (!mounted) return false;
    setState(() {
      _loading = true;
      _loadingLabel = 'LOADING YOUR LIBRARY';
      _catalogLoadError = null;
    });
    try {
      await CatalogCache.instance.preloadAll(
        client,
        onProgress: (progress) {
          if (!mounted) return;
          setState(() => _catalogProgress = progress);
        },
      );
      if (!mounted) return true;
      setState(() {
        _loading = false;
        _loadingLabel = 'RESTORING YOUR SESSION';
        _catalogLoadError = null;
        _catalogProgress = null;
      });
      await _scheduleCatalogRefresh(client);
      return true;
    } catch (error, stack) {
      AppDiagnostics.instance.record(
        'Catalog',
        'Initial catalog preload failed (' + error.runtimeType.toString() + ')',
      );
      debugPrint(
        'Initial catalog preload failed: ' + error.toString() + '\n' + stack.toString(),
      );
      if (mounted) {
        setState(() {
          _loading = true;
          _catalogLoadError =
              'We could not finish loading the playlist. Check the connection and try again.';
        });
      }
      return false;
    }
  }

  Future<void> _retryCatalogLoad() async {
    final credentials = _creds;
    if (credentials == null) return;
    final client = _client ??= _viewerProfiles.length > 1
        ? MultiSourceXtreamClient(credentials, _viewerProfiles)
        : XtreamClient(credentials);
    activeClient = client;
    await _loadCatalogBeforeEntering(client);
  }

  Future<void> _scheduleCatalogRefresh(XtreamClient client) async {
    _catalogRefreshTimer?.cancel();
    final last = await CatalogCache.instance.lastCompletedLoad(client);
    final elapsed = last == null
        ? CatalogCache.defaultRefreshInterval
        : DateTime.now().difference(last);
    final delay = elapsed >= CatalogCache.defaultRefreshInterval
        ? Duration.zero
        : CatalogCache.defaultRefreshInterval - elapsed;
    _catalogRefreshTimer = Timer(delay, () async {
      if (!mounted || !identical(_client, client) || _creds == null) return;
      if (_catalogRefreshInFlight) return;
      _catalogRefreshInFlight = true;
      try {
        await CatalogCache.instance.preloadAll(client, onProgress: (_) {});
      } catch (error, stack) {
        AppDiagnostics.instance.record(
          'Catalog',
          '12-hour background refresh failed (' +
              error.runtimeType.toString() +
              ')',
        );
        debugPrint(
          '12-hour catalog refresh failed: ' + error.toString() + '\n' + stack.toString(),
        );
      } finally {
        _catalogRefreshInFlight = false;
        if (mounted && identical(_client, client) && _creds != null) {
          await _scheduleCatalogRefresh(client);
        }
      }
    });
  }

  Future<void> _checkCatalogRefreshDue() async {
    final client = _client;
    if (client == null || _creds == null || _loading) return;
    final last = await CatalogCache.instance.lastCompletedLoad(client);
    if (last == null ||
        DateTime.now().difference(last) >= CatalogCache.defaultRefreshInterval) {
      if (!_catalogRefreshInFlight) {
        _catalogRefreshInFlight = true;
        try {
          await CatalogCache.instance.preloadAll(client, onProgress: (_) {});
        } catch (_) {
          // Keep the last good catalog if a background refresh fails.
        } finally {
          _catalogRefreshInFlight = false;
          if (mounted && identical(_client, client)) {
            await _scheduleCatalogRefresh(client);
          }
        }
      }
    }
  }

  Future<void> _acceptLegal() async {
    await LegalAcceptance.accept();
    if (mounted) setState(() => _legalAccepted = true);
  }

  XtreamClient? _client; // cached so theme rebuilds don't recreate it

  Future<void> _activateProfileState(XtreamCredentials? credentials) {
    final override = widget.profileActivator;
    if (override != null) return override(credentials);
    return Future.wait([
      _activateViewingState(credentials),
      Downloads.instance.activate(credentials),
    ]);
  }

  Future<void> _activateViewingState(XtreamCredentials? credentials) {
    final viewingId = ViewingProfiles.instance.activeId;
    return Future.wait([
      Library.instance.activate(credentials, viewingId: viewingId),
      HomeConfig.instance.activate(credentials, viewingId: viewingId),
      WatchStats.instance.activate(credentials, viewingId: viewingId),
    ]);
  }

  Future<void> _selectViewer(String id) async {
    final credentials = _creds;
    if (credentials == null) return;
    final change = ++_sessionChange;
    _guardSessionStep('playback', PlaybackController.instance.stop);
    await SplitController.instance.close();
    await ViewingProfiles.instance.select(id);
    if (!mounted || change != _sessionChange) return;
    await _guardProfileState(_activateViewingState(credentials));
    if (mounted && change == _sessionChange) {
      setState(() => _selectingViewer = false);
    }
  }

  Future<void> _guardProfileState(Future<void> activation) async {
    try {
      await activation;
    } catch (error, stack) {
      AppDiagnostics.instance.record(
        'Session',
        'Profile state hydration failed (${error.runtimeType})',
      );
      debugPrint('Profile state hydration failed: $error\n$stack');
    }
  }

  /// Make these credentials active: stop account-bound work, atomically switch
  /// persisted state, then rebuild with a fresh client and catalog namespace.
  Future<void> _activate(XtreamCredentials? credentials) async {
    ++_sessionChange;
    final previousClient = _client;

    // Commit the authenticated session first. Cleanup and profile hydration
    // must never be able to strand a successfully saved account on Login.
    if (!mounted) return;
    setState(() {
      _creds = credentials;
      _viewerProfiles = credentials == null ? const [] : [credentials];
      _client = null;
      _loading = credentials != null;
      _loadingLabel = credentials == null ? 'RESTORING YOUR SESSION' : 'OPENING YOUR LIBRARY';
      _selectingViewer = false;
    });
    AppDiagnostics.instance.record(
      'Session',
      credentials == null
          ? 'Activated signed-out state'
          : 'Activated ${AppDiagnostics.sourceLabel(credentials)}',
    );

    _guardSessionStep('previous client', () => previousClient?.close());
    activeClient = null;
    _guardSessionStep('playback', PlaybackController.instance.stop);
    unawaited(_guardProfileState(SplitController.instance.close()));
    _guardSessionStep('catalog cache', CatalogCache.instance.clear);

    // Hydrate profile-scoped library/download state before exposing Home.
    // This removes the first-login race where utility pages and Continue
    // Watching were mounted before their account state was ready.
    try {
      await _activateProfileState(credentials);
    } catch (error, stack) {
      AppDiagnostics.instance.record(
        'Session',
        'Profile activation failed (' + error.runtimeType.toString() + ')',
      );
      debugPrint(
        'Profile activation failed: ' + error.toString() + '\\n' + stack.toString(),
      );
    }
    if (!mounted || credentials == null) return;
    if (_creds != credentials) return;

    final client = XtreamClient(credentials);
    _client = client;
    activeClient = client;
    if (!await _loadCatalogBeforeEntering(client)) return;
    // The active client is already valid for this login. Re-read saved viewer
    // profiles only to discover additional services; do not recreate the client
    // when the profile list is unchanged, because Home is already mounted.
    unawaited(_reloadViewerProfiles(credentials, _sessionChange));
  }

  bool _sameCredential(XtreamCredentials a, XtreamCredentials b) =>
      a.baseUrl == b.baseUrl &&
      a.username == b.username &&
      a.password == b.password &&
      a.m3uUrl == b.m3uUrl &&
      a.demo == b.demo;

  bool _sameViewerProfiles(
    List<XtreamCredentials> a,
    List<XtreamCredentials> b,
  ) {
    if (a.length != b.length) return false;
    for (var i = 0; i < a.length; i++) {
      if (!_sameCredential(a[i], b[i])) return false;
    }
    return true;
  }

  Future<void> _reloadViewerProfiles(
    XtreamCredentials credentials,
    int change,
  ) async {
    final profiles = await Store.viewerProfiles(credentials);
    if (!mounted || change != _sessionChange || _creds == null) return;

    // During first login, _activate() has already hydrated the active account
    // and mounted Home. If the stored viewer list is the same account we just
    // opened, keep the existing client and shell state alive. Recreating the
    // client here used to clear CatalogCache immediately after Home started,
    // leaving the first-login Home stuck on its loading state until restart.
    if (_sameViewerProfiles(_viewerProfiles, profiles)) return;

    final previousClient = _client;
    setState(() {
      _viewerProfiles = profiles;
      _client = null;
    });
    _guardSessionStep('previous service viewer', () => previousClient?.close());
    CatalogCache.instance.clear();
  }

  Future<void> _onServicesChanged() async {
    final credentials = _creds;
    if (credentials == null) return;
    await _reloadViewerProfiles(credentials, _sessionChange);
  }

  void _guardSessionStep(String label, void Function() action) {
    try {
      action();
    } catch (error, stack) {
      AppDiagnostics.instance.record(
        'Session',
        '$label cleanup failed (${error.runtimeType})',
      );
      debugPrint('Session $label cleanup failed: $error\n$stack');
    }
  }

  Future<void> _onLogin(XtreamCredentials c) async {
    AppDiagnostics.instance.record(
      'Session',
      'Login completed (${AppDiagnostics.sourceLabel(c)})',
    );
    await _activate(c);
  }

  Future<void> _switchTo(XtreamCredentials c) async {
    await Store.setActive(c);
    AppDiagnostics.instance.record(
      'Session',
      'Profile switched (${AppDiagnostics.sourceLabel(c)})',
    );
    if (mounted) await _activate(c);
  }

  Future<void> _onLogout() async {
    AppDiagnostics.instance.record('Session', 'Sign-out started');
    final change = ++_sessionChange;
    final previousClient = _client;
    if (mounted) {
      setState(() {
        _loading = true;
        _loadingLabel = 'SIGNING OUT SECURELY';
      });
    }
    try {
      await Store.logout().timeout(const Duration(seconds: 6));
    } catch (error) {
      AppDiagnostics.instance.record(
        'Session',
        'Sign-out failed (${error.runtimeType})',
      );
      if (mounted && change == _sessionChange) {
        setState(() => _loading = false);
      }
      rethrow;
    }

    if (!mounted || change != _sessionChange) return;

    // The persisted signed-out marker is now authoritative. Commit the visible
    // session transition before any player, cache, or profile cleanup. Those
    // operations are deliberately best-effort so one slow plugin cannot leave
    // the user staring at an endless loader even though logout succeeded.
    setState(() {
      _creds = null;
      _viewerProfiles = const [];
      _client = null;
      _loading = false;
      _loadingLabel = 'RESTORING YOUR SESSION';
      _selectingViewer = false;
    });
    AppDiagnostics.instance.record('Session', 'Sign-out completed');
    activeClient = null;

    WidgetsBinding.instance.addPostFrameCallback((_) {
      _guardSessionStep('previous client', () => previousClient?.close());
      _guardSessionStep('playback', PlaybackController.instance.stop);
      unawaited(_guardProfileState(SplitController.instance.close()));
      _guardSessionStep('catalog cache', CatalogCache.instance.clear);
      unawaited(
        _guardProfileState(
          Future<void>.sync(() => _activateProfileState(null)),
        ),
      );
    });
  }

  @override
  void dispose() {
    _catalogRefreshTimer?.cancel();
    _catalogLifecycle.dispose();
    _client?.close();
    if (identical(activeClient, _client)) activeClient = null;
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    // Set the active palette and build the screens in ONE builder, below the
    // Navigator route — so a theme change rebuilds this subtree and the new
    // palette is published immediately before the screens read it.
    return ValueListenableBuilder<ThemeMode>(
      valueListenable: ThemeController.instance.mode,
      builder: (context, mode, _) {
        resolvePalette(mode, MediaQuery.platformBrightnessOf(context));
        if (_loading) {
          return PopScope(
            canPop: false,
            child: _catalogProgress != null
                ? CatalogLoadingScreen(
                    progress: _catalogProgress!,
                    error: _catalogLoadError,
                    onRetry: _retryCatalogLoad,
                  )
                : SessionLoading(message: _loadingLabel),
          );
        }
        if (!_legalAccepted) {
          return _rootExitGuard(LegalWelcomeScreen(onAccepted: _acceptLegal));
        }
        if (_creds == null) {
          return _rootExitGuard(LoginScreen(onLogin: _onLogin));
        }
        if (_selectingViewer) {
          return _rootExitGuard(ViewerPickerScreen(onSelect: _selectViewer));
        }
        _client ??= _viewerProfiles.length > 1
            ? MultiSourceXtreamClient(_creds!, _viewerProfiles)
            : XtreamClient(_creds!);
        activeClient = _client; // expose to the app-level player (split picker)
        // Key by the active profile so switching fully remounts all tabs with
        // the new client (fresh catalogs), not stale data from the old account.
        return HomeShell(
          key: ValueKey(
            '${Store.profileScope(_creds!)}:${ViewingProfiles.instance.activeId}',
          ),
          client: _client!,
          onLogout: _onLogout,
          onSwitch: _switchTo,
          onServicesChanged: _onServicesChanged,
          onViewerChanged: _selectViewer,
        );
      },
    );
  }

  Widget _rootExitGuard(Widget child) => PopScope(
    canPop: false,
    onPopInvokedWithResult: (didPop, _) {
      if (!didPop) unawaited(_requestRootExit());
    },
    child: child,
  );

  Future<void> _requestRootExit() async {
    if (_exitDialogOpen || !mounted) return;
    _exitDialogOpen = true;
    final shouldExit = await showHomeExitConfirmation(context);
    _exitDialogOpen = false;
    if (shouldExit && mounted) await SystemNavigator.pop();
  }
}
