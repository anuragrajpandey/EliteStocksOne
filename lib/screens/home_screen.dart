import 'package:flutter/material.dart';
import 'package:flutter_animate/flutter_animate.dart';
import 'package:flutter/services.dart';
import 'dart:async';
import 'dart:math' as math;
import '../catalog_cache.dart';
import '../device_profile.dart';
import '../focus_return.dart';
import '../library.dart';
import '../models.dart';
import '../playback.dart';
import '../refresh.dart';
import '../responsive.dart';
import '../theme.dart';
import '../tmdb.dart';
import '../widgets.dart';
import '../xtream.dart';
import 'movie_detail_screen.dart';
import 'series_detail_screen.dart';

String _year(String s) => RegExp(r'(19|20)\d{2}').firstMatch(s)?.group(0) ?? '';
String _titleKey(String value) => value
    .toLowerCase()
    .replaceAll(RegExp(r'[^a-z0-9]+'), ' ')
    .trim();

/// Picks the provider's best English-film bucket for the Home spotlight.
/// Xtream category names are provider-defined, so prefer an explicit
/// "English movies" label, then a recent non-CAM English/FHD bucket, and use
/// Hollywood only as a final synonym.
Category? preferredEnglishMovieCategory(Iterable<Category> categories) {
  Category? best;
  var bestScore = 0;
  for (final category in categories) {
    final name = category.name.toLowerCase().replaceAll(
      RegExp(r'[^a-z0-9]+'),
      ' ',
    );
    final padded = ' $name ';
    final isEnglish = padded.contains(' english ');
    final isHollywood = padded.contains(' hollywood ');
    if (!isEnglish && !isHollywood) continue;
    if (padded.contains(' cam ') ||
        padded.contains(' trailer ') ||
        padded.contains(' series ') ||
        padded.contains(' tv show ')) {
      continue;
    }

    var score = isEnglish ? 700 : 400;
    if (name.trim() == 'english movies') {
      score += 1000;
    } else if (name.contains('english movies')) {
      score += 800;
    }
    if (padded.contains(' fhd ')) score += 30;
    if (padded.contains(' 4k ') || padded.contains(' uhd ')) score += 20;
    final years = RegExp(r'\b(20\d{2})\b').allMatches(name);
    for (final match in years) {
      score += (int.tryParse(match.group(1) ?? '') ?? 2000) - 2000;
    }
    if (score > bestScore) {
      best = category;
      bestScore = score;
    }
  }
  return best;
}

/// Strip provider filename cruft from a title — year, quality tags, dots — so
/// the hero shows a clean name (e.g. "Soul (2020).(4K)" → "Soul").
String _clean(String s) {
  var t = s;
  t = t.replaceAll(RegExp(r'\((?:19|20)\d{2}\)'), ''); // (2020)
  t = t.replaceAll(
    RegExp(
      r'\b(?:4K|UHD|FHD|HD|SD|HQ|1080p|720p|2160p|HEVC|x26[45]|DV|HDR)\b',
      caseSensitive: false,
    ),
    '',
  );
  t = t.replaceAll(RegExp(r'[._]+'), ' '); // dots/underscores → space
  t = t.replaceAll(
    RegExp(r'\(\s*\)|\[\s*\]'),
    '',
  ); // empty brackets left behind
  t = t.replaceAll(RegExp(r'\s{2,}'), ' ').trim();
  t = t.replaceAll(RegExp(r'[-|·•:]\s*$'), '').trim(); // trailing separators
  return t.isEmpty ? s : t;
}


const _mobileCuratedShelfTitles = <String>[
  'Trending Now',
  'What\'s Hot',
  'Must Watch',
  'Popular Picks',
  'New & Noteworthy',
  'Fan Favorites',
  'Critics\' Choice',
  'Late Night Picks',
  'Fresh Releases',
  'Editor\'s Picks',
];

class _MobileCategorySource {
  const _MobileCategorySource({
    required this.category,
    required this.isSeries,
  });

  final Category category;
  final bool isSeries;

  String get key => '${isSeries ? 'series' : 'movie'}:${category.id}';
}

class _MobileCuratedShelf {
  const _MobileCuratedShelf({required this.title, required this.future});
  final String title;
  final Future<List<_MobileFeature>> future;
}

class HomeScreen extends StatefulWidget {
  final XtreamClient client;
  final VoidCallback onBrowse;
  final FocusNode? entryFocusNode;

  /// Test seam for exercising refresh transitions without opening the
  /// persistent catalog database. Production callers always use the shared
  /// cached provider loader below.
  final Future<List<Category>> Function()? categoryLoader;

  const HomeScreen({
    super.key,
    required this.client,
    required this.onBrowse,
    this.entryFocusNode,
    this.categoryLoader,
  });
  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen>
    with AutomaticKeepAliveClientMixin {
  late Future<_HomeData> _future;
  _HomeData? _visibleData;
  int _loadGeneration = 0;
  bool _coldRetryUsed = false;
  Timer? _hourlyHomeRefreshTimer;
  Timer? _dailyShelfRefreshTimer;
  final Map<String, FocusNode> _continueFocus = <String, FocusNode>{};
  final Map<String, FocusNode> _channelFocus = <String, FocusNode>{};

  // Futures are owned by screen state, not created during build. This keeps
  // scroll/rebuild cycles from restarting catalog requests.
  Future<List<_MobileFeature>> _mobileHeroFuture =
      Future.value(const <_MobileFeature>[]);
  List<_MobileCuratedShelf> _mobileCuratedShelves =
      const <_MobileCuratedShelf>[];

  @override
  bool get wantKeepAlive => true;

  @override
  void initState() {
    super.initState();
    // Start the TV hero independently of the full Home catalog. The old Home
    // future waited for both movie and series category lists, so a slow movie
    // endpoint could keep the first-login hero blank even though series data
    // was already available.
    _mobileHeroFuture = _bootstrapMobileHero();
    _beginLoad();
    // The large hero is intentionally refreshed every hour.
    _hourlyHomeRefreshTimer = Timer.periodic(
      const Duration(hours: 1),
      (_) {
        if (mounted) refreshContent();
      },
    );
    // The ten Home shelves use a slower playlist refresh cadence. This keeps
    // their provider-backed categories stable during the day while allowing
    // the playlist to rotate once every 24 hours.
    _dailyShelfRefreshTimer = Timer.periodic(
      const Duration(hours: 24),
      (_) => _refreshMobileShelvesFromPlaylist(),
    );
    contentRefresh.addListener(_onRefresh);
  }

  @override
  void dispose() {
    _hourlyHomeRefreshTimer?.cancel();
    _dailyShelfRefreshTimer?.cancel();
    contentRefresh.removeListener(_onRefresh);
    for (final node in [..._continueFocus.values, ..._channelFocus.values]) {
      node.dispose();
    }
    super.dispose();
  }

  void _onRefresh() {
    if (!mounted) return;
    // Keep the currently rendered catalogs in place while fresh data arrives.
    // Pull-to-refresh should feel like an in-place update, not a cold launch.
    setState(_beginLoad);
  }

  Future<void> _pullRefresh() async {
    refreshContent(); // clears caches + bumps the notifier (reloads _future)
    await _future;
  }

  Future<_HomeData> _loadHome() async {
    final categoryLoader = widget.categoryLoader;
    if (categoryLoader != null) {
      return _HomeData(await categoryLoader(), const <Category>[]);
    }
    // Plain M3U profiles are live-only. Do not spend multiple retry windows on
    // movie/series endpoints they can never have before showing their channels.
    if (!widget.client.supportsMovieCatalog &&
        !widget.client.supportsSeriesCatalog) {
      return _HomeData(const [], const []);
    }
    final results = await Future.wait([
      widget.client.supportsMovieCatalog
          ? CatalogCache.instance.vod(widget.client, priority: true)
          : Future.value(const <Category>[]),
      widget.client.supportsSeriesCatalog
          ? CatalogCache.instance.series(widget.client, priority: true)
          : Future.value(const <Category>[]),
    ]);
    return _HomeData(results[0], results[1]);
  }

  void _beginLoad() {
    final generation = ++_loadGeneration;
    _future = _loadHome().then((data) {
      if (mounted && generation == _loadGeneration) {
        _visibleData = data;
        _prepareMobileShelves(data);
        // A first-login race can leave the catalog store empty after the
        // provider session has just been created. One bounded retry clears
        // that cold cache and retries once without creating a refresh loop.
        if (!_coldRetryUsed &&
            widget.categoryLoader == null &&
            data.vodCats.isEmpty &&
            data.seriesCats.isEmpty) {
          _coldRetryUsed = true;
          Future<void>.delayed(const Duration(milliseconds: 700), () {
            if (mounted) refreshContent();
          });
        }
      }
      return data;
    });
  }

  Future<void> _push(Widget w) async {
    await pushWithFocusReturn(context, w);
  }

  Future<List<_MobileFeature>> _bootstrapMobileHero() async {
    try {
      if (!widget.client.supportsSeriesCatalog) {
        return const <_MobileFeature>[];
      }
      final categories = await CatalogCache.instance.series(
        widget.client,
        priority: true,
      );
      final sources = _selectMobileCategories(
        _HomeData(const <Category>[], categories),
      );
      return _mobileHeroItems(widget.client, sources);
    } catch (_) {
      return const <_MobileFeature>[];
    }
  }

  Widget _mobileHeroWidget(XtreamClient client) => _MobileHomeSpotlight(
    future: _mobileHeroFuture,
    onMoviePlay: (m) {
      final ext = m.containerExtension.isEmpty ? 'mp4' : m.containerExtension;
      PlaybackController.instance.open([
        PlayerItem(
          client.streamUrl('movie', m.streamId, ext: ext),
          _clean(m.name),
          progressKey: 'movie:' + m.streamId.toString(),
          poster: m.icon,
          ext: ext,
        ),
      ], 0);
    },
    onSeriesOpen: (series) => _push(
      SeriesDetailScreen(
        client: client,
        seriesId: series.seriesId,
        title: series.name,
        preview: series,
      ),
    ),
  );

  FocusNode _continueNode(String key) => _continueFocus.putIfAbsent(
    key,
    () => FocusNode(debugLabel: 'Continue watching $key'),
  );

  FocusNode _channelNode(String key) => _channelFocus.putIfAbsent(
    key,
    () => FocusNode(debugLabel: 'Recent channel $key'),
  );

  void _openProgress(Progress progress) {
    PlaybackController.instance.open([
      PlayerItem(
        progress.url,
        progress.title,
        progressKey: progress.key,
        poster: progress.poster,
        ext: progress.ext,
      ),
    ], 0);
  }

  void _openRecentChannel(MediaRef channel) {
    PlaybackController.instance.open([
      PlayerItem(
        channel.url,
        channel.name,
        isLive: true,
        poster: channel.image,
        httpHeaders: widget.client.streamHeaders(channel.id),
        favRef: channel,
      ),
    ], 0);
  }

  Future<void> _showContinueActions(Progress progress) async {
    final action = await showDialog<_ContinueAction>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: Text(
          progress.title,
          maxLines: 2,
          overflow: TextOverflow.ellipsis,
        ),
        contentPadding: const EdgeInsets.fromLTRB(18, 12, 18, 18),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            _HistoryDialogOption(
              autofocus: true,
              icon: Icons.play_arrow_rounded,
              label: 'Resume',
              onTap: () => Navigator.pop(dialogContext, _ContinueAction.resume),
            ),
            _HistoryDialogOption(
              icon: Icons.replay_rounded,
              label: 'Start from beginning',
              onTap: () =>
                  Navigator.pop(dialogContext, _ContinueAction.restart),
            ),
            _HistoryDialogOption(
              icon: Icons.check_circle_outline_rounded,
              label: 'Mark as watched',
              onTap: () =>
                  Navigator.pop(dialogContext, _ContinueAction.watched),
            ),
            _HistoryDialogOption(
              icon: Icons.remove_circle_outline_rounded,
              label: 'Remove from row',
              onTap: () => Navigator.pop(dialogContext, _ContinueAction.remove),
            ),
          ],
        ),
      ),
    );
    if (!mounted || action == null) return;
    switch (action) {
      case _ContinueAction.resume:
        _openProgress(progress);
      case _ContinueAction.restart:
        Library.instance.clearProgress(progress.key);
        _openProgress(progress);
      case _ContinueAction.watched:
        Library.instance.markWatched(progress.key);
      case _ContinueAction.remove:
        Library.instance.clearProgress(progress.key);
    }
  }

  Future<void> _showChannelActions(MediaRef channel) async {
    final remove = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: Text(channel.name, maxLines: 2, overflow: TextOverflow.ellipsis),
        contentPadding: const EdgeInsets.fromLTRB(18, 12, 18, 18),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            _HistoryDialogOption(
              autofocus: true,
              icon: Icons.play_arrow_rounded,
              label: 'Watch live',
              onTap: () => Navigator.pop(dialogContext, false),
            ),
            _HistoryDialogOption(
              icon: Icons.remove_circle_outline_rounded,
              label: 'Remove from recent channels',
              onTap: () => Navigator.pop(dialogContext, true),
            ),
          ],
        ),
      ),
    );
    if (!mounted || remove == null) return;
    if (remove) {
      Library.instance.removeRecent(channel.key);
    } else {
      _openRecentChannel(channel);
    }
  }

  Widget _historyRows() {
    final continuing = Library.instance.continueWatching();
    final channels = Library.instance.recent
        .where((item) => item.isLive && item.url.isNotEmpty)
        .take(16)
        .toList();
    if (continuing.isEmpty && channels.isEmpty) {
      return const SizedBox.shrink();
    }
    final cardWidth = DeviceProfile.isTelevision ? 310.0 : 260.0;
    final cardHeight = DeviceProfile.isTelevision ? 112.0 : 96.0;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        if (continuing.isNotEmpty) ...[
          const Padding(
            padding: EdgeInsets.only(top: 24),
            child: SectionHeader(title: 'Continue watching'),
          ),
          SizedBox(
            height: cardHeight + 16,
            child: HorizontalShelfViewport(
              key: const ValueKey('home-continue-watching-viewport'),
              child: ListView.separated(
                scrollDirection: Axis.horizontal,
                clipBehavior: Clip.none,
                padding: EdgeInsets.symmetric(
                  horizontal: DeviceProfile.isTelevision ? 28 : 20,
                  vertical: 8,
                ),
                itemCount: continuing.length,
                separatorBuilder: (_, _) =>
                    SizedBox(width: DeviceProfile.isTelevision ? 16 : 14),
                itemBuilder: (_, i) => _ContinueWatchingCard(
                  key: ValueKey(continuing[i].key),
                  progress: continuing[i],
                  index: i,
                  width: cardWidth,
                  height: cardHeight,
                  focusNode: _continueNode(continuing[i].key),
                  onTap: () => _openProgress(continuing[i]),
                  onLongPress: () => _showContinueActions(continuing[i]),
                ),
              ),
            ),
          ),
        ],
        if (channels.isNotEmpty) ...[
          const Padding(
            padding: EdgeInsets.only(top: 24),
            child: SectionHeader(title: 'Recent channels'),
          ),
          SizedBox(
            height: cardHeight + 16,
            child: HorizontalShelfViewport(
              key: const ValueKey('home-recent-channels-viewport'),
              child: ListView.separated(
                scrollDirection: Axis.horizontal,
                clipBehavior: Clip.none,
                padding: EdgeInsets.symmetric(
                  horizontal: DeviceProfile.isTelevision ? 28 : 20,
                  vertical: 8,
                ),
                itemCount: channels.length,
                separatorBuilder: (_, _) =>
                    SizedBox(width: DeviceProfile.isTelevision ? 16 : 14),
                itemBuilder: (_, i) => _RecentChannelCard(
                  key: ValueKey(channels[i].key),
                  item: channels[i],
                  index: i,
                  width: cardWidth,
                  height: cardHeight,
                  focusNode: _channelNode(channels[i].key),
                  onTap: () => _openRecentChannel(channels[i]),
                  onLongPress: () => _showChannelActions(channels[i]),
                ),
              ),
            ),
          ),
        ],
      ],
    );
  }

  @override
  Widget build(BuildContext context) {
    super.build(context);
    Theme.of(
      context,
    ); // Rebuild palette-backed cached Home content on mode changes.
    return FutureBuilder<_HomeData>(
      future: _future,
      initialData: _visibleData,
      builder: (context, snap) {
        if (!snap.hasData) {
          // Paint the mobile Home immediately. The full category snapshot can
          // still be loading in the background, while the independent series
          // hero already has a chance to populate on first login.
          if (!isWide(context)) {
            return RefreshIndicator(
              onRefresh: _pullRefresh,
              color: accentInk,
              child: ListView(
                physics: const AlwaysScrollableScrollPhysics(
                  parent: BouncingScrollPhysics(),
                ),
                padding: const EdgeInsets.only(bottom: 120),
                children: [
                  _searchBar(),
                  const SizedBox(height: 8),
                  _mobileHeroWidget(widget.client),
                ],
              ),
            );
          }
          return BrandedLoading();
        }
        if (snap.hasError && _visibleData == null) {
          return Center(
            child: Padding(
              padding: const EdgeInsets.all(24),
              child: Text(
                '${snap.error ?? "Couldn't load."}',
                textAlign: TextAlign.center,
                style: TextStyle(color: dangerInk),
              ),
            ),
          );
        }
        final d = snap.data!;
        final c = widget.client;
        final heroCat =
            preferredEnglishMovieCategory(d.vodCats)?.id ??
            (d.vodCats.isEmpty ? null : d.vodCats.first.id);
        final primarySource = heroCat == null
            ? Future.value(const <VodStream>[])
            : CatalogCache.instance
                  .vodStreams(c, heroCat, priority: true)
                  .catchError((_) => <VodStream>[]);
        final heroFuture = primarySource.then((items) {
          final ranked = moviesRecentlyAdded(
            items.where((m) => m.icon.isNotEmpty),
          );
          return ranked.take(8).toList();
        });
        final hero = _SpotlightHero(
          key: ValueKey('hero:$heroCat'),
          client: c,
          future: heroFuture,
          revision: _loadGeneration,
          onOpen: (m) => _push(MovieDetailScreen(client: c, movie: m)),
          entryFocusNode: widget.entryFocusNode,
        );
        final lastPlayed = AnimatedBuilder(
          animation: Library.instance,
          builder: (_, __) => _historyRows(),
        );

        if (isWide(context)) {
          return RefreshIndicator(
            onRefresh: _pullRefresh,
            color: accentInk,
            child: CustomScrollView(
              slivers: [
                SliverToBoxAdapter(child: hero),
                SliverToBoxAdapter(child: lastPlayed),
                const SliverToBoxAdapter(child: SizedBox(height: 80)),
              ],
            ),
          );
        }

        final shelfCount = 4 + _mobileCuratedShelves.length;

        return RefreshIndicator(
          onRefresh: _pullRefresh,
          color: accentInk,
          child: ListView.builder(
            key: const PageStorageKey<String>('mobile-home-scroll'),
            physics: const AlwaysScrollableScrollPhysics(
              parent: BouncingScrollPhysics(),
            ),
            padding: const EdgeInsets.only(bottom: 120),
            itemCount: shelfCount,
            itemBuilder: (context, index) {
              if (index == 0) {
                return Column(
                  children: [
                    _searchBar(),
                    const SizedBox(height: 8),
                  ],
                );
              }
              if (index == 1) {
                return _mobileHeroWidget(c);
              }
              if (index == 2) {
                return AnimatedBuilder(
                  animation: Library.instance,
                  builder: (_, __) => _mobileContinueWatching(),
                );
              }
              if (index == 3) {
                return AnimatedBuilder(
                  animation: Library.instance,
                  builder: (_, __) => _mobileContinueLiveTv(),
                );
              }

              final shelf = _mobileCuratedShelves[index - 4];
              return _MobileCuratedShelfLoader(
                key: ValueKey('mobile-curated-' + shelf.title),
                title: shelf.title,
                future: shelf.future,
                onTap: (item) {
                  final movie = item.movie;
                  if (movie != null) {
                    final ext = movie.containerExtension.isEmpty
                        ? 'mp4'
                        : movie.containerExtension;
                    PlaybackController.instance.open([
                      PlayerItem(
                        c.streamUrl('movie', movie.streamId, ext: ext),
                        _clean(movie.name),
                        progressKey: 'movie:' + movie.streamId.toString(),
                        poster: item.image,
                        ext: ext,
                      ),
                    ], 0);
                    return;
                  }
                  final series = item.series;
                  if (series != null) {
                    _push(
                      SeriesDetailScreen(
                        client: c,
                        seriesId: series.seriesId,
                        title: series.name,
                        preview: series,
                      ),
                    );
                  }
                },
              );
            },
          ),
        );
      },
    );
  }

  List<_MobileCategorySource> _selectMobileCategories(_HomeData data) {
    final sources = <_MobileCategorySource>[
      ...data.seriesCats.map(
        (category) => _MobileCategorySource(category: category, isSeries: true),
      ),
      ...data.vodCats.map(
        (category) => _MobileCategorySource(category: category, isSeries: false),
      ),
    ];

    // Prefer real provider buckets such as Netflix, Prime Video, Disney+,
    // HBO/Max, Sony, Hotstar, Apple TV+, Paramount, etc. Unknown provider
    // buckets remain valid fallbacks.
    const platformWords = <String>[
      'netflix',
      'prime',
      'amazon',
      'disney',
      'hotstar',
      'hbo',
      'max',
      'sony',
      'apple',
      'paramount',
      'peacock',
      'hulu',
      'zee',
      'jio',
      'lionsgate',
      'crunchyroll',
      'aha',
      'mx player',
      'voot',
    ];

    int score(_MobileCategorySource source) {
      final name = source.category.name.trim().toLowerCase();
      if (name.isEmpty) return -10000;
      if (name == 'all' || name == 'uncategorized' || name == 'other') {
        return -5000;
      }
      var value = 0;
      for (var i = 0; i < platformWords.length; i++) {
        if (name.contains(platformWords[i])) {
          value = math.max(value, 1000 - i * 20);
        }
      }
      if (name.contains('trailer') || name.contains('cam')) value -= 300;
      if (name.contains('4k') || name.contains('uhd')) value += 20;
      return value;
    }

    final ranked = [...sources]
      ..sort((a, b) {
        final byScore = score(b).compareTo(score(a));
        if (byScore != 0) return byScore;
        return a.category.name.toLowerCase().compareTo(
          b.category.name.toLowerCase(),
        );
      });

    String platformBucket(String name) {
      if (name.contains('netflix')) return 'netflix';
      if (name.contains('prime') || name.contains('amazon')) return 'amazon';
      if (name.contains('disney') || name.contains('hotstar')) return 'disney';
      if (name.contains('hbo') || name.contains('max')) return 'max';
      if (name.contains('sony')) return 'sony';
      if (name.contains('apple')) return 'apple';
      if (name.contains('paramount')) return 'paramount';
      if (name.contains('peacock')) return 'peacock';
      if (name.contains('hulu')) return 'hulu';
      if (name.contains('zee')) return 'zee';
      if (name.contains('jio')) return 'jio';
      if (name.contains('lionsgate')) return 'lionsgate';
      if (name.contains('crunchyroll')) return 'crunchyroll';
      if (name.contains('mx player')) return 'mx player';
      if (name.contains('voot')) return 'voot';
      return '';
    }

    final selected = <_MobileCategorySource>[];
    final seen = <String>{};
    final seenPlatforms = <String>{};
    for (final source in ranked) {
      if (selected.length == 10) break;
      if (!seen.add(source.key)) continue;
      final platform = platformBucket(source.category.name.toLowerCase());
      if (platform.isNotEmpty && !seenPlatforms.add(platform)) continue;
      selected.add(source);
    }
    return selected;
  }

  Future<List<_MobileFeature>> _loadMobileCategory(
    XtreamClient client,
    _MobileCategorySource source,
    String shelfTitle,
  ) async {
    try {
      if (source.isSeries) {
        final items = await CatalogCache.instance.seriesItems(
          client,
          source.category.id,
          priority: true,
        );
        var rows = seriesRecentlyAdded(items)
            .where((item) => item.name.trim().isNotEmpty)
            .take(20)
            .map((item) => _MobileFeature.series(item))
            .toList(growable: false);
        if (shelfTitle != 'New & Noteworthy' &&
            shelfTitle != 'Fresh Releases') {
          rows = [...rows]
            ..sort((a, b) =>
                (b.series?.rating ?? 0).compareTo(a.series?.rating ?? 0));
        }
        return _enrichMissingTmdbArtwork(rows);
      }

      final items = await CatalogCache.instance.vodStreams(
        client,
        source.category.id,
        priority: true,
      );
      var rows = moviesRecentlyAdded(items)
          .where((item) => item.name.trim().isNotEmpty)
          .take(20)
          .map((item) => _MobileFeature.movie(item))
          .toList(growable: false);
      if (shelfTitle != 'New & Noteworthy' &&
          shelfTitle != 'Fresh Releases') {
        rows = [...rows]
          ..sort((a, b) =>
              (b.movie?.rating ?? 0).compareTo(a.movie?.rating ?? 0));
      }
      return _enrichMissingTmdbArtwork(rows);
    } catch (_) {
      return const <_MobileFeature>[];
    }
  }

  Future<List<_MobileFeature>> _mobileHeroItems(
    XtreamClient client,
    List<_MobileCategorySource> sources,
  ) async {
    try {
      // The hero has its own small, series-only load. It must not wait for all
      // ten Home shelves to finish.
      final seriesSources = sources.where((source) => source.isSeries).take(5);
      final groups = await Future.wait([
        for (final source in seriesSources)
          CatalogCache.instance
              .seriesItems(client, source.category.id, priority: true)
              .catchError((_) => <Series>[]),
      ]);
      final providerSeries = <Series>[];
      final seenProvider = <int>{};
      for (final group in groups) {
        for (final item in seriesRecentlyAdded(group).take(20)) {
          if (seenProvider.add(item.seriesId)) providerSeries.add(item);
        }
      }

      final trending = await Tmdb.trendingTvIndia(candidateLimit: 40);
      final seriesMap = <String, Series>{};
      for (final item in providerSeries) {
        final key = _titleKey(item.name);
        if (key.isNotEmpty) seriesMap.putIfAbsent(key, () => item);
      }

      final result = <_MobileFeature>[];
      for (final tmdb in trending) {
        final provider = seriesMap[_titleKey(tmdb.title)];
        if (provider == null) continue;
        result.add(
          _MobileFeature.series(
            provider,
            tmdbTitle: tmdb.title,
            tmdbImage: tmdb.poster.isNotEmpty ? tmdb.poster : tmdb.backdrop,
            tmdbYear: tmdb.year,
          ),
        );
        if (result.length == 10) break;
      }

      // TMDB matching is an enhancement, not a reason to leave Home blank.
      if (result.isEmpty) {
        result.addAll(
          providerSeries
              .where((item) => item.cover.isNotEmpty)
              .take(10)
              .map((item) => _MobileFeature.series(item)),
        );
      }
      return result;
    } catch (_) {
      return const <_MobileFeature>[];
    }
  }

  Future<void> _refreshMobileShelvesFromPlaylist() async {
    if (!mounted) return;
    try {
      // Reload the provider category lists on the 24-hour shelf cadence. The
      // cache layer may serve the current snapshot immediately and refresh the
      // provider-backed data without disturbing the hourly hero.
      final data = await _loadHome();
      if (!mounted) return;
      setState(() => _prepareMobileShelves(data, updateHero: false));
    } catch (_) {
      // Keep the last usable shelves if the provider is temporarily offline.
    }
  }

  void _prepareMobileShelves(_HomeData data, {bool updateHero = true}) {
    final sources = _selectMobileCategories(data);
    final client = widget.client;

    // Each visible shelf gets a different provider category. At most ten
    // categories are loaded, with at most twenty cards displayed per shelf.
    if (updateHero) {
      _mobileHeroFuture = _mobileHeroItems(client, sources);
    }
    _mobileCuratedShelves = [
      for (var i = 0; i < _mobileCuratedShelfTitles.length; i++)
        if (i < sources.length)
          _MobileCuratedShelf(
            title: _mobileCuratedShelfTitles[i],
            future: _loadMobileCategory(
              client,
              sources[i],
              _mobileCuratedShelfTitles[i],
            ),
          ),
    ];
  }

  Future<List<_MobileFeature>> _enrichMissingTmdbArtwork(
    List<_MobileFeature> items,
  ) async {
    if (items.isEmpty) return const <_MobileFeature>[];
    final enriched = <_MobileFeature>[];
    var missingLookups = 0;
    for (final item in items.take(20)) {
      if (item.image.isNotEmpty) {
        enriched.add(item);
        continue;
      }
      // Keep the repair pass deliberately small so ten Home shelves do not
      // launch hundreds of TMDB requests on a low-end phone.
      if (missingLookups >= 8) continue;
      missingLookups++;
      var repaired = item;
      try {
        final movie = item.movie;
        if (movie != null) {
          final info = await Tmdb.movie(movie.name);
          if (info != null && info.poster.isNotEmpty) {
            repaired = _MobileFeature.movie(
              movie,
              tmdbTitle: info.title,
              tmdbImage: info.poster,
              tmdbYear: info.year,
            );
          }
        } else {
          final series = item.series;
          if (series != null) {
            final info = await Tmdb.tv(series.name);
            if (info != null && info.poster.isNotEmpty) {
              repaired = _MobileFeature.series(
                series,
                tmdbTitle: info.title,
                tmdbImage: info.poster,
                tmdbYear: info.year,
              );
            }
          }
        }
      } catch (_) {}
      if (repaired.image.isNotEmpty) enriched.add(repaired);
    }
    return enriched.take(20).toList(growable: false);
  }

  Widget _mobileContinueWatching() {
    final items = Library.instance.continueWatching();
    if (items.isEmpty) return const SizedBox.shrink();

    return Padding(
      padding: const EdgeInsets.only(top: 22),
      child: _MobileShelf(
        title: 'Continue Watching',
        children: [
          for (final progress in items)
            _MobileContinuePoster(
              key: ValueKey('continue-' + progress.key),
              progress: progress,
              onTap: () {
                if (progress.url.trim().isEmpty) return;
                PlaybackController.instance.open([
                  PlayerItem(
                    progress.url,
                    progress.title,
                    progressKey: progress.key,
                    poster: progress.poster,
                    ext: progress.ext,
                  ),
                ], 0);
              },
            ),
        ],
      ),
    );
  }

  Widget _mobileContinueLiveTv() {
    final channels = Library.instance.recent
        .where((item) => item.isLive && item.url.trim().isNotEmpty)
        .take(20)
        .toList();
    if (channels.isEmpty) return const SizedBox.shrink();

    return Padding(
      padding: const EdgeInsets.only(top: 22),
      child: _MobileShelf(
        title: 'Continue LIVE TV',
        children: [
          for (final channel in channels)
            _MobileLivePoster(
              key: ValueKey('live-' + channel.key),
              channel: channel,
              onTap: () => _openRecentChannel(channel),
            ),
        ],
      ),
    );
  }

  Widget _searchBar() {
    return Padding(
      // The shell owns the persistent account control in the top-right corner.
      // Reserve its footprint so the search affordance never sits underneath.
      padding: const EdgeInsets.fromLTRB(16, 4, 76, 0),
      child: SearchField(
        hint: 'Movies, series, channels…',
        readOnly: true,
        onTap: widget.onBrowse,
        trailing: Container(
          padding: const EdgeInsets.all(8),
          decoration: BoxDecoration(
            color: surface,
            borderRadius: BorderRadius.circular(lumenCorner(11)),
          ),
          child: Icon(Icons.tune_rounded, color: muted, size: 18),
        ),
      ),
    );
  }
}


class _MobileHomeSpotlight extends StatefulWidget {
  const _MobileHomeSpotlight({
    required this.future,
    required this.onMoviePlay,
    required this.onSeriesOpen,
  });
  final Future<List<_MobileFeature>> future;
  final ValueChanged<VodStream> onMoviePlay;
  final ValueChanged<Series> onSeriesOpen;
  @override
  State<_MobileHomeSpotlight> createState() => _MobileHomeSpotlightState();
}

class _MobileHomeSpotlightState extends State<_MobileHomeSpotlight> {
  // Keep the PageView on a large circular track so the tenth card flows
  // directly into the first instead of animating backwards across the list.
  static const int _loopCenterPage = 50000;
  final PageController _pageController = PageController(
    initialPage: _loopCenterPage,
  );
  Timer? _timer;
  List<_MobileFeature> _items = const [];
  int _index = 0;

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void didUpdateWidget(covariant _MobileHomeSpotlight oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.future != widget.future) {
      _timer?.cancel();
      _items = const [];
      _index = 0;
      _load();
    }
  }

  Future<void> _load() async {
    try {
      final items = await widget.future;
      if (!mounted) return;
      setState(() {
        _items = items.take(10).toList(growable: false);
        _index = 0;
      });
      if (_pageController.hasClients) {
        _pageController.jumpToPage(_loopCenterPage);
      }
      _startTimer();
    } catch (_) {
      if (mounted) setState(() => _items = const []);
    }
  }

  void _startTimer() {
    _timer?.cancel();
    if (_items.length < 2) return;
    _timer = Timer.periodic(const Duration(seconds: 6), (_) {
      if (!mounted || !_pageController.hasClients || _items.length < 2) return;
      final currentPage = _pageController.page?.round() ?? _loopCenterPage;
      _pageController.animateToPage(
        currentPage + 1,
        duration: const Duration(milliseconds: 520),
        curve: Curves.easeOutCubic,
      );
    });
  }

  @override
  void dispose() {
    _timer?.cancel();
    _pageController.dispose();
    super.dispose();
  }

  void _activate(_MobileFeature item) {
    if (item.movie != null) {
      widget.onMoviePlay(item.movie!);
    } else if (item.series != null) {
      widget.onSeriesOpen(item.series!);
    }
  }

  MediaRef _favoriteRef(_MobileFeature item) {
    if (item.movie != null) {
      final movie = item.movie!;
      return MediaRef(
        kind: 'movie',
        id: movie.streamId,
        name: item.title,
        image: item.image,
        cat: movie.categoryId,
      );
    }
    final series = item.series!;
    return MediaRef(
      kind: 'series',
      id: series.seriesId,
      name: item.title,
      image: item.image,
      cat: series.categoryId,
    );
  }

  void _toggleFavorite(_MobileFeature item) {
    final ref = _favoriteRef(item);
    Library.instance.toggleFav(ref);
    HapticFeedback.selectionClick();
  }

  @override
  Widget build(BuildContext context) {
    if (_items.isEmpty) {
      return const SizedBox(
        height: 420,
        child: Center(child: CircularProgressIndicator(strokeWidth: 2)),
      );
    }
    final width = MediaQuery.sizeOf(context).width - 32;
    final height = (width * 1.28).clamp(360.0, 500.0);
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 2, 16, 0),
      child: Column(
        children: [
          SizedBox(
            height: height,
            child: ClipRRect(
              borderRadius: BorderRadius.circular(22),
              child: PageView.builder(
                controller: _pageController,
                physics: const ClampingScrollPhysics(),
                onPageChanged: (page) {
                  if (!mounted || _items.isEmpty) return;
                  setState(() => _index = page % _items.length);
                  _startTimer();
                },
                itemCount: 100000,
                itemBuilder: (_, index) {
                  final item = _items[index % _items.length];
                  return RepaintBoundary(
                    child: GestureDetector(
                      behavior: HitTestBehavior.opaque,
                      onTap: () => _activate(item),
                      child: Stack(
                        fit: StackFit.expand,
                        children: [
                          MediaImage(
                            key: ValueKey(item.image),
                            source: item.image,
                            fit: BoxFit.cover,
                            alignment: Alignment.center,
                            memCacheWidth: (width * MediaQuery.devicePixelRatioOf(context))
                                .round()
                                .clamp(420, 1080),
                            error: ColoredBox(color: surfaceHi),
                          ),
                          const DecoratedBox(
                            decoration: BoxDecoration(
                              gradient: LinearGradient(
                                begin: Alignment.topCenter,
                                end: Alignment.bottomCenter,
                                colors: [
                                  Color(0x12000000),
                                  Color(0x22000000),
                                  Color(0xD9000000),
                                ],
                                stops: [0.25, 0.48, 1],
                              ),
                            ),
                          ),
                          Positioned(
                            left: 18,
                            right: 18,
                            bottom: 18,
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Row(
                                  children: [
                                    Container(
                                      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                                      decoration: BoxDecoration(
                                        color: accentInk,
                                        borderRadius: BorderRadius.circular(7),
                                      ),
                                      child: Text(
                                        item.movie != null ? 'MOVIE' : 'TV SHOW',
                                        style: TextStyle(
                                          color: foregroundFor(accentInk),
                                          fontSize: 9,
                                          fontWeight: FontWeight.w900,
                                          letterSpacing: .8,
                                        ),
                                      ),
                                    ),
                                    const SizedBox(width: 8),
                                    if (_year(item.title).isNotEmpty)
                                      Text(
                                        _year(item.title),
                                        style: const TextStyle(
                                          color: Colors.white70,
                                          fontSize: 11,
                                          fontWeight: FontWeight.w700,
                                        ),
                                      ),
                                  ],
                                ),
                                const SizedBox(height: 7),
                                Text(
                                  item.title,
                                  maxLines: 2,
                                  overflow: TextOverflow.ellipsis,
                                  style: const TextStyle(
                                    color: Colors.white,
                                    fontSize: 25,
                                    height: 1.02,
                                    fontWeight: FontWeight.w900,
                                  ),
                                ),
                                if (item.tmdbYear.isNotEmpty) ...[
                                  const SizedBox(height: 4),
                                  Text(
                                    item.tmdbYear,
                                    style: const TextStyle(
                                      color: Colors.white70,
                                      fontSize: 11,
                                      fontWeight: FontWeight.w700,
                                    ),
                                  ),
                                ],
                                const SizedBox(height: 11),
                                Row(
                                  children: [
                                    Expanded(
                                      child: FilledButton.icon(
                                        onPressed: () => _activate(item),
                                        icon: Icon(
                                          item.movie != null
                                              ? Icons.play_arrow_rounded
                                              : Icons.info_outline_rounded,
                                          size: 20,
                                        ),
                                        label: Text(
                                          item.movie != null ? 'Play' : 'View',
                                        ),
                                        style: FilledButton.styleFrom(
                                          minimumSize: const Size.fromHeight(44),
                                          backgroundColor: Colors.white,
                                          foregroundColor: Colors.black,
                                          shape: RoundedRectangleBorder(
                                            borderRadius: BorderRadius.circular(9),
                                          ),
                                        ),
                                      ),
                                    ),
                                    const SizedBox(width: 8),
                                    AnimatedBuilder(
                                      animation: Library.instance,
                                      builder: (context, _) {
                                        final saved = Library.instance.isFav(
                                          item.key,
                                        );
                                        return SizedBox(
                                          width: 48,
                                          height: 44,
                                          child: FilledButton(
                                            onPressed: () => _toggleFavorite(item),
                                            style: FilledButton.styleFrom(
                                              backgroundColor: Colors.white
                                                  .withValues(alpha: .18),
                                              foregroundColor: Colors.white,
                                              padding: EdgeInsets.zero,
                                              shape: RoundedRectangleBorder(
                                                borderRadius:
                                                    BorderRadius.circular(9),
                                              ),
                                            ),
                                            child: AnimatedSwitcher(
                                              duration: const Duration(
                                                milliseconds: 180,
                                              ),
                                              transitionBuilder:
                                                  (child, animation) =>
                                                      ScaleTransition(
                                                scale: CurvedAnimation(
                                                  parent: animation,
                                                  curve: Curves.easeOutBack,
                                                ),
                                                child: child,
                                              ),
                                              child: Icon(
                                                saved
                                                    ? Icons.check_rounded
                                                    : Icons.add_rounded,
                                                key: ValueKey(saved),
                                                size: 24,
                                              ),
                                            ),
                                          ),
                                        );
                                      },
                                    ),
                                  ],
                                ),
                              ],
                            ),
                          ),
                        ],
                      ),
                    ),
                  );
                },
              ),
            ),
          ),
          const SizedBox(height: 9),
          Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: List.generate(
              10,
              (i) => AnimatedContainer(
                duration: const Duration(milliseconds: 160),
                margin: const EdgeInsets.symmetric(horizontal: 3),
                width: i == _index ? 16 : 4,
                height: 4,
                decoration: BoxDecoration(
                  color: i == _index ? accent : muted.withValues(alpha: .55),
                  borderRadius: BorderRadius.circular(4),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _MobileFeature {
  const _MobileFeature.movie(
    this.movie, {
    this.tmdbTitle = '',
    this.tmdbImage = '',
    this.tmdbYear = '',
  }) : series = null;

  const _MobileFeature.series(
    this.series, {
    this.tmdbTitle = '',
    this.tmdbImage = '',
    this.tmdbYear = '',
  }) : movie = null;

  final VodStream? movie;
  final Series? series;
  final String tmdbTitle;
  final String tmdbImage;
  final String tmdbYear;

  String get title =>
      tmdbTitle.isNotEmpty ? tmdbTitle : (movie?.name ?? series?.name ?? '');

  String get image => tmdbImage.isNotEmpty
      ? tmdbImage
      : (movie?.icon ?? series?.cover ?? '');

  String get key => movie != null
      ? 'movie:' + movie!.streamId.toString()
      : 'series:' + series!.seriesId.toString();
}

class _MobileShelfSkeleton extends StatelessWidget {
  const _MobileShelfSkeleton({required this.title});

  final String title;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      height: 238,
      child: Padding(
        padding: const EdgeInsets.only(top: 22),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 0, 16, 10),
              child: Text(
                title,
                style: TextStyle(
                  color: textHi,
                  fontSize: 17,
                  fontWeight: FontWeight.w800,
                ),
              ),
            ),
            SizedBox(
              height: 194,
              child: ListView.separated(
                scrollDirection: Axis.horizontal,
                padding: const EdgeInsets.symmetric(horizontal: 16),
                itemCount: 4,
                separatorBuilder: (_, _) => const SizedBox(width: 10),
                itemBuilder: (_, _) => Container(
                  width: 132,
                  height: 194,
                  decoration: BoxDecoration(
                    color: surfaceHi,
                    borderRadius: BorderRadius.circular(14),
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _MobileShelf extends StatelessWidget {
  const _MobileShelf({required this.title, required this.children});

  final String title;
  final List<Widget> children;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      height: 216,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 10),
            child: Text(
              title,
              style: TextStyle(
                color: textHi,
                fontSize: 17,
                fontWeight: FontWeight.w800,
              ),
            ),
          ),
          SizedBox(
            height: 194,
            child: ListView.separated(
              scrollDirection: Axis.horizontal,
              padding: const EdgeInsets.symmetric(horizontal: 16),
              cacheExtent: 396,
              itemCount: children.length,
              separatorBuilder: (_, _) => const SizedBox(width: 10),
              itemBuilder: (_, i) => RepaintBoundary(child: children[i]),
            ),
          ),
        ],
      ),
    );
  }
}

class _MobileCuratedShelfLoader extends StatelessWidget {
  const _MobileCuratedShelfLoader({
    super.key,
    required this.title,
    required this.future,
    required this.onTap,
  });

  final String title;
  final Future<List<_MobileFeature>> future;
  final ValueChanged<_MobileFeature> onTap;

  @override
  Widget build(BuildContext context) {
    return FutureBuilder<List<_MobileFeature>>(
      future: future,
      builder: (context, snap) {
        if (snap.connectionState != ConnectionState.done && !snap.hasData) {
          return _MobileShelfSkeleton(title: title);
        }
        final items = (snap.data ?? const <_MobileFeature>[])
            .where((item) => item.image.isNotEmpty)
            .take(20)
            .toList(growable: false);
        if (items.isEmpty) return const SizedBox.shrink();
        return Padding(
          padding: const EdgeInsets.only(top: 22),
          child: _MobileShelf(
            title: title,
            children: [
              for (final item in items)
                _MobileFeaturePosterCard(
                  key: ValueKey('curated-card-' + item.key),
                  item: item,
                  onTap: () => onTap(item),
                ),
            ],
          ),
        );
      },
    );
  }
}

class _MobileFeaturePosterCard extends StatelessWidget {
  const _MobileFeaturePosterCard({
    super.key,
    required this.item,
    required this.onTap,
  });

  final _MobileFeature item;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: 132,
      height: 194,
      child: Material(
        color: Colors.transparent,
        child: InkWell(
          borderRadius: BorderRadius.circular(14),
          onTap: onTap,
          child: ClipRRect(
            borderRadius: BorderRadius.circular(14),
            child: MediaImage(
              source: item.image,
              fit: BoxFit.cover,
              memCacheWidth:
                  (132 * MediaQuery.devicePixelRatioOf(context))
                      .round()
                      .clamp(180, 420),
              error: ColoredBox(color: surfaceHi),
            ),
          ),
        ),
      ),
    );
  }
}

class _MobileLivePoster extends StatelessWidget {
  const _MobileLivePoster({
    super.key,
    required this.channel,
    required this.onTap,
  });
  final MediaRef channel;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: 132,
      height: 194,
      child: Material(
        color: Colors.transparent,
        child: InkWell(
          borderRadius: BorderRadius.circular(14),
          onTap: onTap,
          child: ClipRRect(
            borderRadius: BorderRadius.circular(14),
            child: Stack(
              fit: StackFit.expand,
              children: [
                MediaImage(
                  source: channel.image,
                  fit: BoxFit.cover,
                  memCacheWidth:
                      (132 * MediaQuery.devicePixelRatioOf(context))
                          .round()
                          .clamp(180, 420),
                  error: ColoredBox(color: surfaceHi),
                ),
                const Positioned(
                  top: 8,
                  left: 8,
                  child: _LiveBadge(),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _LiveBadge extends StatelessWidget {
  const _LiveBadge();

  @override
  Widget build(BuildContext context) {
    return DecoratedBox(
      decoration: BoxDecoration(
        color: Colors.black.withValues(alpha: .72),
        borderRadius: BorderRadius.circular(7),
      ),
      child: const Padding(
        padding: EdgeInsets.symmetric(horizontal: 7, vertical: 4),
        child: Text(
          'LIVE',
          style: TextStyle(
            color: Colors.white,
            fontSize: 9,
            fontWeight: FontWeight.w900,
            letterSpacing: .8,
          ),
        ),
      ),
    );
  }
}

class _MobileContinuePoster extends StatelessWidget {
  const _MobileContinuePoster({
    super.key,
    required this.progress,
    required this.onTap,
  });
  final Progress progress;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: 132,
      height: 194,
      child: InkWell(
        borderRadius: BorderRadius.circular(14),
        onTap: onTap,
        child: ClipRRect(
          borderRadius: BorderRadius.circular(14),
          child: Stack(
            fit: StackFit.expand,
            children: [
              MediaImage(
                source: progress.poster,
                fit: BoxFit.cover,
                memCacheWidth:
                    (150 * MediaQuery.devicePixelRatioOf(context))
                        .round()
                        .clamp(180, 420),
                error: ColoredBox(color: surfaceHi),
              ),
              const DecoratedBox(
                decoration: BoxDecoration(
                  gradient: LinearGradient(
                    begin: Alignment.topCenter,
                    end: Alignment.bottomCenter,
                    colors: [Colors.transparent, Color(0xCC000000)],
                  ),
                ),
              ),
              Positioned(
                left: 0,
                right: 0,
                bottom: 0,
                height: 3,
                child: LinearProgressIndicator(
                  value: progress.fraction,
                  color: accent,
                  backgroundColor: Colors.white24,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _HomeData {
  final List<Category> vodCats;
  final List<Category> seriesCats;
  _HomeData(this.vodCats, this.seriesCats);
}

/// Immersive desktop hero: full-bleed backdrop, big title, actions, and a
/// poster rail along the bottom that swaps the spotlight (auto-advances).
class _SpotlightHero extends StatefulWidget {
  final XtreamClient client;
  final Future<List<VodStream>> future;
  final int revision;
  final void Function(VodStream) onOpen;
  final FocusNode? entryFocusNode;
  const _SpotlightHero({
    super.key,
    required this.client,
    required this.future,
    required this.revision,
    required this.onOpen,
    this.entryFocusNode,
  });
  @override
  State<_SpotlightHero> createState() => _SpotlightHeroState();
}

class _SpotlightHeroState extends State<_SpotlightHero> {
  List<VodStream> _items = [];
  int _index = 0;
  bool _loaded = false;
  Timer? _timer;
  final Map<int, TmdbInfo?> _meta = {};
  final List<FocusNode> _railFocusNodes = List.generate(
    8,
    (index) => FocusNode(debugLabel: 'Home spotlight tile $index'),
  );
  int _request = 0;

  @override
  void initState() {
    super.initState();
    _load(widget.future);
  }

  @override
  void didUpdateWidget(covariant _SpotlightHero oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.revision != widget.revision) _load(widget.future);
  }

  void _load(Future<List<VodStream>> future) {
    final request = ++_request;
    future
        .then((l) {
          if (!mounted || request != _request) return;
          // A transient empty provider response must not blank a hero that is
          // already on screen. The next refresh can replace it once reliable
          // content arrives.
          if (l.isEmpty && _items.isNotEmpty) return;
          setState(() {
            _items = l;
            if (_index >= l.length) _index = 0;
            _loaded = true;
          });
          if (l.isNotEmpty) {
            // Enrich only what is visible. The next item loads when selected rather
            // than issuing two TMDB requests for every hero card at startup.
            _fetchMeta(l.first);
            _timer ??= Timer.periodic(
              const Duration(seconds: 8),
              (_) => _advance(),
            );
          }
        })
        .catchError((_) {
          if (mounted && request == _request && _items.isEmpty) {
            setState(() => _loaded = true);
          }
        });
  }

  @override
  void dispose() {
    _timer?.cancel();
    for (final node in _railFocusNodes) {
      node.dispose();
    }
    super.dispose();
  }

  KeyEventResult _handleRailKey(int index, KeyEvent event) {
    if (event is! KeyDownEvent && event is! KeyRepeatEvent) {
      return KeyEventResult.ignored;
    }
    final key = event.logicalKey;
    if (key != LogicalKeyboardKey.arrowLeft &&
        key != LogicalKeyboardKey.arrowRight) {
      return KeyEventResult.ignored;
    }

    final target = index + (key == LogicalKeyboardKey.arrowLeft ? -1 : 1);
    // Left from the first tile deliberately bubbles to HomeShell, which moves
    // focus to the navigation rail. Keep focus put at the rightmost edge.
    if (target < 0) return KeyEventResult.ignored;
    if (target >= _items.length) return KeyEventResult.handled;

    final targetNode = _railFocusNodes[target];
    final targetContext = targetNode.context;
    if (targetContext == null || !targetContext.mounted) {
      // Let the app's traversal policy reveal a lazily built tile first.
      return KeyEventResult.ignored;
    }
    targetNode.requestFocus();
    return KeyEventResult.handled;
  }

  void _advance() {
    // IndexedStack preserves Home while another tab is open. TickerMode is
    // disabled there, so do not rotate artwork or fetch metadata off-screen.
    if (!TickerMode.of(context) || _items.length < 2) return;
    _select((_index + 1) % _items.length);
  }

  void _select(int i) {
    setState(() => _index = i);
    _fetchMeta(_items[i]);
  }

  void _fetchMeta(VodStream m) {
    if (_meta.containsKey(m.streamId)) return;
    _meta[m.streamId] = null;
    if (widget.client.creds.isDemo) return;
    Tmdb.movie(m.name).then((t) {
      if (mounted) setState(() => _meta[m.streamId] = t);
    });
  }

  MediaRef _ref(VodStream m) => MediaRef(
    kind: 'movie',
    id: m.streamId,
    name: m.name,
    image: m.icon,
    cat: m.categoryId,
  );

  void _play(VodStream m) {
    final ext = m.containerExtension.isEmpty ? 'mp4' : m.containerExtension;
    final url = widget.client.streamUrl('movie', m.streamId, ext: ext);
    PlaybackController.instance.open([
      PlayerItem(
        url,
        m.name,
        progressKey: 'movie:${m.streamId}',
        poster: m.icon,
        ext: ext,
        favRef: _ref(m),
      ),
    ], 0);
  }

  Widget _chip(Widget child) => Container(
    padding: const EdgeInsets.symmetric(horizontal: 11, vertical: 6),
    decoration: BoxDecoration(
      color: surfaceHi,
      borderRadius: BorderRadius.circular(lumenCorner(10)),
      border: Border.all(color: line),
    ),
    child: child,
  );

  // Phone hero: poster on top, centred title / meta / actions, rail below.
  Widget _narrowHero(
    VodStream m,
    String poster,
    double rating,
    String year,
    String genre,
    String overview,
  ) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 6, 20, 4),
      child: Column(
        children: [
          AnimatedSwitcher(
            duration: const Duration(milliseconds: 450),
            transitionBuilder: (c, a) => FadeTransition(
              opacity: a,
              child: ScaleTransition(
                scale: Tween(begin: 0.97, end: 1.0).animate(a),
                child: c,
              ),
            ),
            child: Container(
              key: ValueKey('ncard$poster'),
              width: 152,
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(lumenCorner(18)),
                boxShadow: [
                  BoxShadow(
                    color: Colors.black.withValues(alpha: 0.5),
                    blurRadius: 34,
                    offset: const Offset(0, 16),
                  ),
                ],
              ),
              child: AspectRatio(
                aspectRatio: 2 / 3,
                child: ClipRRect(
                  borderRadius: BorderRadius.circular(lumenCorner(18)),
                  child: Stack(
                    fit: StackFit.expand,
                    children: [
                      ColoredBox(color: surfaceHi),
                      if (poster.isNotEmpty)
                        MediaImage(
                          source: poster,
                          fit: BoxFit.cover,
                          memCacheWidth:
                              (180 * MediaQuery.devicePixelRatioOf(context))
                                  .round()
                                  .clamp(320, 560),
                        ),
                      DecoratedBox(
                        decoration: BoxDecoration(
                          borderRadius: BorderRadius.circular(lumenCorner(18)),
                          border: Border.all(
                            color: Colors.white.withValues(alpha: 0.12),
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ),
          const SizedBox(height: 16),
          Text(
            'FEATURED',
            style: TextStyle(
              color: accent,
              fontSize: 11,
              fontWeight: FontWeight.w800,
              letterSpacing: 2.5,
            ),
          ),
          const SizedBox(height: 8),
          Text(
            _clean(m.name),
            textAlign: TextAlign.center,
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
            style: kTitle(),
          ),
          const SizedBox(height: 12),
          Wrap(
            alignment: WrapAlignment.center,
            spacing: 8,
            runSpacing: 8,
            children: [
              if (rating > 0)
                _chip(
                  Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Icon(Icons.star_rounded, color: gold, size: 14),
                      const SizedBox(width: 4),
                      Text(
                        rating.toStringAsFixed(1),
                        style: TextStyle(
                          color: gold,
                          fontWeight: FontWeight.w800,
                          fontSize: 12.5,
                        ),
                      ),
                    ],
                  ),
                ),
              if (year.isNotEmpty)
                _chip(
                  Text(
                    year,
                    style: TextStyle(
                      color: textHi,
                      fontWeight: FontWeight.w700,
                      fontSize: 12.5,
                    ),
                  ),
                ),
              if (genre.isNotEmpty)
                _chip(
                  Text(genre, style: TextStyle(color: muted, fontSize: 12.5)),
                ),
              if (m.sourceLabel.isNotEmpty)
                _chip(
                  Text(
                    m.sourceLabel,
                    style: TextStyle(color: accentInk, fontSize: 12.5),
                  ),
                ),
            ],
          ),
          if (overview.isNotEmpty) ...[
            const SizedBox(height: 12),
            Text(
              overview,
              textAlign: TextAlign.center,
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style: kBody(),
            ),
          ],
          const SizedBox(height: 16),
          Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              PillButton(
                icon: Icons.play_arrow_rounded,
                label: 'Play',
                onTap: () => _play(m),
                focusNode: widget.entryFocusNode,
              ),
              const SizedBox(width: 10),
              HoverScale(
                child: RemoteTap(
                  onTap: () => widget.onOpen(m),
                  child: Container(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 20,
                      vertical: 14,
                    ),
                    decoration: BoxDecoration(
                      color: surfaceHi,
                      borderRadius: BorderRadius.circular(lumenCorner(30)),
                      border: Border.all(color: line),
                    ),
                    child: Icon(
                      Icons.info_outline_rounded,
                      color: textHi,
                      size: 22,
                    ),
                  ),
                ),
              ),
              const SizedBox(width: 10),
              AnimatedBuilder(
                animation: Library.instance,
                builder: (_, __) {
                  final fav = Library.instance.isFav(_ref(m).key);
                  return RemoteTap(
                    onTap: () => Library.instance.toggleFav(_ref(m)),
                    child: Container(
                      padding: const EdgeInsets.all(14),
                      decoration: BoxDecoration(
                        shape: BoxShape.circle,
                        color: surfaceHi,
                        border: Border.all(color: line),
                      ),
                      child: Icon(
                        fav
                            ? Icons.favorite_rounded
                            : Icons.favorite_border_rounded,
                        color: fav ? accent : textHi,
                        size: 22,
                      ),
                    ),
                  );
                },
              ),
            ],
          ),
          const SizedBox(height: 18),
          SizedBox(
            height: 96,
            child: HorizontalShelfViewport(
              key: const ValueKey('home-spotlight-compact-viewport'),
              child: ListView.separated(
                scrollDirection: Axis.horizontal,
                clipBehavior: Clip.none,
                padding: const EdgeInsets.symmetric(
                  horizontal: 20,
                  vertical: 6,
                ),
                itemCount: _items.length,
                separatorBuilder: (_, _) => const SizedBox(width: 12),
                itemBuilder: (_, i) {
                  final it = _items[i];
                  final p = _meta[it.streamId]?.poster;
                  final img = (p != null && p.isNotEmpty) ? p : it.icon;
                  return _RailThumb(
                    image: img,
                    number: i + 1,
                    selected: i == _index,
                    focusNode: _railFocusNodes[i],
                    onKeyEvent: (event) => _handleRailKey(i, event),
                    onTap: () => _select(i),
                  );
                },
              ),
            ),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    // Loaded but nothing to feature → collapse so the shelves show at the top.
    if (_loaded && _items.isEmpty) return const SizedBox.shrink();
    // Still loading → a bounded placeholder (never an infinite full-screen spin).
    if (_items.isEmpty) {
      return SizedBox(
        height: 360,
        child: Center(
          child: CircularProgressIndicator(color: accentInk, strokeWidth: 2),
        ),
      );
    }
    final m = _items[_index];
    final t = _meta[m.streamId];
    // Prefer a cinematic 16:9 backdrop when metadata is available. Provider
    // posters remain a reliable fallback while metadata is still loading.
    final poster = (t?.poster.isNotEmpty == true) ? t!.poster : m.icon;
    final heroArt = (t?.backdrop.isNotEmpty == true) ? t!.backdrop : poster;
    final rating = (t?.rating ?? 0) > 0 ? t!.rating : m.rating;
    final year = _year(m.name);
    final genre = t?.genres ?? '';
    final overview = t?.overview ?? '';

    if (!isWide(context))
      return _narrowHero(m, poster, rating, year, genre, overview);

    final h = DeviceProfile.isTelevision
        ? (MediaQuery.sizeOf(context).height * 0.64).clamp(455.0, 520.0)
        : (MediaQuery.sizeOf(context).height * 0.63).clamp(500.0, 610.0);
    return Padding(
      padding: const EdgeInsets.fromLTRB(18, 6, 18, 0),
      child: SizedBox(
        height: h,
        child: ClipRRect(
          borderRadius: BorderRadius.circular(lumenCorner(22)),
          child: Stack(
            fit: StackFit.expand,
            children: [
              ColoredBox(color: surface),
              if (heroArt.isNotEmpty)
                Positioned.fill(
                  child: AnimatedSwitcher(
                    duration: const Duration(milliseconds: 550),
                    child: MediaImage(
                      key: ValueKey('focus$heroArt'),
                      source: heroArt,
                      fit: BoxFit.cover,
                      alignment: Alignment.center,
                      memCacheWidth:
                          (760 * MediaQuery.devicePixelRatioOf(context))
                              .round()
                              .clamp(900, 1800),
                      error: ColoredBox(color: surfaceHi),
                    ),
                  ),
                ),
              DecoratedBox(
                decoration: BoxDecoration(
                  gradient: LinearGradient(
                    begin: Alignment.centerLeft,
                    end: Alignment.centerRight,
                    stops: const [0, 0.34, 0.68, 1],
                    colors: [
                      surface.withValues(alpha: 0.98),
                      surface.withValues(alpha: 0.86),
                      surface.withValues(alpha: 0.35),
                      surface.withValues(alpha: 0.08),
                    ],
                  ),
                ),
              ),
              DecoratedBox(
                decoration: BoxDecoration(
                  gradient: LinearGradient(
                    begin: Alignment.topCenter,
                    end: Alignment.bottomCenter,
                    stops: const [0.50, 1],
                    colors: [
                      Colors.transparent,
                      Colors.black.withValues(alpha: 0.72),
                    ],
                  ),
                ),
              ),
              Positioned(
                left: 42,
                top: 34,
                width: 570,
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        Container(width: 28, height: 2, color: accent),
                        const SizedBox(width: 10),
                        Text('NOW IN FOCUS', style: kSection(color: accentInk)),
                        const SizedBox(width: 12),
                        Text(
                          '${(_index + 1).toString().padLeft(2, '0')} / ${_items.length.toString().padLeft(2, '0')}',
                          style: TextStyle(
                            color: subtle,
                            fontSize: 11,
                            fontWeight: FontWeight.w600,
                            letterSpacing: 1.2,
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 16),
                    Text(
                          _clean(m.name),
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                          style: kHero(),
                        )
                        .animate(key: ValueKey('t${m.streamId}'))
                        .fadeIn(duration: 400.ms)
                        .slideY(begin: 0.08, end: 0),
                    const SizedBox(height: 12),
                    Wrap(
                      spacing: 16,
                      runSpacing: 8,
                      crossAxisAlignment: WrapCrossAlignment.center,
                      children: [
                        if (rating > 0)
                          Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              Icon(Icons.star_rounded, color: gold, size: 15),
                              const SizedBox(width: 5),
                              Text(
                                rating.toStringAsFixed(1),
                                style: TextStyle(
                                  color: textHi,
                                  fontWeight: FontWeight.w700,
                                  fontSize: 13,
                                ),
                              ),
                            ],
                          ),
                        if (year.isNotEmpty)
                          Text(
                            year,
                            style: TextStyle(
                              color: muted,
                              fontWeight: FontWeight.w600,
                              fontSize: 13,
                            ),
                          ),
                        if (genre.isNotEmpty)
                          Text(
                            genre,
                            style: TextStyle(color: muted, fontSize: 13),
                          ),
                        if (m.sourceLabel.isNotEmpty)
                          Text(
                            m.sourceLabel,
                            style: TextStyle(
                              color: accentInk,
                              fontWeight: FontWeight.w700,
                              fontSize: 13,
                            ),
                          ),
                      ],
                    ),
                    if (overview.isNotEmpty) ...[
                      const SizedBox(height: 12),
                      ConstrainedBox(
                        constraints: const BoxConstraints(maxWidth: 500),
                        child: Text(
                          overview,
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                          style: kBody(),
                        ),
                      ),
                    ],
                    const SizedBox(height: 18),
                    Row(
                      children: [
                        PillButton(
                          icon: Icons.play_arrow_rounded,
                          label: 'Watch now',
                          onTap: () => _play(m),
                          focusNode: widget.entryFocusNode,
                        ),
                        const SizedBox(width: 10),
                        PillButton(
                          icon: Icons.arrow_outward_rounded,
                          label: 'Details',
                          filled: false,
                          onTap: () => widget.onOpen(m),
                        ),
                        const SizedBox(width: 10),
                        AnimatedBuilder(
                          animation: Library.instance,
                          builder: (_, __) {
                            final fav = Library.instance.isFav(_ref(m).key);
                            return FocusableTap(
                              onTap: () => Library.instance.toggleFav(_ref(m)),
                              builder: (_, active) => AnimatedContainer(
                                duration: const Duration(milliseconds: 160),
                                width: 47,
                                height: 47,
                                decoration: BoxDecoration(
                                  color: active ? surfaceHi : surface,
                                  borderRadius: BorderRadius.circular(
                                    lumenCorner(14),
                                  ),
                                  border: Border.all(
                                    color: active ? accent : line,
                                  ),
                                ),
                                child: Icon(
                                  fav
                                      ? Icons.favorite_rounded
                                      : Icons.favorite_border_rounded,
                                  color: fav ? accent : textHi,
                                  size: 20,
                                ),
                              ),
                            );
                          },
                        ),
                      ],
                    ),
                  ],
                ),
              ),
              Positioned(
                left: 42,
                right: 28,
                bottom: 20,
                height: DeviceProfile.isTelevision ? 108 : 78,
                child: HorizontalShelfViewport(
                  key: const ValueKey('home-spotlight-wide-viewport'),
                  child: ListView.separated(
                    scrollDirection: Axis.horizontal,
                    clipBehavior: Clip.none,
                    padding: EdgeInsets.symmetric(
                      horizontal: DeviceProfile.isTelevision ? 22 : 18,
                      vertical: DeviceProfile.isTelevision ? 7 : 5,
                    ),
                    itemCount: _items.length,
                    separatorBuilder: (_, _) =>
                        SizedBox(width: DeviceProfile.isTelevision ? 12 : 10),
                    itemBuilder: (_, i) {
                      final it = _items[i];
                      final p = _meta[it.streamId]?.poster;
                      final img = (p != null && p.isNotEmpty) ? p : it.icon;
                      return _RailThumb(
                        image: img,
                        label: _clean(it.name),
                        number: i + 1,
                        selected: i == _index,
                        width: DeviceProfile.isTelevision ? 158 : 122,
                        focusNode: _railFocusNodes[i],
                        onKeyEvent: (event) => _handleRailKey(i, event),
                        onFocus: () => _select(i),
                        onTap: () => widget.onOpen(it),
                      );
                    },
                  ),
                ),
              ),
              Positioned.fill(
                child: IgnorePointer(
                  child: DecoratedBox(
                    decoration: BoxDecoration(
                      border: Border.all(color: line),
                      borderRadius: BorderRadius.circular(lumenCorner(22)),
                    ),
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

/// A single poster in the hero's "Featured" rail — sharp TMDB poster, dimmed
/// when inactive, accent-ringed + glowing + scaled-up when active or hovered.
class _RailThumb extends StatelessWidget {
  final String image;
  final String label;
  final int number;
  final bool selected;
  final double width;
  final FocusNode? focusNode;
  final KeyEventResult Function(KeyEvent event)? onKeyEvent;
  final VoidCallback? onFocus;
  final VoidCallback onTap;
  const _RailThumb({
    required this.image,
    this.label = '',
    required this.number,
    required this.selected,
    this.width = 112,
    this.focusNode,
    this.onKeyEvent,
    this.onFocus,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return FocusableTap(
      focusNode: focusNode,
      onKeyEvent: onKeyEvent == null ? null : (_, event) => onKeyEvent!(event),
      onFocusChange: (focused) {
        if (focused) onFocus?.call();
      },
      onTap: onTap,
      builder: (context, active) {
        return AnimatedScale(
          // FocusableTap owns the app-wide, user-selected scale treatment.
          scale: 1,
          duration: const Duration(milliseconds: 200),
          curve: Curves.easeOut,
          alignment: Alignment.bottomCenter,
          child: AnimatedOpacity(
            opacity: selected ? 1 : (active ? 0.92 : 0.58),
            duration: const Duration(milliseconds: 200),
            child: SizedBox(
              width: width,
              child: Container(
                decoration: BoxDecoration(
                  borderRadius: BorderRadius.circular(lumenCorner(10)),
                  border: Border.all(
                    color: selected ? accent : line,
                    width: selected ? 2 : 1,
                  ),
                  boxShadow: selected
                      ? [
                          BoxShadow(
                            color: accent.withValues(alpha: 0.5),
                            blurRadius: 24,
                            spreadRadius: -2,
                            offset: const Offset(0, 8),
                          ),
                        ]
                      : [
                          BoxShadow(
                            color: Colors.black.withValues(alpha: 0.45),
                            blurRadius: 12,
                            offset: const Offset(0, 5),
                          ),
                        ],
                ),
                clipBehavior: Clip.antiAlias,
                child: Stack(
                  fit: StackFit.expand,
                  children: [
                    image.isNotEmpty
                        ? MediaImage(
                            source: image,
                            fit: BoxFit.cover,
                            alignment: Alignment.topCenter,
                            memCacheWidth:
                                (220 * MediaQuery.devicePixelRatioOf(context))
                                    .round()
                                    .clamp(320, 640),
                            error: ColoredBox(color: surfaceHi),
                          )
                        : ColoredBox(color: surfaceHi),
                    DecoratedBox(
                      decoration: BoxDecoration(
                        gradient: LinearGradient(
                          begin: Alignment.bottomCenter,
                          end: Alignment.topCenter,
                          colors: [
                            Colors.black.withValues(alpha: 0.72),
                            Colors.transparent,
                          ],
                        ),
                      ),
                    ),
                    Positioned(
                      left: 8,
                      top: 7,
                      child: Text(
                        number.toString().padLeft(2, '0'),
                        style: const TextStyle(
                          color: Colors.white,
                          fontSize: 10,
                          fontWeight: FontWeight.w800,
                          letterSpacing: 1,
                        ),
                      ),
                    ),
                    if (label.isNotEmpty)
                      Positioned(
                        left: 9,
                        right: 9,
                        bottom: 7,
                        child: Text(
                          label,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(
                            color: Colors.white,
                            fontSize: 11.5,
                            fontWeight: FontWeight.w800,
                          ),
                        ),
                      ),
                  ],
                ),
              ),
            ),
          ),
        );
      },
    );
  }
}

enum _ContinueAction { resume, restart, watched, remove }

class _HistoryDialogOption extends StatelessWidget {
  const _HistoryDialogOption({
    required this.icon,
    required this.label,
    required this.onTap,
    this.autofocus = false,
  });

  final IconData icon;
  final String label;
  final VoidCallback onTap;
  final bool autofocus;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(top: 8),
      child: FocusableTap(
        autofocus: autofocus,
        onTap: onTap,
        builder: (_, active) => AnimatedContainer(
          duration: lumenMotionFast,
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 13),
          decoration: BoxDecoration(
            color: active ? surfaceRaised : surfaceHi,
            borderRadius: BorderRadius.circular(lumenCorner(13)),
            border: Border.all(color: active ? accentInk : line),
          ),
          child: Row(
            children: [
              Icon(icon, size: 20, color: active ? accentInk : muted),
              const SizedBox(width: 12),
              Expanded(
                child: Text(
                  label,
                  style: TextStyle(
                    color: textHi,
                    fontWeight: FontWeight.w700,
                    fontSize: 14,
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

String _remainingLabel(Progress progress) {
  final remaining = (progress.duration - progress.position)
      .clamp(0, progress.duration)
      .toInt();
  final duration = Duration(seconds: remaining);
  if (duration.inHours > 0) {
    final minutes = duration.inMinutes.remainder(60);
    return '${duration.inHours}h ${minutes == 0 ? '' : '${minutes}m '}left'
        .replaceAll('  ', ' ');
  }
  return '${duration.inMinutes.clamp(1, 999)}m left';
}

/// A true resume card backed by durable VOD playback position.
class _ContinueWatchingCard extends StatelessWidget {
  const _ContinueWatchingCard({
    super.key,
    required this.progress,
    required this.index,
    required this.width,
    required this.height,
    required this.focusNode,
    required this.onTap,
    required this.onLongPress,
  });

  final Progress progress;
  final int index;
  final double width;
  final double height;
  final FocusNode focusNode;
  final VoidCallback onTap;
  final VoidCallback onLongPress;

  @override
  Widget build(BuildContext context) {
    final episode = progress.key.startsWith('ep:');
    return SizedBox(
      width: width,
      height: height,
      child:
          FocusableTap(
                focusNode: focusNode,
                onTap: onTap,
                onLongPress: onLongPress,
                builder: (context, active) => AnimatedContainer(
                  duration: lumenMotionFast,
                  decoration: BoxDecoration(
                    color: active ? surfaceHi : surface,
                    borderRadius: BorderRadius.circular(lumenCorner(16)),
                    border: Border.all(color: active ? accent : line),
                    boxShadow: active
                        ? glow(accent, blur: 18, y: 7, a: .28)
                        : null,
                  ),
                  clipBehavior: Clip.antiAlias,
                  child: Stack(
                    children: [
                      Row(
                        children: [
                          SizedBox(
                            width: height * 1.05,
                            height: height,
                            child: progress.poster.isNotEmpty
                                ? MediaImage(
                                    source: progress.poster,
                                    fit: BoxFit.cover,
                                    memCacheWidth:
                                        (height *
                                                1.5 *
                                                MediaQuery.devicePixelRatioOf(
                                                  context,
                                                ))
                                            .round()
                                            .clamp(240, 600),
                                  )
                                : ColoredBox(
                                    color: surfaceHi,
                                    child: Icon(
                                      episode
                                          ? Icons.video_library_rounded
                                          : Icons.movie_rounded,
                                      color: muted,
                                      size: 30,
                                    ),
                                  ),
                          ),
                          Expanded(
                            child: Padding(
                              padding: const EdgeInsets.fromLTRB(13, 9, 10, 10),
                              child: Column(
                                mainAxisAlignment: MainAxisAlignment.center,
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Row(
                                    children: [
                                      Expanded(
                                        child: Text(
                                          progress.title,
                                          maxLines: 2,
                                          overflow: TextOverflow.ellipsis,
                                          style: TextStyle(
                                            color: textHi,
                                            fontSize: DeviceProfile.isTelevision
                                                ? 14
                                                : 13,
                                            fontWeight: FontWeight.w800,
                                            height: 1.15,
                                          ),
                                        ),
                                      ),
                                      Icon(
                                        Icons.more_horiz_rounded,
                                        size: 18,
                                        color: active ? accentInk : muted,
                                      ),
                                    ],
                                  ),
                                  const SizedBox(height: 7),
                                  Text(
                                    '${episode ? 'Episode' : 'Film'} · ${_remainingLabel(progress)}',
                                    maxLines: 1,
                                    overflow: TextOverflow.ellipsis,
                                    style: TextStyle(
                                      color: active ? accentInk : muted,
                                      fontSize: 11.5,
                                      fontWeight: FontWeight.w700,
                                    ),
                                  ),
                                ],
                              ),
                            ),
                          ),
                        ],
                      ),
                      Positioned(
                        left: 0,
                        right: 0,
                        bottom: 0,
                        height: 4,
                        child: LinearProgressIndicator(
                          value: progress.fraction,
                          color: accent,
                          backgroundColor: line,
                        ),
                      ),
                    ],
                  ),
                ),
              )
              .animate()
              .fadeIn(duration: 320.ms, delay: (index.clamp(0, 12) * 30).ms)
              .slideY(begin: 0.1, end: 0, curve: Curves.easeOutCubic),
    );
  }
}

/// A separate live-history card; channels never enter Continue Watching.
class _RecentChannelCard extends StatelessWidget {
  final MediaRef item;
  final int index;
  final double width;
  final double height;
  final FocusNode focusNode;
  final VoidCallback onTap;
  final VoidCallback onLongPress;
  const _RecentChannelCard({
    super.key,
    required this.item,
    required this.index,
    this.width = 280,
    this.height = 104,
    required this.focusNode,
    required this.onTap,
    required this.onLongPress,
  });

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: width,
      height: height,
      child:
          FocusableTap(
                focusNode: focusNode,
                onTap: onTap,
                onLongPress: onLongPress,
                builder: (context, active) => AnimatedContainer(
                  duration: lumenMotionFast,
                  decoration: BoxDecoration(
                    color: active ? surfaceHi : surface,
                    borderRadius: BorderRadius.circular(lumenCorner(16)),
                    border: Border.all(color: active ? accent : line),
                    boxShadow: active
                        ? glow(accent, blur: 18, y: 7, a: .28)
                        : null,
                  ),
                  clipBehavior: Clip.antiAlias,
                  child: Row(
                    children: [
                      SizedBox(
                        width: height * 1.05,
                        height: height,
                        child: Stack(
                          fit: StackFit.expand,
                          children: [
                            ColoredBox(color: surfaceHi),
                            if (item.image.isNotEmpty)
                              Padding(
                                padding: const EdgeInsets.all(14),
                                child: MediaImage(
                                  source: item.image,
                                  fit: BoxFit.contain,
                                  memCacheWidth:
                                      (height *
                                              1.5 *
                                              MediaQuery.devicePixelRatioOf(
                                                context,
                                              ))
                                          .round()
                                          .clamp(240, 600),
                                ),
                              ),
                            Positioned(
                              left: 8,
                              top: 8,
                              child: Container(
                                padding: const EdgeInsets.symmetric(
                                  horizontal: 6,
                                  vertical: 3,
                                ),
                                decoration: BoxDecoration(
                                  color: const Color(0xFFFF3B41),
                                  borderRadius: BorderRadius.circular(
                                    lumenCorner(6),
                                  ),
                                ),
                                child: const Text(
                                  'LIVE',
                                  style: TextStyle(
                                    color: Colors.white,
                                    fontSize: 9,
                                    fontWeight: FontWeight.w900,
                                  ),
                                ),
                              ),
                            ),
                          ],
                        ),
                      ),
                      Expanded(
                        child: Padding(
                          padding: const EdgeInsets.symmetric(horizontal: 13),
                          child: Column(
                            mainAxisAlignment: MainAxisAlignment.center,
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(
                                item.name,
                                maxLines: 2,
                                overflow: TextOverflow.ellipsis,
                                style: TextStyle(
                                  color: textHi,
                                  fontSize: DeviceProfile.isTelevision
                                      ? 14
                                      : 13,
                                  fontWeight: FontWeight.w800,
                                  height: 1.15,
                                ),
                              ),
                              const SizedBox(height: 7),
                              Row(
                                children: [
                                  Icon(
                                    Icons.play_circle_fill_rounded,
                                    size: 17,
                                    color: active ? accent : muted,
                                  ),
                                  const SizedBox(width: 6),
                                  Expanded(
                                    child: Text(
                                      'Watch live',
                                      maxLines: 1,
                                      overflow: TextOverflow.ellipsis,
                                      style: TextStyle(
                                        color: active ? accent : muted,
                                        fontSize: 11.5,
                                        fontWeight: FontWeight.w700,
                                      ),
                                    ),
                                  ),
                                ],
                              ),
                            ],
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
              )
              .animate()
              .fadeIn(duration: 320.ms, delay: (index.clamp(0, 12) * 30).ms)
              .slideY(begin: 0.1, end: 0, curve: Curves.easeOutCubic),
    );
  }
}
