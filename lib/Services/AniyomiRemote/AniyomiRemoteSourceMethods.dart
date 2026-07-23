import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;
import 'package:http/http.dart' as http;

import '../../anymex_extension_runtime_bridge.dart';
import '../Aniyomi/Models/Source.dart';
import '../../Logger.dart';
import '../../Settings/KvStore.dart';
import '../../Runtime/RuntimePaths.dart';

class AniyomiRemoteSourceMethods extends SourceMethods {
  @override
  final ASource source;

  AniyomiRemoteSourceMethods(Source source) : source = source as ASource;

  bool get isAnime => source.itemType == ItemType.anime;

  Future<String> _getExtensionsPath(String subFolder) async {
    final dir = await RuntimePaths().extensionsDir;
    final targetDir = Directory(p.join(dir.path, subFolder));
    if (!await targetDir.exists()) {
      await targetDir.create(recursive: true);
    }
    return targetDir.path;
  }

  Future<String> _getApkBase64() async {
    final pkgName = source.pkgName ?? source.apkName?.replaceAll('.apk', '') ?? 'unknown_ext';
    final extDir = await _getExtensionsPath('AniyomiRemote');
    final apkPath = p.join(extDir, '$pkgName.apk');
    if (!File(apkPath).existsSync()) {
      throw Exception("APK not found locally at $apkPath. Please reinstall the extension.");
    }
    final bytes = await File(apkPath).readAsBytes();
    return base64Encode(bytes);
  }

  Future<dynamic> _invokeRemote(String fullMethod, Map<String, dynamic> additionalParams) async {
    final proxyUrl = getVal<String>('aniyomi_remote_proxy_url');
    if (proxyUrl == null || proxyUrl.isEmpty) {
      throw Exception("Proxy Server URL is not configured in settings. Go to Settings > Extensions to set it.");
    }

    final base64Apk = await _getApkBase64();

    final payload = {
      "method": fullMethod,
      "data": base64Apk,
      ...additionalParams,
    };

    final response = await http.post(
      Uri.parse("$proxyUrl/dalvik"),
      headers: {"Content-Type": "application/json"},
      body: jsonEncode(payload),
    ).timeout(const Duration(seconds: 45));

    if (response.statusCode != 200) {
      throw Exception("Proxy returned error: ${response.statusCode}");
    }

    return jsonDecode(response.body);
  }

  List<String> _parseGenre(dynamic genreData) {
    if (genreData is String) {
      return genreData.split(',').map((e) => e.trim()).toList();
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
    final detailsMethod = isAnime ? 'getDetailsAnime' : 'getDetailsManga';
    final dataKey = isAnime ? 'animeData' : 'mangaData';
    final mediaData = {
      "url": media.url,
      "title": media.title,
    };

    final detailsResult = await _invokeRemote(detailsMethod, {
      dataKey: mediaData,
    });
    final m = Map<String, dynamic>.from(detailsResult);

    final episodesMethod = isAnime ? 'getEpisodeList' : 'getChapterList';
    final episodesResult = await _invokeRemote(episodesMethod, {
      dataKey: mediaData,
    });
    
    final chaptersList = episodesResult as List? ?? [];
    
    final episodes = chaptersList.map((e) {
      final c = Map<String, dynamic>.from(e);
      return DEpisode(
        name: c['name'] ?? '',
        url: c['url'] ?? '',
        dateUpload: c['date_upload']?.toString() ?? c['dateUpload']?.toString() ?? '',
        scanlator: c['scanlator'] ?? '',
        episodeNumber: c['episode_number']?.toString() ?? c['chapter_number']?.toString() ?? c['episodeNumber']?.toString() ?? '1',
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
      episodes: episodes.cast<DEpisode>(),
    );
  }

  @override
  Future<Pages> getLatestUpdates(int page, {SourceParams? parameters}) async {
    final result = await _invokeRemote(isAnime ? 'getLatestAnime' : 'getLatestManga', {
      "page": page,
    });
    return _mapPages(Map<String, dynamic>.from(result));
  }

  @override
  Future<Pages> getPopular(int page, {SourceParams? parameters}) async {
    final result = await _invokeRemote(isAnime ? 'getPopularAnime' : 'getPopularManga', {
      "page": page,
      "search": "",
    });
    return _mapPages(Map<String, dynamic>.from(result));
  }

  @override
  Future<List<Video>> getVideoList(DEpisode episode, {SourceParams? parameters}) async {
    final result = await _invokeRemote('getVideoList', {
      "episodeData": {
        "url": episode.url,
        "name": episode.name,
      }
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

  @override
  Future<List<PageUrl>> getPageList(DEpisode episode, {SourceParams? parameters}) async {
    final result = await _invokeRemote('getPageList', {
      "chapterData": {
        "url": episode.url,
        "name": episode.name,
      }
    });
    
    final list = result as List? ?? [];
    return list.map((e) {
      final p = Map<String, dynamic>.from(e);
      return PageUrl(p['imageUrl'] ?? p['url'] ?? '', headers: _parseHeaders(p['headers']));
    }).toList();
  }

  @override
  Future<Pages> search(String query, int page, List filters, {SourceParams? parameters}) async {
    final result = await _invokeRemote(isAnime ? 'getSearchAnime' : 'getSearchManga', {
      "page": page,
      "search": query,
    });
    return _mapPages(Map<String, dynamic>.from(result));
  }

  @override
  Future<void> cancelRequest(String token) async {}

  @override
  Future<String?> getNovelContent(String chapterTitle, String chapterId, {SourceParams? parameters}) async {
    return null;
  }

  @override
  Future<List<SourcePreference>> getPreference() async {
    try {
      final result = await _invokeRemote('getPreferencesAnime', {});
      if (result is List) {
        return result.map((e) {
          final map = Map<String, dynamic>.from(e);
          if (map.containsKey('checkBoxPreference')) map['type'] = 'checkbox';
          if (map.containsKey('switchPreferenceCompat')) map['type'] = 'switch';
          if (map.containsKey('listPreference')) map['type'] = 'list';
          if (map.containsKey('multiSelectListPreference')) map['type'] = 'multi_select';
          if (map.containsKey('editTextPreference')) map['type'] = 'text';
          return SourcePreference.fromJson(map);
        }).toList();
      }
    } catch (_) {}
    return [];
  }

  @override
  Future<bool> setPreference(SourcePreference pref, dynamic value) async {
    try {
      await _invokeRemote('setPreferenceAnime', {
        'preferenceData': {
          'key': pref.key,
          'value': value,
        }
      });
      return true;
    } catch (_) {
      return false;
    }
  }
}
