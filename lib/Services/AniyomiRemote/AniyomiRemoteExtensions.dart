import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;
import 'package:get/get.dart';

import '../../Logger.dart';
import '../../Settings/KvStore.dart';
import '../../Models/Source.dart';
import '../../Extensions/Extensions.dart';
import '../../Extensions/SourceMethods.dart';
import '../../Runtime/RuntimePaths.dart';
import '../../Runtime/DesktopExtensionBase.dart';
import '../Aniyomi/Models/Source.dart';
import '../Mangayomi/http/m_client.dart';
import 'AniyomiRemoteSourceMethods.dart';

class AniyomiRemoteExtensions extends DesktopExtensionBase {
  final _client = MClient.init();

  @override
  String get id => 'aniyomi-remote';

  @override
  String get name => 'Aniyomi (Remote Proxy)';

  @override
  bool get supportsNovel => false;

  @override
  bool get requiresPlugin => false;

  @override
  SourceMethods createSourceMethods(Source source) =>
      AniyomiRemoteSourceMethods(source);

  Future<String> _getExtensionsPath() async {
    return getExtensionsPath('AniyomiRemote');
  }

  @override
  Future<void> fetchInstalledAnimeExtensions() async {
    getInstalledRx(ItemType.anime).value = _loadInstalledFromStore(ItemType.anime);
  }

  @override
  Future<void> fetchInstalledMangaExtensions() async {
    getInstalledRx(ItemType.manga).value = _loadInstalledFromStore(ItemType.manga);
  }

  @override
  Future<void> fetchInstalledNovelExtensions() async {}

  List<ASource> _loadInstalledFromStore(ItemType type) {
    final key = 'aniyomi_remote_installed_${type.name}';
    final data = getVal<List<String>>(key);
    if (data == null || data.isEmpty) return [];
    try {
      final parsed = data.map((e) => ASource.fromJson(jsonDecode(e))).toList();
      for (var s in parsed) {
        s.managerId = id;
      }
      return parsed;
    } catch (e) {
      Logger.log('Error loading installed remote extensions: $e');
      return [];
    }
  }

  void _saveInstalledToStore(List<ASource> list, ItemType type) {
    final key = 'aniyomi_remote_installed_${type.name}';
    setVal(key, list.map((e) => jsonEncode(e.toJson())).toList());
  }

  @override
  Future<void> fetchAnimeExtensions() async {
    final res = await _fetchExtensions(ItemType.anime);
    getAvailableRx(ItemType.anime).value = res;
  }

  @override
  Future<void> fetchMangaExtensions() async {
    final res = await _fetchExtensions(ItemType.manga);
    getAvailableRx(ItemType.manga).value = res;
  }

  @override
  Future<void> fetchNovelExtensions() async {}

  Future<List<Source>> _fetchExtensions(ItemType type) async {
    final repos = _loadRepos(type);
    if (repos.isEmpty) return const [];

    getReposRx(type).value = repos;

    final results = await Future.wait(repos.map((r) => _fetchRepo(r, type)));
    final all = results.expand((e) => e).toList(growable: false);

    final installed = getInstalledRx(type).value;
    final installedIds = installed.map((e) => e.id).toSet();

    _detectUpdates(all.whereType<ASource>().toList(), type);

    getRawAvailableRx(type).value = List.unmodifiable(all);

    return List.unmodifiable(
      all.where((s) => !installedIds.contains(s.id)),
    );
  }

  Future<List<Source>> _fetchRepo(Repo repo, ItemType type) async {
    try {
      final res = await _client.get(Uri.parse(repo.url));
      if (res.statusCode != 200) return const [];
      return await compute(_parseExtensions, (res.body, repo.url, type));
    } catch (e) {
      Logger.log("Repo failed ${repo.url}: $e");
      return const [];
    }
  }

  static List<Source> _parseExtensions(
    (String body, String repoUrl, ItemType itemType) args,
  ) {
    final (body, repoUrl, targetType) = args;

    try {
      final decoded = jsonDecode(body);
      if (decoded is! List) return const [];

      final baseIconUrl = repoUrl.replaceAll('/index.min.json', '');
      final sources = <Source>[];

      for (final item in decoded) {
        final map = item as Map<String, dynamic>;
        final name = map['name'] as String? ?? '';

        final detectedType = name.startsWith('Aniyomi: ')
            ? ItemType.anime
            : name.startsWith('Tachiyomi: ')
                ? ItemType.manga
                : null;

        if (detectedType != targetType) continue;

        sources.add(
          ASource(
            id: map["sources"] != null &&
                    map["sources"] is List &&
                    (map["sources"] as List).isNotEmpty
                ? (map["sources"] as List).first['id']?.toString() ?? ''
                : '',
            name: detectedType == ItemType.anime
                ? name.substring(9)
                : name.substring(10),
            pkgName: map['pkg'],
            apkName: map['apk'],
            lang: map['lang'],
            version: map['version'],
            isNsfw: map['isNsfw'] ?? false,
            itemType: detectedType,
            repo: repoUrl,
            iconUrl: "$baseIconUrl/icon/${map['pkg']}.png",
          ),
        );
      }

      final Map<String, List<ASource>> grouped = {};
      for (final s in sources) {
        final key = (s as ASource).pkgName ?? s.name ?? "unknown";
        grouped.putIfAbsent(key, () => []).add(s);
      }

      final filtered = <ASource>[];
      for (final group in grouped.values) {
        if (group.length > 1) {
          final allSource = group.firstWhere((s) => s.lang == 'all',
              orElse: () => group.firstWhere((s) => s.lang == 'en',
                  orElse: () => group.first));
          for (final s in group) {
            s.langs = group;
          }
          filtered.add(allSource);
        } else {
          filtered.add(group.first);
        }
      }

      return List.unmodifiable(filtered);
    } catch (e) {
      debugPrint("Remote Proxy: Failed to parse extensions from $repoUrl: $e");
      return const [];
    }
  }

  void _detectUpdates(List<ASource> available, ItemType type) {
    final installed = getInstalledRx(type).value.whereType<ASource>().toList();
    final repoMap = {for (var s in available) s.id: s};
    bool changed = false;

    for (var i = 0; i < installed.length; i++) {
      final inst = installed[i];
      final repo = repoMap[inst.id];
      if (repo == null) continue;

      if (compareVersions(repo.version ?? "0", inst.version ?? "0") > 0) {
        installed[i] = inst
          ..hasUpdate = true
          ..apkName = repo.apkName
          ..iconUrl = repo.iconUrl
          ..versionLast = repo.version;
        changed = true;
      }
    }

    if (changed) {
      getInstalledRx(type).value = List.unmodifiable(installed);
      _saveInstalledToStore(installed, type);
    }
  }

  @override
  Future<void> addRepo(String repoUrl, ItemType type) async {
    try {
      final uri = Uri.tryParse(repoUrl);
      if (uri == null || !uri.hasScheme) throw Exception("Invalid repo URL");

      final repos = _loadRepos(type);
      if (repos.any((r) => r.url == repoUrl)) return;

      final res = await _client.get(uri);
      if (res.statusCode != 200) throw Exception("Failed to fetch repo");

      final repo = Repo(url: repoUrl, managerId: id);
      final updatedRepos = List<Repo>.from(repos)..add(repo);
      _saveRepos(updatedRepos, type);

      final parsed = await compute(_parseExtensions, (res.body, repoUrl, type));

      final rx = getAvailableRx(type);
      final existing = rx.value;
      final merged = {
        for (final s in existing) s.id: s,
        for (final s in parsed) s.id: s,
      }.values.toList(growable: false);

      rx.value = List.unmodifiable(merged);
      getReposRx(type).value = updatedRepos;
    } catch (e) {
      Logger.log("Failed to add repo $repoUrl: $e");
      rethrow;
    }
  }

  @override
  Future<void> removeRepo(String repoUrl, ItemType type) async {
    try {
      final repos = _loadRepos(type).where((r) => r.url != repoUrl).toList(growable: false);
      _saveRepos(repos, type);

      final rx = getAvailableRx(type);
      rx.value = rx.value.where((s) => s.repo != repoUrl).toList();

      getReposRx(type).value = repos;
    } catch (e) {
      Logger.log("Failed to remove repo $repoUrl: $e");
    }
  }

  List<Repo> _loadRepos(ItemType type) {
    final key = 'aniyomiRemote${type.name}Repos';
    final encoded = getVal<List<String>>(key);
    if (encoded == null || encoded.isEmpty) return const [];
    return encoded.map((e) => Repo.fromJson(jsonDecode(e))).toSet().toList(growable: false);
  }

  void _saveRepos(List<Repo> repos, ItemType type) {
    final key = 'aniyomiRemote${type.name}Repos';
    setVal(key, repos.toSet().map((e) => jsonEncode(e.toJson())).toList(growable: false));
  }

  @override
  Future<void> installSource(Source source, {String? customPath}) async {
    var aSource = source as ASource;
    if (aSource.apkUrl == null) {
      return Future.error('Source APK URL is required for installation.');
    }

    try {
      final pkgName = aSource.pkgName ?? aSource.apkName?.replaceAll('.apk', '') ?? 'unknown_ext';
      final extDir = await _getExtensionsPath();
      final outApkPath = p.join(extDir, '$pkgName.apk');

      final apkRes = await _client.get(Uri.parse(aSource.apkUrl!));
      if (apkRes.statusCode != 200) {
        throw Exception('Failed to download extension APK: HTTP ${apkRes.statusCode}');
      }
      File(outApkPath).writeAsBytesSync(apkRes.bodyBytes);

      final installedList = _loadInstalledFromStore(aSource.itemType!);
      installedList.removeWhere((e) => e.id == aSource.id);
      
      final versionToSave = aSource.hasUpdate == true ? aSource.versionLast : aSource.version;
      aSource.version = versionToSave;
      aSource.hasUpdate = false;
      
      installedList.add(aSource);
      _saveInstalledToStore(installedList, aSource.itemType!);

      final avail = getAvailableRx(aSource.itemType!);
      avail.value = avail.value.where((e) => e.id != aSource.id).toList();

      if (aSource.itemType == ItemType.anime) {
        await fetchInstalledAnimeExtensions();
      } else {
        await fetchInstalledMangaExtensions();
      }
    } catch (e) {
      Logger.log('Error installing remote source: $e');
      rethrow;
    }
  }

  @override
  Future<void> uninstallSource(Source source) async {
    final s = source as ASource;
    final pkgName = s.pkgName;
    if (pkgName == null || pkgName.isEmpty) {
      throw Exception('Source ID required');
    }

    try {
      final extPath = await _getExtensionsPath();
      final apkPath = p.join(extPath, '$pkgName.apk');

      if (File(apkPath).existsSync()) File(apkPath).deleteSync();

      final installedList = _loadInstalledFromStore(s.itemType!);
      installedList.removeWhere((e) => e.id == s.id);
      _saveInstalledToStore(installedList, s.itemType!);

      final raw = getRawAvailableRx(s.itemType!).value;
      getInstalledRx(s.itemType!).value = installedList;

      final installedIds = installedList.map((e) => e.id).toSet();
      getAvailableRx(s.itemType!).value = List.unmodifiable(
        raw.where((x) => !installedIds.contains(x.id)),
      );
    } catch (e) {
      Logger.log('Error uninstalling remote source: $e');
      rethrow;
    }
  }

  @override
  Future<void> updateSource(Source source) async {
    await installSource(source);
  }
}
