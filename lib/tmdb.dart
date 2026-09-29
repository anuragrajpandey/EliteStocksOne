import 'dart:convert';
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

  static Future<TmdbInfo?> movie(String rawName) => _lookup('movie', rawName);
  static Future<TmdbInfo?> tv(String rawName) => _lookup('tv', rawName);

  /// Returns the current TMDB popularity leaders for TV that have availability
  /// data for India. TMDB's discover endpoint supports [watch_region] together
  /// with monetisation/provider filters, which is the closest regional
  /// equivalent to a "trending in India" shelf.
  static Future<List<TmdbTrendingItem>> trendingTvIndia() {
    if (_key.trim().isEmpty) {
      return Future.value(const <TmdbTrendingItem>[]);
    }
    return _indiaTvFuture ??= _fetchTrendingTvIndia();
  }

  static Future<List<TmdbTrendingItem>> _fetchTrendingTvIndia() async {
    try {
      final uri = Uri.parse(
        '$_base/discover/tv'
        '?api_key=$_key'
        '&language=en-IN'
        '&watch_region=IN'
        '&with_watch_monetization_types=flatrate%7Cfree%7Cads%7Crent%7Cbuy'
        '&sort_by=popularity.desc'
        '&include_adult=false'
        '&page=1',
      );
      final response = await http.get(uri).timeout(const Duration(seconds: 10));
      if (response.statusCode != 200) return const <TmdbTrendingItem>[];
      final raw = (jsonDecode(response.body)['results'] as List?) ?? const [];
      return raw
          .whereType<Map>()
          .map((item) => TmdbTrendingItem.fromJson(
                item.cast<String, dynamic>(),
              ))
          .where((item) => item.title.isNotEmpty && item.poster.isNotEmpty)
          .take(10)
          .toList(growable: false);
    } catch (_) {
      return const <TmdbTrendingItem>[];
    }
  }

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
