class AnymeXBridgeSettings {
  final bool useInternalExtensionLoading;
  final String? customAnimeApkPath;
  final String? customMangaApkPath;

  AnymeXBridgeSettings({
    this.useInternalExtensionLoading = false,
    this.customAnimeApkPath,
    this.customMangaApkPath,
  });

  Map<String, dynamic> toJson() => {
        'useInternalExtensionLoading': useInternalExtensionLoading,
        'customAnimeApkPath': customAnimeApkPath,
        'customMangaApkPath': customMangaApkPath,
      };

  factory AnymeXBridgeSettings.fromJson(Map<String, dynamic> json) {
    return AnymeXBridgeSettings(
      useInternalExtensionLoading: json['useInternalExtensionLoading'] ?? false,
      customAnimeApkPath: json['customAnimeApkPath'],
      customMangaApkPath: json['customMangaApkPath'],
    );
  }
}
