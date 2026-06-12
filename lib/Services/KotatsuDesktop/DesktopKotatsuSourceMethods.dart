import 'dart:async';
import 'dart:convert';
import 'package:flutter/foundation.dart';
import '../../anymex_extension_runtime_bridge.dart';

class DesktopKotatsuSourceMethods extends SourceMethods {
  @override
  final KotatsuSource source;

  DesktopKotatsuSourceMethods(Source source) : source = source as KotatsuSource;

  dynamic _decode(dynamic result) {
    if (result is String) {
      return jsonDecode(result);
    }
    return result;
  }

  @override
  Future<DMedia> getDetail(DMedia media, {SourceParams? parameters}) async {
    final result = await BridgeDispatcher().invokeMethod('kotatsuGetDetail', {
      'sourceId': source.id,
      'media': {
        'title': media.title,
        'url': media.url,
        'thumbnail_url': media.cover,
      },
    });

    final decoded = _decode(result);
    return await compute(
      DMedia.fromJson,
      Map<String, dynamic>.from(decoded as Map),
    );
  }

  @override
  Future<Pages> getLatestUpdates(int page, {SourceParams? parameters}) async {
    final result =
        await BridgeDispatcher().invokeMethod('kotatsuGetLatestUpdates', {
      'sourceId': source.id,
      'page': page,
    });

    final decoded = _decode(result);
    return await compute(
      Pages.fromJson,
      Map<String, dynamic>.from(decoded as Map),
    );
  }

  @override
  Future<Pages> getPopular(int page, {SourceParams? parameters}) async {
    final result = await BridgeDispatcher().invokeMethod('kotatsuGetPopular', {
      'sourceId': source.id,
      'page': page,
    });

    final decoded = _decode(result);
    return await compute(
      Pages.fromJson,
      Map<String, dynamic>.from(decoded as Map),
    );
  }

  @override
  Future<List<Video>> getVideoList(DEpisode episode,
      {SourceParams? parameters}) async {
    return const [];
  }

  @override
  Future<List<PageUrl>> getPageList(DEpisode episode,
      {SourceParams? parameters}) async {
    final result = await BridgeDispatcher().invokeMethod('kotatsuGetPageList', {
      'sourceId': source.id,
      'episode': {
        'name': episode.name,
        'url': episode.url,
      },
    });

    final decoded = _decode(result);
    return compute(parsePageUrls, List<dynamic>.from(decoded as List));
  }

  @override
  Future<Pages> search(String query, int page, List filters,
      {SourceParams? parameters}) async {
    final result = await BridgeDispatcher().invokeMethod('kotatsuSearch', {
      'sourceId': source.id,
      'query': query,
      'page': page,
    });

    final decoded = _decode(result);
    return await compute(
      Pages.fromJson,
      Map<String, dynamic>.from(decoded as Map),
    );
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
    return const [];
  }

  @override
  Future<bool> setPreference(SourcePreference pref, dynamic value) async {
    return false;
  }
}
