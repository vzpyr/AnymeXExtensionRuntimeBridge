import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:http/http.dart' as http;
import 'package:path/path.dart' as path;
import 'package:path_provider/path_provider.dart';
import '../../Logger.dart';
import '../../Settings/KvStore.dart';
import '../../anymex_extension_runtime_bridge.dart';
import '../Mangayomi/Eval/dart/model/filter.dart';
import 'Models/Source.dart';

class AniyomiSourceMethods extends SourceMethods {
  @override
  final ASource source;

  AniyomiSourceMethods(Source source) : source = source as ASource;

  static const platform = MethodChannel('aniyomiExtensionBridge');

  bool get isAnime => source.itemType?.index == 1;

  Future<String> _getApkBase64() async {
    String? apkPath = source.apkPath;
    if (apkPath == null || !File(apkPath).existsSync()) {
      final docDir = await getApplicationDocumentsDirectory();
      final candidate = File(path.join(docDir.path, 'Aniyomi', 'extensions', '${source.pkgName}.apk'));
      if (candidate.existsSync()) {
        apkPath = candidate.path;
      }
    }
    if (apkPath == null || !File(apkPath).existsSync()) {
      throw Exception('APK not found locally. Please reinstall the extension.');
    }
    return base64Encode(await File(apkPath).readAsBytes());
  }

  Future<dynamic> _invokeZero(String method, Map<String, dynamic> params) async {
    final port = getVal<int>('zero_server_port') ?? 8080;
    final url = 'http://127.0.0.1:$port/dalvik';
    final base64Apk = await _getApkBase64();
    final body = jsonEncode({
      'method': method,
      'data': base64Apk,
      ...params,
    });
    final res = await http.post(
      Uri.parse(url),
      headers: {'Content-Type': 'application/json'},
      body: body,
    ).timeout(const Duration(seconds: 45));
    if (res.statusCode != 200) {
      throw Exception('Zero interpreter returned HTTP ${res.statusCode}');
    }
    return jsonDecode(res.body);
  }

  List<String> _parseGenre(dynamic genreData) {
    if (genreData is String) {
      return genreData.split(',').map((e) => e.trim()).where((e) => e.isNotEmpty).toList();
    } else if (genreData is List) {
      return genreData.map((e) => e.toString()).toList();
    }
    return [];
  }

  Map<String, String>? _parseHeaders(dynamic headersData) {
    if (headersData is Map) {
      if (headersData.containsKey('namesAndValues\$okhttp')) {
        final arr = headersData['namesAndValues\$okhttp'] as List? ?? [];
        final Map<String, String> parsed = {};
        for (int i = 0; i < arr.length; i += 2) {
          if (i + 1 < arr.length) {
            parsed[arr[i].toString()] = arr[i + 1].toString();
          }
        }
        return parsed.isNotEmpty ? parsed : null;
      }
      return headersData.map((key, value) => MapEntry(key.toString(), value.toString()));
    }
    return null;
  }

  Pages _mapPages(Map<String, dynamic> json) {
    final list = json['animes'] as List? ?? json['mangas'] as List? ?? json['list'] as List? ?? [];
    final hasNextPage = json['hasNextPage'] ?? false;
    final mediaList = list.map((e) {
      final m = Map<String, dynamic>.from(e);
      return DMedia(
        title: m['title'] ?? m['name'] ?? '',
        url: m['url'] ?? m['link'] ?? '',
        cover: m['thumbnail_url'] ?? m['imageUrl'] ?? '',
        description: m['description'] ?? '',
        author: m['author'] ?? '',
        artist: m['artist'] ?? '',
        genre: _parseGenre(m['genre']),
      );
    }).toList();
    return Pages(list: mediaList, hasNextPage: hasNextPage);
  }

  @override
  Future<DMedia> getDetail(DMedia media, {SourceParams? parameters}) async {
    if (Platform.isIOS) {
      final details = await _invokeZero(isAnime ? 'getDetailsAnime' : 'getDetailsManga', {
        (isAnime ? 'animeData' : 'mangaData'): {'url': media.url, 'title': media.title},
      });
      final m = Map<String, dynamic>.from(details);
      final episodesRes = await _invokeZero(isAnime ? 'getEpisodeList' : 'getChapterList', {
        (isAnime ? 'animeData' : 'mangaData'): {'url': media.url, 'title': media.title},
      });
      final chaptersList = episodesRes as List? ?? [];
      final episodes = chaptersList.map((e) {
        final c = Map<String, dynamic>.from(e);
        return DEpisode(
          name: c['name'] ?? '',
          url: c['url'] ?? '',
          dateUpload: c['date_upload']?.toString() ?? c['dateUpload']?.toString() ?? '',
          scanlator: c['scanlator'] ?? '',
          episodeNumber: c['episode_number']?.toString() ?? c['chapter_number']?.toString() ?? '1',
        );
      }).toList();

      return DMedia(
        title: m['title'] ?? m['name'] ?? media.title,
        url: m['url'] ?? m['link'] ?? media.url,
        cover: m['thumbnail_url'] ?? m['imageUrl'] ?? media.cover,
        description: m['description'] ?? media.description,
        author: m['author'] ?? media.author,
        artist: m['artist'] ?? media.artist,
        genre: _parseGenre(m['genre']),
        episodes: episodes,
      );
    }

    final result = await platform.invokeMethod('getDetail', {
      'sourceId': source.id,
      'isAnime': isAnime,
      'media': {
        'title': media.title,
        'url': media.url,
        'thumbnail_url': media.cover,
        'description': media.description,
        'author': media.author,
        'artist': media.artist,
        'genre': media.genre,
      },
      if (parameters != null) 'parameters': parameters.toJson(),
    });

    return await compute(
      DMedia.fromJson,
      Map<String, dynamic>.from(result as Map),
    );
  }

  @override
  Future<Pages> getLatestUpdates(int page, {SourceParams? parameters}) async {
    if (Platform.isIOS) {
      final result = await _invokeZero(isAnime ? 'getLatestAnime' : 'getLatestManga', {
        'page': page,
      });
      return _mapPages(Map<String, dynamic>.from(result));
    }

    final result = await platform.invokeMethod('getLatestUpdates', {
      'sourceId': source.id,
      'isAnime': isAnime,
      'page': page,
      if (parameters != null) 'parameters': parameters.toJson(),
    });

    return await compute(
      Pages.fromJson,
      Map<String, dynamic>.from(result as Map),
    );
  }

  @override
  Future<Pages> getPopular(int page, {SourceParams? parameters}) async {
    if (Platform.isIOS) {
      final result = await _invokeZero(isAnime ? 'getPopularAnime' : 'getPopularManga', {
        'page': page,
        'search': '',
      });
      return _mapPages(Map<String, dynamic>.from(result));
    }

    final result = await platform.invokeMethod('getPopular', {
      'sourceId': source.id,
      'isAnime': isAnime,
      'page': page,
      if (parameters != null) 'parameters': parameters.toJson(),
    });

    return await compute(
      Pages.fromJson,
      Map<String, dynamic>.from(result as Map),
    );
  }

  @override
  Future<List<Video>> getVideoList(DEpisode episode,
      {SourceParams? parameters}) async {
    if (Platform.isIOS) {
      final result = await _invokeZero('getVideoList', {
        'episodeData': {'url': episode.url, 'name': episode.name},
      });
      final list = result as List? ?? [];
      return list.map((e) {
        final v = Map<String, dynamic>.from(e);
        final audios = (v['audios'] as List?)?.map((a) {
          final tr = Map<String, dynamic>.from(a);
          return Track(file: tr['file'] ?? '', label: tr['label'] ?? '');
        }).toList();
        final subtitles = (v['subtitles'] as List?)?.map((s) {
          final tr = Map<String, dynamic>.from(s);
          return Track(file: tr['file'] ?? '', label: tr['label'] ?? '');
        }).toList();
        return Video(
          v['quality'] ?? 'Unknown Server',
          v['videoUrl'] ?? v['url'] ?? '',
          v['quality'] ?? 'Unknown Quality',
          headers: _parseHeaders(v['headers']),
          audios: audios,
          subtitles: subtitles,
        );
      }).toList();
    }

    final result = await platform.invokeMethod('getVideoList', {
      'sourceId': source.id,
      'isAnime': isAnime,
      'episode': {
        'name': episode.name,
        'url': episode.url,
        'date_upload': episode.dateUpload,
        'description': episode.description,
        'episode_number': episode.episodeNumber,
        'scanlator': episode.scanlator,
      },
      if (parameters != null) 'parameters': parameters.toJson(),
    });

    return await compute(parseVideos, List<dynamic>.from(result));
  }

  @override
  Future<void> stopHttpServer() async {
    try {
      if (Platform.isIOS) return;
      await platform.invokeMethod('stopHttpServer', {
        'sourceId': source.id,
        'isAnime': isAnime,
      });
    } catch (e) {
      Logger.log("Failed to stop http server: $e");
    }
  }

  @override
  Future<List<PageUrl>> getPageList(DEpisode episode,
      {SourceParams? parameters}) async {
    if (Platform.isIOS) {
      final result = await _invokeZero('getPageList', {
        'chapterData': {'url': episode.url, 'name': episode.name},
      });
      final list = result as List? ?? [];
      return list.map((e) {
        final p = Map<String, dynamic>.from(e);
        return PageUrl(p['imageUrl'] ?? p['url'] ?? '', headers: _parseHeaders(p['headers']));
      }).toList();
    }

    final result = await platform.invokeMethod('getPageList', {
      'sourceId': source.id,
      'isAnime': isAnime,
      'episode': {
        'name': episode.name,
        'url': episode.url,
        'date_upload': episode.dateUpload,
        'description': episode.description,
        'episode_number': episode.episodeNumber,
        'scanlator': episode.scanlator,
      },
      if (parameters != null) 'parameters': parameters.toJson(),
    });

    return compute(parsePageUrls, List<dynamic>.from(result));
  }

  @override
  Future<Pages> search(String query, int page, List filters,
      {SourceParams? parameters}) async {
    if (Platform.isIOS) {
      final result = await _invokeZero(isAnime ? 'getSearchAnime' : 'getSearchManga', {
        'page': page,
        'search': query,
      });
      return _mapPages(Map<String, dynamic>.from(result));
    }

    final mappedFilters = filters.map((f) {
      if (f is Map) return f;
      return _mapClassToAniyomiFilter(f);
    }).where((f) => f != null).toList();

    final result = await platform.invokeMethod('search', {
      'sourceId': source.id,
      'isAnime': isAnime,
      'query': query,
      'page': page,
      'filters': mappedFilters,
      if (parameters != null) 'parameters': parameters.toJson(),
    });

    return await compute(
      Pages.fromJson,
      Map<String, dynamic>.from(result as Map),
    );
  }

  @override
  Future<List<dynamic>> getFilterList() async {
    try {
      final result = await platform.invokeMethod('getFilterList', {
        'sourceId': source.id,
        'isAnime': isAnime,
      });
      final list = result as List<dynamic>;
      return list
          .map((f) => _mapAniyomiFilterToClass(Map<dynamic, dynamic>.from(f)))
          .where((f) => f != null)
          .toList();
    } catch (e) {
      Logger.log('AniyomiSourceMethods getFilterList error: $e');
      return [];
    }
  }

  dynamic _mapAniyomiFilterToClass(Map<dynamic, dynamic> map) {
    final name = map['name'] as String? ?? '';
    final type = map['type'] as String? ?? '';
    final state = map['state'];
    final values = map['values'] as List<dynamic>?;

    switch (type) {
      case 'Header':
        return HeaderFilter(name, 'HeaderFilter', type: '');
      case 'Separator':
        return SeparatorFilter('SeparatorFilter', type: '');
      case 'CheckBox':
        return CheckBoxFilter(
          '', name, name, 'CheckBox',
          state: state is bool ? state : false,
        );
      case 'TriState':
        return TriStateFilter(
          '', name, name, 'TriState',
          state: state is int ? state : 0,
        );
      case 'Select':
        final selectOptions = values
                ?.map((v) => SelectFilterOption(v.toString(), v.toString(), 'SelectOption'))
                .toList() ??
            [];
        return SelectFilter(
          '', name, state is int ? state : 0, selectOptions, 'SelectFilter',
        );
      case 'Sort':
        final selectOptions = values
                ?.map((v) => SelectFilterOption(v.toString(), v.toString(), 'SelectOption'))
                .toList() ??
            [];
        SortState sortState;
        if (state is Map) {
          sortState = SortState(
            state['index'] is int ? state['index'] : 0,
            state['ascending'] is bool ? state['ascending'] : true,
            'SortState',
          );
        } else {
          sortState = SortState(0, true, 'SortState');
        }
        return SortFilter(
          '', name, sortState, selectOptions, 'SortFilter',
        );
      case 'Text':
        return TextFilter(
          '', name, 'TextFilter',
          state: state is String ? state : '',
        );
      case 'Group':
        final subFilters = (state as List<dynamic>?)
                ?.map((sub) => _mapAniyomiFilterToClass(Map<dynamic, dynamic>.from(sub)))
                .where((f) => f != null)
                .toList() ??
            [];
        return GroupFilter(
          '', name, subFilters, 'GroupFilter',
        );
      default:
        return null;
    }
  }

  Map<String, dynamic>? _mapClassToAniyomiFilter(dynamic filter) {
    if (filter is HeaderFilter) {
      return {
        'name': filter.name,
        'type': 'Header',
        'state': null,
      };
    } else if (filter is SeparatorFilter) {
      return {
        'name': '',
        'type': 'Separator',
        'state': null,
      };
    } else if (filter is CheckBoxFilter) {
      return {
        'name': filter.name,
        'type': 'CheckBox',
        'state': filter.state,
      };
    } else if (filter is TriStateFilter) {
      return {
        'name': filter.name,
        'type': 'TriState',
        'state': filter.state,
      };
    } else if (filter is SelectFilter) {
      return {
        'name': filter.name,
        'type': 'Select',
        'state': filter.state,
      };
    } else if (filter is SortFilter) {
      return {
        'name': filter.name,
        'type': 'Sort',
        'state': {
          'index': filter.state.index,
          'ascending': filter.state.ascending,
        },
      };
    } else if (filter is TextFilter) {
      return {
        'name': filter.name,
        'type': 'Text',
        'state': filter.state,
      };
    } else if (filter is GroupFilter) {
      return {
        'name': filter.name,
        'type': 'Group',
        'state': filter.state.map((sub) => _mapClassToAniyomiFilter(sub)).toList(),
      };
    }
    return null;
  }

  List<Video> parseVideos(List<dynamic> list) {
    return list
        .map((e) => Video.fromJson(Map<String, dynamic>.from(e)))
        .toList();
  }

  List<PageUrl> parsePageUrls(List<dynamic> list) {
    return list
        .map((e) => PageUrl.fromJson(Map<String, dynamic>.from(e)))
        .toList();
  }

  @override
  Future<String?> getNovelContent(String chapterTitle, String chapterId,
      {SourceParams? parameters}) {
    throw UnimplementedError();
  }

  @override
  Future<void> cancelRequest(String token) async {
    await AnymeXRuntimeBridge.cancelRequest(token);
  }

  @override
  Future<List<SourcePreference>> getPreference() async {
    if (Platform.isIOS) {
      try {
        final result = await _invokeZero(isAnime ? 'getPreferencesAnime' : 'getPreferencesManga', {});
        if (result is List) {
          return result.map((e) {
            final map = Map<String, dynamic>.from(e);
            if (map.containsKey('checkBoxPreference')) map['type'] = 'checkbox';
            if (map.containsKey('switchPreferenceCompat')) map['type'] = 'switch';
            if (map.containsKey('listPreference')) map['type'] = 'list';
            if (map.containsKey('multiSelectListPreference')) map['type'] = 'multi_select';
            if (map.containsKey('editTextPreference')) map['type'] = 'text';
            return mapToSourcePreference(map);
          }).toList();
        }
      } catch (_) {}
      return const [];
    }

    final result = await platform.invokeMethod("getPreference", {
      'sourceId': source.id,
      'isAnime': isAnime,
    });

    if (result == null) return const [];

    if (result is String) return const [];

    return List<dynamic>.from(
      result,
    ).map((e) => mapToSourcePreference(Map<String, dynamic>.from(e))).toList();
  }

  @override
  Future<bool> setPreference(SourcePreference pref, dynamic value) async {
    if (Platform.isIOS) {
      try {
        await _invokeZero(isAnime ? 'setPreferenceAnime' : 'setPreferenceManga', {
          'preferenceData': {
            'key': pref.key,
            'value': value,
          },
        });
        return true;
      } catch (_) {
        return false;
      }
    }

    final result = await platform.invokeMethod('saveSourcePreference', {
      'sourceId': source.id,
      'key': pref.key,
      'value': value,
    });
    return result;
  }
}

SourcePreference mapToSourcePreference(Map<String, dynamic> json) {
  final type = json['type'] as String?;
  switch (type) {
    case 'checkbox':
      return SourcePreference(
        key: json['key'],
        type: type,
        checkBoxPreference: CheckBoxPreference(
          title: json['title'],
          summary: json['summary'],
          value: json['value'],
        ),
      );

    case 'switch':
      return SourcePreference(
        key: json['key'],
        type: type,
        switchPreferenceCompat: SwitchPreferenceCompat(
          title: json['title'],
          summary: json['summary'],
          value: json['value'],
        ),
      );

    case 'list':
      final entries =
          (json['entries'] as List?)?.map((e) => e.toString()).toList();
      final entryValues =
          (json['entryValues'] as List?)?.map((e) => e.toString()).toList();
      final valueIndex = entryValues?.indexOf(json['value']?.toString() ?? '');
      return SourcePreference(
        key: json['key'],
        type: type,
        listPreference: ListPreference(
          title: json['title'],
          summary: json['summary'],
          entries: entries,
          entryValues: entryValues,
          valueIndex: valueIndex != -1 ? valueIndex : 0,
          value: json['value']?.toString(),
        ),
      );

    case 'multi_select':
      final entries =
          (json['entries'] as List?)?.map((e) => e.toString()).toList();
      final entryValues =
          (json['entryValues'] as List?)?.map((e) => e.toString()).toList();
      final values =
          (json['value'] as List?)?.map((e) => e.toString()).toList() ?? [];
      return SourcePreference(
        key: json['key'],
        type: type,
        multiSelectListPreference: MultiSelectListPreference(
          title: json['title'],
          summary: json['summary'],
          entries: entries,
          entryValues: entryValues,
          values: values,
        ),
      );

    case 'text':
      return SourcePreference(
        key: json['key'],
        type: type,
        editTextPreference: EditTextPreference(
          title: json['title'],
          summary: json['summary'],
          value: json['value']?.toString(),
        ),
      );

    default:
      return SourcePreference(key: json['key']);
  }
}
