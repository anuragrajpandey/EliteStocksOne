import 'dart:convert';
import 'dart:math' as math;
import 'package:http/http.dart' as http;

/// TMDB metadata enrichment for artwork, titles, dates and details.
///
/// The API key is injected at build time with --dart-define=TMDB_API_KEY=...
/// so it never needs to live in the repository source.
class Tmdb {
  static const _key = String.fromEnvironment('TMDB_API_KEY');
  static const _base = 'https://api.themoviedb.org/3';
  static const img = 'https://image.tmdb.org/t/p';

  static final Map<String, Future<TmdbInfo?>> _cache = {};
  static Future<List<TmdbTrendingItem>>? _indiaTvFuture;
  static final Map<String, Future<List<TmdbCatalogItem>>> _curatedCache = {};

  static Future<TmdbInfo?> movie(String rawName) => _lookup('movie', rawName);
  static Future<TmdbInfo?> tv(String rawName) => _lookup('tv', rawName);

  static Future<List<TmdbTrendingItem>> trendingTvIndia({
    int candidateLimit = 40,
  }) {
    if (_key.trim().isEmpty) return Future.value(const <TmdbTrendingItem>[]);
    return _indiaTvFuture ??= _fetchTrendingTvIndia(
      candidateLimit.clamp(10, 60),
    );
  }

  static Future<List<TmdbTrendingItem>> _fetchTrendingTvIndia(
    int candidateLimit,
  ) async {
    try {
      final pages = (candidateLimit / 20).ceil().clamp(1, 3);
      final responses = await Future.wait([
        for (var page = 1; page <= pages; page++)
          http.get(
            Uri.parse(
              '$_base/discover/tv'
              '?api_key=$_key'
              '&language=en-IN'
              '&watch_region=IN'
              '&with_watch_monetization_types=flatrate%7Cfree%7Cads%7Crent%7Cbuy'
              '&sort_by=popularity.desc'
              '&include_adult=false'
              '&page=$page',
            ),
          ).timeout(const Duration(seconds: 10)),
      ]);
      final result = <TmdbTrendingItem>[];
      for (final response in responses) {
        if (response.statusCode != 200) continue;
        final raw = (jsonDecode(response.body)['results'] as List?) ?? const [];
        for (final item in raw.whereType<Map>()) {
          final parsed = TmdbTrendingItem.fromJson(
            item.cast<String, dynamic>(),
          );
          if (parsed.title.isNotEmpty && parsed.poster.isNotEmpty) {
            result.add(parsed);
          }
          if (result.length >= candidateLimit) break;
        }
        if (result.length >= candidateLimit) break;
      }
      return result.take(candidateLimit).toList(growable: false);
    } catch (_) {
      return const <TmdbTrendingItem>[];
    }
  }

  static Future<List<TmdbCatalogItem>> curated(String shelf) {
    if (_key.trim().isEmpty) {
      return Future.value(const <TmdbCatalogItem>[]);
    }
    return _curatedCache.putIfAbsent(shelf, () => _fetchCurated(shelf));
  }

  static Future<List<TmdbCatalogItem>> _fetchCurated(String shelf) async {
    final now = DateTime.now().toUtc();
    final recent = now.subtract(const Duration(days: 120));
    final fresh = now.subtract(const Duration(days: 45));

    switch (shelf) {
      case 'Trending Now':
        return _trendingAllDay();
      case 'What\'s Hot':
        return _discoverBoth(sortBy: 'popularity.desc');
      case 'Must Watch':
        return _discoverBoth(sortBy: 'vote_average.desc', voteCountGte: 200);
      case 'Popular Picks':
        return _discoverBoth(sortBy: 'vote_count.desc');
      case 'New & Noteworthy':
        return _discoverBoth(sortBy: 'popularity.desc', releaseGte: recent);
      case 'Fan Favorites':
        return _discoverBoth(sortBy: 'vote_count.desc', voteCountGte: 500);
      case 'Critics\' Choice':
        return _discoverBoth(sortBy: 'vote_average.desc', voteCountGte: 1000);
      case 'Late Night Picks':
        return _discoverBoth(
          sortBy: 'popularity.desc',
          genres: '27|53|80|9648',
        );
      case 'Fresh Releases':
        return _discoverBoth(sortBy: 'popularity.desc', releaseGte: fresh);
      case 'Editor\'s Picks':
        return _discoverBoth(sortBy: 'popularity.desc', voteCountGte: 100);
      default:
        return const <TmdbCatalogItem>[];
    }
  }

  static Future<List<TmdbCatalogItem>> _trendingAllDay() async {
    try {
      final responses = await Future.wait([
        _getJson('$_base/trending/movie/day?api_key=$_key&language=en-IN'),
        _getJson('$_base/trending/tv/day?api_key=$_key&language=en-IN'),
      ]);
      final items = <TmdbCatalogItem>[
        ..._parseCatalogResults(responses[0], 'movie'),
        ..._parseCatalogResults(responses[1], 'tv'),
      ];
      items.sort((a, b) => b.popularity.compareTo(a.popularity));
      return items.take(60).toList(growable: false);
    } catch (_) {
      return const <TmdbCatalogItem>[];
    }
  }

  static Future<List<TmdbCatalogItem>> _discoverBoth({
    required String sortBy,
    int? voteCountGte,
    DateTime? releaseGte,
    String? genres,
  }) async {
    try {
      final responses = await Future.wait([
        _getJson(_discoverUri(
          'movie',
          sortBy: sortBy,
          voteCountGte: voteCountGte,
          releaseGte: releaseGte,
          genres: genres,
        ).toString()),
        _getJson(_discoverUri(
          'tv',
          sortBy: sortBy,
          voteCountGte: voteCountGte,
          releaseGte: releaseGte,
          genres: genres,
        ).toString()),
      ]);
      final items = <TmdbCatalogItem>[
        ..._parseCatalogResults(responses[0], 'movie'),
        ..._parseCatalogResults(responses[1], 'tv'),
      ];
      items.sort((a, b) => b.score.compareTo(a.score));
      return items.take(60).toList(growable: false);
    } catch (_) {
      return const <TmdbCatalogItem>[];
    }
  }

  static Uri _discoverUri(
    String kind, {
    required String sortBy,
    int? voteCountGte,
    DateTime? releaseGte,
    String? genres,
  }) {
    final params = <String, String>{
      'api_key': _key,
      'language': 'en-IN',
      'region': 'IN',
      'include_adult': 'false',
      'sort_by': sortBy,
      'page': '1',
    };
    if (kind == 'tv') {
      params['include_null_first_air_dates'] = 'false';
      if (releaseGte != null) params['first_air_date.gte'] = _date(releaseGte);
    } else if (releaseGte != null) {
      params['primary_release_date.gte'] = _date(releaseGte);
    }
    if (voteCountGte != null) params['vote_count.gte'] = '$voteCountGte';
    if (genres != null) params['with_genres'] = genres;
    return Uri.parse('$_base/discover/$kind').replace(queryParameters: params);
  }

  static Future<Map<String, dynamic>> _getJson(String url) async {
    final response = await http.get(Uri.parse(url)).timeout(
      const Duration(seconds: 10),
    );
    if (response.statusCode != 200) return const <String, dynamic>{};
    final decoded = jsonDecode(response.body);
    return decoded is Map
        ? decoded.cast<String, dynamic>()
        : const <String, dynamic>{};
  }

  static List<TmdbCatalogItem> _parseCatalogResults(
    Map<String, dynamic> json,
    String kind,
  ) {
    final raw = (json['results'] as List?) ?? const [];
    return raw.whereType<Map>().map((item) {
      final j = item.cast<String, dynamic>();
      final release =
          (j['release_date'] ?? j['first_air_date'] ?? '').toString();
      return TmdbCatalogItem(
        id: (j['id'] as num?)?.toInt() ?? 0,
        kind: kind,
        title: (j['title'] ??
                j['name'] ??
                j['original_title'] ??
                j['original_name'] ??
                '')
            .toString()
            .trim(),
        poster: _path(j['poster_path'], 'w500'),
        backdrop: _path(j['backdrop_path'], 'w1280'),
        releaseDate: release,
        popularity: (j['popularity'] as num?)?.toDouble() ?? 0,
        rating: (j['vote_average'] as num?)?.toDouble() ?? 0,
        voteCount: (j['vote_count'] as num?)?.toInt() ?? 0,
      );
    }).where((item) => item.title.isNotEmpty && item.poster.isNotEmpty).toList(
          growable: false,
        );
  }

  static String _date(DateTime value) =>
      '${value.year.toString().padLeft(4, '0')}-'
      '${value.month.toString().padLeft(2, '0')}-'
      '${value.day.toString().padLeft(2, '0')}';

  static Future<TmdbInfo?> _lookup(String kind, String rawName) {
    if (_key.trim().isEmpty) return Future.value(null);
    final title = _clean(rawName);
    if (title.isEmpty) return Future.value(null);
    final year = _year(rawName);
    return _cache.putIfAbsent(
      '$kind:$title:$year',
      () => _fetch(kind, title, year),
    );
  }

  static Future<TmdbInfo?> _fetch(String kind, String title, int? year) async {
    try {
      final yearParam = year == null
          ? ''
          : (kind == 'movie' ? '&year=$year' : '&first_air_date_year=$year');
      final search = Uri.parse(
        '$_base/search/$kind'
        '?api_key=$_key'
        '&query=${Uri.encodeQueryComponent(title)}'
        '$yearParam'
        '&include_adult=false'
        '&language=en-IN',
      );
      final sr = await http.get(search).timeout(const Duration(seconds: 10));
      if (sr.statusCode != 200) return null;
      final results = (jsonDecode(sr.body)['results'] as List?) ?? [];
      if (results.isEmpty) return null;
      final id = results.first['id'];

      final detail = Uri.parse(
        '$_base/$kind/$id'
        '?api_key=$_key'
        '&append_to_response=credits,videos'
        '&language=en-IN',
      );
      final dr = await http.get(detail).timeout(const Duration(seconds: 10));
      if (dr.statusCode != 200) return null;
      final j = jsonDecode(dr.body) as Map<String, dynamic>;

      final genres = ((j['genres'] as List?) ?? [])
          .map((g) => g['name'])
          .whereType<String>()
          .take(3)
          .join(', ');
      final cast = (((j['credits'] ?? {})['cast'] as List?) ?? [])
          .map((c) => c['name'])
          .whereType<String>()
          .take(5)
          .join(', ');
      String? trailer;
      final vids = (((j['videos'] ?? {})['results'] as List?) ?? []);
      for (final v in vids) {
        if (v['site'] == 'YouTube' &&
            (v['type'] == 'Trailer' || v['type'] == 'Teaser')) {
          trailer = v['key'];
          if (v['type'] == 'Trailer') break;
        }
      }

      return TmdbInfo(
        title: (j['title'] ?? j['name'] ?? title).toString(),
        overview: (j['overview'] ?? '') as String,
        backdrop: _path(j['backdrop_path'], 'w1280'),
        poster: _path(j['poster_path'], 'w500'),
        rating: (j['vote_average'] is num)
            ? (j['vote_average'] as num).toDouble()
            : 0,
        releaseDate: (j['release_date'] ?? j['first_air_date'] ?? '') as String,
        genres: genres,
        cast: cast,
        trailerKey: trailer,
      );
    } catch (_) {
      return null;
    }
  }

  static String _path(dynamic p, String size) =>
      (p is String && p.isNotEmpty) ? '$img/$size$p' : '';

  static String _clean(String raw) {
    var s = raw;
    s = s.replaceFirst(
      RegExp(r'^\s*[A-Z]{2,3}\s*[|:\-]\s*'),
      '',
    );
    s = s.replaceAll(RegExp(r'\[[^\]]*\]'), ' ');
    s = s.replaceAll(RegExp(r'\([^)]*\)'), ' ');
    s = s.replaceAll(
      RegExp(
        r'\b(4K|UHD|FHD|HD|SD|HEVC|H ?265|H ?264|x265|x264|MULTI|DUAL|SUB|DUB|VOSTFR)\b',
        caseSensitive: false,
      ),
      ' ',
    );
    s = s.replaceAll(RegExp(r'\b(19|20)\d{2}\b'), ' ');
    s = s.replaceAll(RegExp(r'[_\.]+'), ' ');
    s = s.replaceAll(RegExp(r'\s+'), ' ').trim();
    return s;
  }

  static int? _year(String raw) {
    final m = RegExp(r'(19|20)\d{2}').firstMatch(raw);
    return m == null ? null : int.tryParse(m.group(0)!);
  }
}

class TmdbTrendingItem {
  final int id;
  final String title;
  final String poster;
  final String backdrop;
  final String releaseDate;
  final double popularity;

  const TmdbTrendingItem({
    required this.id,
    required this.title,
    required this.poster,
    required this.backdrop,
    required this.releaseDate,
    required this.popularity,
  });

  factory TmdbTrendingItem.fromJson(Map<String, dynamic> j) {
    return TmdbTrendingItem(
      id: (j['id'] as num?)?.toInt() ?? 0,
      title: (j['name'] ?? j['original_name'] ?? '').toString().trim(),
      poster: Tmdb._path(j['poster_path'], 'w780'),
      backdrop: Tmdb._path(j['backdrop_path'], 'w1280'),
      releaseDate: (j['first_air_date'] ?? '').toString(),
      popularity: (j['popularity'] as num?)?.toDouble() ?? 0,
    );
  }

  String get year => RegExp(r'^(\d{4})').firstMatch(releaseDate)?.group(1) ?? '';
}

class TmdbCatalogItem {
  final int id;
  final String kind;
  final String title;
  final String poster;
  final String backdrop;
  final String releaseDate;
  final double popularity;
  final double rating;
  final int voteCount;

  const TmdbCatalogItem({
    required this.id,
    required this.kind,
    required this.title,
    required this.poster,
    required this.backdrop,
    required this.releaseDate,
    required this.popularity,
    required this.rating,
    required this.voteCount,
  });

  String get year =>
      RegExp(r'^(\d{4})').firstMatch(releaseDate)?.group(1) ?? '';

  double get score =>
      popularity + rating * 12 + math.min(voteCount, 5000) / 5000;
}

class TmdbInfo {
  final String title;
  final String overview, backdrop, poster, releaseDate, genres, cast;
  final double rating;
  final String? trailerKey;

  TmdbInfo({
    required this.title,
    required this.overview,
    required this.backdrop,
    required this.poster,
    required this.releaseDate,
    required this.genres,
    required this.cast,
    required this.rating,
    this.trailerKey,
  });

  String get year =>
      RegExp(r'^(\d{4})').firstMatch(releaseDate)?.group(1) ?? '';

  String? get trailerUrl =>
      trailerKey == null ? null : 'https://www.youtube.com/watch?v=$trailerKey';
}
