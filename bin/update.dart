// ignore_for_file: avoid_print

import 'dart:async';
import 'dart:convert';
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

  final logs = <String>[];

  try {
    final parser = ArgParser();
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

    final parsed = parser.parse(args ?? []);

    final paths = parsed['paths'].split(',');
    var hasUpdates = false;

    final timeout = Duration(
      minutes: JsonClass.maybeParseInt(parsed['timeout']) ?? 10,
    );
    final dryRun = parsed['dry-run'] == true;

    for (var path in paths) {
      hasUpdates = await _updateDependencies(
            dryRun: dryRun,
            logs: logs,
            path: path,
            timeout: timeout,
          ) ||
          hasUpdates;
    }
    if (hasUpdates) {
      if (parsed['dry-run'] != true) {
        await _processGit(
          branch: parsed['branch'],
          dryRun: dryRun,
          logs: logs,
          merge: parsed['merge'] == 'true',
          message: parsed['message'],
          pullRequest: parsed['pull-request'] == 'true',
          repository: parsed['repository'],
          timeout: timeout,
          token: parsed['token'],
        );
        logs.add('Process is complete');
      } else {
        logs.add('Dry run requested, process is complete');
      }
    } else {
      logs.add('No updates found, process is complete');
    }
    print(logs.join('\n'));
    exit(0);
  } catch (e, stack) {
    logs.add('$e');
    logs.add('$stack');

    print(logs.join('\n'));
    exit(1);
  }
}

Future<void> _processGit({
  required String branch,
  required bool dryRun,
  required List<String> logs,
  required bool merge,
  required String? message,
  required bool pullRequest,
  required String? repository,
  required Duration timeout,
  required String? token,
}) async {
  if (pullRequest) {
    RepositorySlug? slug;

    if (repository != null) {
      final repo = repository;

      slug = RepositorySlug.full(repo);
      print('Discovered CLI SLUG: $repo');
    } else if (Platform.environment['GITHUB_ACTION_REPOSITORY']?.isNotEmpty ==
        true) {
      final repo = Platform.environment['GITHUB_ACTION_REPOSITORY']!;

      slug = RepositorySlug.full(repo);
      print('Discovered ENV SLUG: $repo');
    } else {
      final ghResult = Process.runSync(
        'git',
        ['remote', 'show', 'origin'],
      );
      final ghOutput = ghResult.stdout;

      final regex = RegExp(
        r'Push[^:]*:[^:]*:(?<org>[^\/]*)\/(?<repo>[^\n\.\/]*)',
      );
      final matches = regex.allMatches(ghOutput.toString());

      for (var match in matches) {
        final org = match.namedGroup('org');
        final repo = match.namedGroup('repo');

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

    final branchName = 'dart_update_${DateTime.now().millisecondsSinceEpoch}';

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
        message ?? 'actions-dart-dependency-updater: updating dependencies',
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

    if (token == null) {
      throw Exception('FormatException: Option token is mandatory.');
    }

    final gh = GitHub(
      auth: Authentication.withToken(token),
    );

    print('''
Creating PR:
  * From Branch: $branchName
  * To Branch:   $branch
''');
    final pr = await gh.pullRequests.create(
      slug,
      CreatePullRequest(
        'BOT: Dart Dependency Updater',
        branchName,
        branch,
        body: '''
PR created automatically

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
    } else if (merge) {
      print('Preparing to merge PR...');
      var merged = false;

      final endBy =
          DateTime.now().millisecondsSinceEpoch + timeout.inMilliseconds;
      while (!merged) {
        await Future.delayed(const Duration(seconds: 30));

        print('Scanning for running status checks...');
        final checks = await gh.checks.checkRuns
            .listCheckRunsForRef(
              slug,
              ref: pr.head!.sha!,
            )
            .toList();

        var done = true;
        for (var check in checks) {
          if (check.status?.value == 'in_progress' ||
              check.status?.value == 'queued') {
            done = false;
          }
        }

        if (done) {
          print('Status checks complete...');
          for (var check in checks) {
            if (check.conclusion.value != 'success') {
              throw Exception('''
Status check(s) did not pass: ${check.conclusion}

Details: 
${const JsonEncoder.withIndent('  ').convert(check.toJson())}
''');
            }
          }

          final mergeResult = await gh.pullRequests.merge(
            slug,
            pr.number!,
            message: 'Automated Merge',
          );

          if (mergeResult.merged != true) {
            throw Exception('Error merging PR');
          }

          print('PR merged');
          merged = true;

          Process.runSync('git', [
            'push',
            'origin',
            '--delete',
            branchName,
          ]);
        } else if (DateTime.now().millisecondsSinceEpoch > endBy) {
          throw Exception('Status Check Timeout!!!');
        } else {
          print('Status check running, waiting...');
        }
      }
    }
  }
}

Future<bool> _updateDependencies({
  required bool dryRun,
  required List<String> logs,
  required String path,
  required Duration timeout,
}) async {
  var hasUpdates = false;
  final scanner = VersionScanner();
  final pubspec = File('$path/pubspec.yaml');
  print('Updating pubspec: [${pubspec.path}]');

  final yaml = loadYamlDocument(pubspec.readAsStringSync());

  final results = await scanner.scan(yaml);

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

  if (hasUpdates) {
    final contents = Map<String, dynamic>.from(yaml.contents.value);
    final version = Version.parse(contents['version']);

    if (version.build.length > 1) {
      throw Exception(
        'Unable to process pubspec version: ${contents['version']}',
      );
    }

    var buildNumber = 0;
    if (version.build.isNotEmpty) {
      buildNumber = JsonClass.maybeParseInt(version.build.first) ?? 0;
    }
    buildNumber++;

    final versionString =
        '${version.major}.${version.minor}.${version.patch}+$buildNumber';
    contents['version'] = versionString;

    final changelog = File('$path/CHANGELOG.md');
    if (changelog.existsSync()) {
      var cl = changelog.readAsStringSync();
      final df = DateFormat('MMMM d, yyyy');

      cl = '''
## [$versionString] - ${df.format(DateTime.now())}

* Automated dependency updates


$cl
'''
          .trim();

      changelog.writeAsStringSync(cl);
    }

    var flutter = false;

    if (results.dependencies.isNotEmpty) {
      final deps = Map<String, dynamic>.from(contents['dependencies']);
      flutter = flutter || deps.containsKey('flutter');
      for (var dep in results.dependencies) {
        deps[dep.package] = '^${dep.newVersion}';
      }
      contents['dependencies'] = deps;
    }

    if (results.devDependencies.isNotEmpty) {
      final deps = Map<String, dynamic>.from(contents['dev_dependencies']);
      flutter = flutter || deps.containsKey('flutter');
      flutter = flutter || deps.containsKey('flutter_test');
      for (var dep in results.devDependencies) {
        deps[dep.package] = '^${dep.newVersion}';
      }
      contents['dev_dependencies'] = deps;
    }
    logs.add('');

    final lines = YamlWriter().write(contents).split('\n');

    final output = <String>[];
    for (var i = 0; i < lines.length; i++) {
      final line = lines[i];
      if (line.trim().isNotEmpty) {
        if (!line.startsWith(' ')) {
          final nextLine = i + 1 < lines.length ? lines[i + 1] : '';

          if (nextLine.startsWith(' ')) {
            output.add('');
          }
        }
      }

      output.add(line);
    }

    pubspec.writeAsStringSync(output.join('\n'));

    Future<ProcessResult> process;
    final lock = File('$path/pubspec.lock');
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
    final cFuture = completer.future;
    late ProcessResult processResult;
    final timer = Timer(
      timeout,
      () {
        print('TIMEOUT!');
        completer?.completeError('TIMEOUT!');
        completer = null;
      },
    );
    final future = Future.microtask(() async {
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
  logs.add('');

  return hasUpdates;
}
