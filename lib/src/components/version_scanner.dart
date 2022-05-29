import 'package:dart_dependency_updater/dart_dependency_updater.dart';
import 'package:logging/logging.dart';
import 'package:pub_api_client/pub_api_client.dart';
import 'package:pub_semver/pub_semver.dart';
import 'package:yaml/yaml.dart';

class VersionScanner {
  final Logger _logger = Logger('VersionScanner');

  Future<UpdateResult> scan(YamlDocument pubspec) async {
    var yaml = pubspec.contents.value;

    var result = UpdateResult();
    var deps = yaml['dependencies'];

    var ignoreUpdates = List<String>.from(yaml['ignore_updates'] ?? []);
    if (deps is Map) {
      var updated = await _updateDependencies(
        Map<String, dynamic>.from(deps),
        ignoreUpdates,
      );
      result.dependencies.addAll(updated);
    }

    deps = yaml['dev_dependencies'];
    if (deps is Map) {
      var updated = await _updateDependencies(
        Map<String, dynamic>.from(deps),
        ignoreUpdates,
      );
      result.devDependencies.addAll(updated);
    }

    return result;
  }

  Future<List<Dependency>> _updateDependencies(
    Map<String, dynamic> deps,
    List<String> ignore,
  ) async {
    var updated = <Dependency>[];

    var client = PubClient();
    for (var entry in deps.entries) {
      var ver = entry.value;
      if (ignore.contains(entry.key)) {
        _logger.info('[ignoring]: ${entry.key}');
      } else if (ver is String && ver.startsWith('^')) {
        var versionConstraint = Version.parse(ver.substring(1));

        var package = await client.packageInfo(entry.key);

        if (versionConstraint.isPreRelease) {
          _logger.info('[pre-release]: ${entry.key}');
        } else if (versionConstraint.toString() != package.version &&
            versionConstraint.canonicalizedVersion != package.version) {
          updated.add(
            Dependency(
              newVersion: package.version,
              oldVersion: versionConstraint.toString(),
              package: entry.key,
            ),
          );

          _logger.info('[updating]: ${entry.key}');
        } else {
          _logger.info('[current]: ${entry.key}');
        }
      } else {
        _logger.info('[unsupported_version]: ${entry.key}');
      }
    }

    return updated;
  }
}
