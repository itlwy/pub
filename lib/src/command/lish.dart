// Copyright (c) 2012, the Dart project authors.  Please see the AUTHORS file
// for details. All rights reserved. Use of this source code is governed by a
// BSD-style license that can be found in the LICENSE file.

import 'dart:async';
import 'dart:io';

import 'package:http/http.dart' as http;

import '../ascii_tree.dart' as tree;
import '../command.dart';
import '../exit_codes.dart' as exit_codes;
import '../http.dart';
import '../io.dart';
import '../log.dart' as log;
import 'package:path/path.dart' as path;
import '../utils.dart';
import '../validator.dart';

/// Handles the `lish` and `publish` pub commands.
class LishCommand extends PubCommand {
  String get name => "publish";

  String get description => "Publish the current package to pub.dartlang.org.";

  String get invocation => "pub publish [options]";

  String get docUrl => "https://dart.dev/tools/pub/cmd/pub-lish";

  List<String> get aliases => const ["lish", "lush"];

  bool get takesArguments => false;

  /// The URL of the server to which to upload the package.
  Uri get server {
    // An explicit argument takes precedence.
    if (argResults.wasParsed('server')) {
      return Uri.parse(argResults['server']);
    }

    // Otherwise, use the one specified in the pubspec.
    if (entrypoint.root.pubspec.publishTo != null) {
      return Uri.parse(entrypoint.root.pubspec.publishTo);
    }

    // Otherwise, use the default.
    return Uri.parse(cache.sources.hosted.defaultUrl);
  }

  /// Whether the publish is just a preview.
  bool get dryRun => argResults['dry-run'];

  /// Whether the publish requires confirmation.
  bool get force => argResults['force'];

  LishCommand() {
    argParser.addFlag('dry-run',
        abbr: 'n',
        negatable: false,
        help: 'Validate but do not publish the package.');
    argParser.addFlag('force',
        abbr: 'f',
        negatable: false,
        help: 'Publish without confirmation if there are no errors.');
    argParser.addOption('server',
        help: 'The package server to which to upload this package.');
  }

  Future _publish(List<int> packageBytes, String dir) async {
    Uri cloudStorageUrl;
    var tarFilePath = path.join(dir, "package.tar.gz");
    try {
//      await oauth2.withClient(cache, (client) {
      var httpClient = http.Client();
      return log.progress('Uploading', () async {
        // TODO(nweiz): Cloud Storage can provide an XML-formatted error. We
        // should report that error and exit.
        var newUri = server.resolve("/api/packages/versions/new");
//          var uri=Uri(scheme: "http", host: "$newUri", queryParameters: pubApiHeaders);
        var response = await httpClient.get(newUri, headers: pubApiHeaders);
//          var response = await httpClient.get(uri);
        var parameters = parseJsonResponse(response);

        var url = _expectField(parameters, 'url', response);
        if (url is! String) invalidServerResponse(response);
        cloudStorageUrl = Uri.parse(url);
        var request = http.MultipartRequest('POST', cloudStorageUrl);

        var fields = _expectField(parameters, 'fields', response);
        if (fields is! Map) invalidServerResponse(response);
        fields.forEach((key, value) {
          if (value is! String) invalidServerResponse(response);
          request.fields[key] = value;
        });

        request.followRedirects = false;

        request.files.add(await http.MultipartFile.fromPath('file', tarFilePath,
            filename: 'package.tar.gz'));
        // request.files.add(await http.MultipartFile.fromBytes(
        //     'file', packageBytes,
        //     filename: 'package.tar.gz'));
        var postResponse =
            await http.Response.fromStream(await httpClient.send(request));

        var location = postResponse.headers['location'];
        if (location == null) throw PubHttpException(postResponse);
        handleJsonSuccess(
            await httpClient.get(location, headers: pubApiHeaders));
        await cleanTarFile(tarFilePath);
      });
//      });
    } on PubHttpException catch (error) {
      await cleanTarFile(tarFilePath);
      var url = error.response.request.url;
      if (url == cloudStorageUrl) {
        // TODO(nweiz): the response may have XML-formatted information about
        // the error. Try to parse that out once we have an easily-accessible
        // XML parser.
        fail(log.red('Failed to upload the package.'));
      } else if (Uri.parse(url.origin) == Uri.parse(server.origin)) {
        handleJsonError(error.response);
      } else {
        rethrow;
      }
    }
  }

  Future<void> cleanTarFile(String tarFilePath) async {
    var tarFile = File(tarFilePath);
    if (await tarFile.exists()) {
      await tarFile.delete();
    }
  }

  Future run() async {
    if (force && dryRun) {
      usageException('Cannot use both --force and --dry-run.');
    }

    if (entrypoint.root.pubspec.isPrivate) {
      dataError('A private package cannot be published.\n'
          'You can enable this by changing the "publish_to" field in your '
          'pubspec.');
    }

    var files = entrypoint.root.listFiles(useGitIgnore: true);
    log.fine('Archiving and publishing ${entrypoint.root}.');

    // Show the package contents so the user can verify they look OK.
    var package = entrypoint.root;
    log.message('Publishing ${package.name} ${package.version} to $server:\n'
        '${tree.fromFiles(files, baseDir: entrypoint.root.dir)}');

    var packageBytesFuture =
        createTarGz(files, baseDir: entrypoint.root.dir).toBytes();

    // Validate the package.
    var isValid =
        await _validate(packageBytesFuture.then((bytes) => bytes.length));
    if (!isValid) {
      await flushThenExit(exit_codes.DATA);
    } else if (dryRun) {
      await flushThenExit(exit_codes.SUCCESS);
    } else {
      await _publish(await packageBytesFuture, entrypoint.root.dir);
    }
  }

  /// Returns the value associated with [key] in [map]. Throws a user-friendly
  /// error if [map] doens't contain [key].
  _expectField(Map map, String key, http.Response response) {
    if (map.containsKey(key)) return map[key];
    invalidServerResponse(response);
  }

  /// Validates the package. Completes to false if the upload should not
  /// proceed.
  Future<bool> _validate(Future<int> packageSize) async {
    var pair = await Validator.runAll(entrypoint, packageSize);
    var errors = pair.first;
    var warnings = pair.last;

    if (errors.isNotEmpty) {
      log.error("Sorry, your package is missing "
          "${(errors.length > 1) ? 'some requirements' : 'a requirement'} "
          "and can't be published yet.\nFor more information, see: "
          "https://dart.dev/tools/pub/cmd/pub-lish.\n");
      return false;
    }

    if (force) return true;

    if (dryRun) {
      var s = warnings.length == 1 ? '' : 's';
      log.warning("\nPackage has ${warnings.length} warning$s.");
      return warnings.isEmpty;
    }

    var message = '\nLooks great! Are you ready to upload your package';

    if (warnings.isNotEmpty) {
      var s = warnings.length == 1 ? '' : 's';
      message = "\nPackage has ${warnings.length} warning$s. Upload anyway";
    }

    var confirmed = await confirm(message);
    if (!confirmed) {
      log.error("Package upload canceled.");
      return false;
    }
    return true;
  }
}
