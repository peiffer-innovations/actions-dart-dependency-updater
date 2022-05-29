import 'dart:async';
import 'dart:io';

import 'package:args/args.dart';
import 'package:dart_dependency_updater/dart_dependency_updater.dart';
import 'package:github/github.dart';
import 'package:intl/intl.dart';
import 'package:json_class/json_class.dart';
import 'package:logging/logging.dart';
import 'package:pub_semver/pub_semver.dart';
import 'package:yaml/yaml.dart';
import 'package:yaml_writer/yaml_writer.dart';

Future<void> main(List<String>? args) async {
  Logger.root.level = Level.ALL;
  Logger.root.onRecord.listen((record) {
    print('${record.level.name}: ${record.time}: ${record.message}');
    if (record.error != null) {
      print('${record.error}');
    }
    if (record.stackTrace != null) {
      print('${record.stackTrace}');
    }
  });

  var logs = <String>[];

  var exitCode = 0;

  try {
    var parser = ArgParser();
    parser.addFlag(
      'dry-run',
    );
    parser.addOption(
      'branch',
      defaultsTo: 'main',
    );
    parser.addOption(
      'merge',
      defaultsTo: 'false',
    );
    parser.addOption(
      'message',
      defaultsTo: 'Automated dependency update',
    );
    parser.addOption(
      'paths',
      defaultsTo: '.',
    );
    parser.addOption(
      'pull-request',
      defaultsTo: 'true',
    );
    parser.addOption(
      'repository',
    );
    parser.addOption(
      'timeout',
      defaultsTo: '10',
    );
    parser.addOption(
      'token',
    );

    var parsed = parser.parse(args ?? []);

    var paths = parsed['paths'].split(',');

    for (var path in paths) {
      logs.clear();
      var scanner = VersionScanner();
      var pubspec = File('$path/pubspec.yaml');

      var yaml = loadYamlDocument(pubspec.readAsStringSync());

      var timeout = Duration(
        minutes: JsonClass.parseInt(parsed['timeout']) ?? 10,
      );

      var results = await scanner.scan(yaml);

      var hasUpdates = false;
      if (results.dependencies.isNotEmpty) {
        logs.add('');
        logs.add('dependencies:');
        hasUpdates = true;
        for (var dep in results.dependencies) {
          logs.add(
            '  * `${dep.package}`: ${dep.oldVersion} --> ${dep.newVersion}',
          );
        }
      }

      if (results.devDependencies.isNotEmpty) {
        logs.add('');
        logs.add('dev_dependencies:');
        hasUpdates = true;
        for (var dep in results.devDependencies) {
          logs.add(
            '  * `${dep.package}`: ${dep.oldVersion} --> ${dep.newVersion}',
          );
        }
      }

      if (hasUpdates && parsed['dry-run'] != true) {
        var contents = Map<String, dynamic>.from(yaml.contents.value);
        var version = Version.parse(contents['version']);

        if (version.build.length > 1) {
          throw Exception(
            'Unable to process pubspec version: ${contents['version']}',
          );
        }

        var buildNumber = 0;
        if (version.build.isNotEmpty) {
          buildNumber = JsonClass.parseInt(version.build.first) ?? 0;
        }
        buildNumber++;

        var versionString =
            '${version.major}.${version.minor}.${version.patch}+$buildNumber';
        contents['version'] = versionString;

        var changelog = File('$path/CHANGELOG.md');
        if (changelog.existsSync()) {
          var cl = changelog.readAsStringSync();
          var df = DateFormat('MMMM, d, yyyy');

          cl = '''
## [$versionString] - ${df.format(DateTime.now())}

* Automated dependency updates


$cl
''';

          changelog.writeAsStringSync(cl);
        }

        var flutter = false;

        if (results.dependencies.isNotEmpty) {
          var deps = Map<String, dynamic>.from(contents['dependencies']);
          flutter = flutter || deps.containsKey('flutter');
          for (var dep in results.dependencies) {
            deps[dep.package] = '^${dep.newVersion}';
          }
          contents['dependencies'] = deps;
        }

        if (results.devDependencies.isNotEmpty) {
          var deps = Map<String, dynamic>.from(contents['dev_dependencies']);
          flutter = flutter || deps.containsKey('flutter');
          flutter = flutter || deps.containsKey('flutter_test');
          for (var dep in results.devDependencies) {
            deps[dep.package] = '^${dep.newVersion}';
          }
          contents['dev_dependencies'] = deps;
        }
        logs.add('');

        var lines = YAMLWriter().write(contents).split('\n');

        var output = <String>[];
        for (var i = 0; i < lines.length; i++) {
          var line = lines[i];
          if (line.trim().isNotEmpty) {
            if (!line.startsWith(' ')) {
              var nextLine = i + 1 < lines.length ? lines[i + 1] : '';

              if (nextLine.startsWith(' ')) {
                output.add('');
              }
            }
          }

          output.add(line);
        }

        pubspec.writeAsStringSync(output.join('\n'));

        Future<ProcessResult> process;
        var lock = File('$path/pubspec.lock');
        if (lock.existsSync()) {
          lock.deleteSync();
        }

        if (flutter) {
          print('Updating Flutter packages...');
          process = Process.run(
            'flutter',
            ['packages', 'get'],
            workingDirectory: path,
          );
        } else {
          print('Updating Dart packages...');
          process = Process.run(
            'dart',
            ['pub', 'get'],
            workingDirectory: path,
          );
        }

        Completer? completer = Completer();
        var cFuture = completer.future;
        late ProcessResult processResult;
        var timer = Timer(
          timeout,
          () {
            print('TIMEOUT!');
            completer?.completeError('TIMEOUT!');
            completer = null;
          },
        );
        var future = Future.microtask(() async {
          try {
            processResult = await process;
            print('Done updating dependencies');
            completer?.complete();
          } catch (e, stack) {
            completer?.completeError(e, stack);
          } finally {
            timer.cancel();
            completer = null;
          }
        });

        await Future.wait([
          future,
          cFuture,
        ]);

        if (processResult.exitCode == 0) {
          if (flutter) {
            processResult = Process.runSync(
              'flutter',
              ['analyze'],
              workingDirectory: path,
            );
          } else {
            processResult = Process.runSync(
              'dart',
              ['analyze'],
              workingDirectory: path,
            );
          }
        }

        if (processResult.exitCode == 0) {
          if (flutter) {
            processResult = Process.runSync(
              'flutter',
              ['test'],
              workingDirectory: path,
            );
          } else {
            processResult = Process.runSync(
              'dart',
              ['test'],
              workingDirectory: path,
            );
          }
        }

        if (processResult.exitCode == 0) {
          logs.add('');
          logs.add('Analysis Successful');
        } else {
          logs.add('');
          logs.add('Error!!!');
          logs.add('```');
          logs.add(processResult.stdout);

          logs.add('');
          logs.add(processResult.stderr);
          logs.add('```');
          exitCode = processResult.exitCode;
        }
      }

      if (parsed['pull-request'] == 'true') {
        RepositorySlug? slug;

        if (parsed['repository'] != null) {
          var repo = parsed['repository']!;

          slug = RepositorySlug.full(repo);
          print('Discovered CLI SLUG: $repo');
        } else if (Platform
                .environment['GITHUB_ACTION_REPOSITORY']?.isNotEmpty ==
            true) {
          var repo = Platform.environment['GITHUB_ACTION_REPOSITORY']!;

          slug = RepositorySlug.full(repo);
          print('Discovered ENV SLUG: $repo');
        } else {
          var ghResult = Process.runSync(
            'git',
            ['remote', 'show', 'origin'],
          );
          var ghOutput = ghResult.stdout;

          var regex = RegExp(
            r'Push[^:]*:[^:]*:(?<org>[^\/]*)\/(?<repo>[^\n\.\/]*)',
          );
          var matches = regex.allMatches(ghOutput.toString());

          for (var match in matches) {
            var org = match.namedGroup('org');
            var repo = match.namedGroup('repo');

            if (org != null && repo != null) {
              slug = RepositorySlug(org, repo);

              print('Discovered SLUG: $org/$repo');
              break;
            }
          }
        }

        if (slug == null) {
          throw Exception('Unable to determine GitHub SLUG');
        }

        var branchName = 'dart_update_${DateTime.now().millisecondsSinceEpoch}';

        var ghResult = Process.runSync(
          'git',
          [
            'checkout',
            '-b',
            branchName,
          ],
        );
        if (ghResult.exitCode != 0) {
          throw Exception('Unable to create branch.');
        }
        print('Created branch: $branchName');

        ghResult = Process.runSync(
          'git',
          [
            'add',
            '.',
          ],
        );
        if (ghResult.exitCode != 0) {
          throw Exception('Unable to add to GitHub.');
        }

        ghResult = Process.runSync(
          'git',
          [
            'commit',
            '-m',
            parsed['message'] ??
                'action-dart-dependency-updater: updating dependencies',
          ],
        );
        if (ghResult.exitCode != 0) {
          throw Exception('Unable to commit to GitHub.');
        }

        ghResult = Process.runSync(
          'git',
          [
            'push',
            '--set-upstream',
            'origin',
            branchName,
          ],
        );
        if (ghResult.exitCode != 0) {
          throw Exception('Unable to push to GitHub.');
        }

        print('Pushed to: $branchName');

        var token = parsed['token'];
        if (token == null) {
          throw Exception('FormatException: Option token is mandatory.');
        }

        var gh = GitHub(
          auth: Authentication.withToken(token),
        );

        print('''
Creating PR:
  * From Branch: $branchName
  * To Branch:   ${parsed['branch']}
''');
        var pr = await gh.pullRequests.create(
          slug,
          CreatePullRequest(
            'BOT: Dart Dependency Updater',
            branchName,
            parsed['branch'],
            body: '''
PR created automatically via: https://github.com/peiffer-innovations/action-dart-dependency-updater

${logs.join('\n')}
''',
          ),
        );

        if (pr.number == null) {
          throw Exception(pr.toJson());
        }

        print('Created PR: ${pr.htmlUrl}');

        if (exitCode != 0) {
          logs.add('');
          logs.add('Analysis failed!');
        } else if (parsed['merge'] == 'true') {
          print('Preparing to merge PR...');
          var merged = false;

          var endBy =
              DateTime.now().millisecondsSinceEpoch + timeout.inMilliseconds;
          while (!merged) {
            await Future.delayed(const Duration(seconds: 30));

            print('Scanning for running status checks...');
            var checks = await gh.checks.checkRuns
                .listCheckRunsForRef(
                  slug,
                  ref: pr.head!.sha!,
                )
                .toList();

            var done = true;
            for (var check in checks) {
              if (check.status?.value == 'in_progress') {
                done = false;
              }
            }

            if (done) {
              print('Status checks complete...');
              for (var check in checks) {
                if (check.conclusion.value != 'success') {
                  throw Exception('Status check(s) did not pass');
                }
              }

              var mergeResult = await gh.pullRequests.merge(
                slug,
                pr.number!,
                message: 'Automated Merge',
              );

              if (mergeResult.merged != true) {
                throw Exception('Error merging PR');
              }

              print('PR merged');
              merged = true;

              await Process.runSync('git', [
                'push',
                'origin',
                '--delete',
                branchName,
              ]);
            } else if (DateTime.now().millisecondsSinceEpoch > endBy) {
              throw Exception('PR Timeout!!!');
            } else {
              print('PR not mergable, waiting...');
            }
          }
        }
      }

      print(logs.join('\n'));
      exit(exitCode);
    }
  } catch (e, stack) {
    logs.add('$e');
    logs.add('$stack');

    print(logs.join('\n'));
    exit(1);
  }
}
