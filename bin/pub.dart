// Copyright (c) 2013, the Dart project authors.  Please see the AUTHORS file
// for details. All rights reserved. Use of this source code is governed by a
// BSD-style license that can be found in the LICENSE file.

import 'dart:io';

import 'package:pub/src/command_runner.dart';

///
/// use below command to generate a snapshot
/// dart --snapshot=xxx.snapshot ./bin/pub.dart
///
void main(List<String> arguments) {
  // if (arguments == null || arguments.isEmpty) {
  //   arguments = [];
  //   arguments.add("publish");
  //   arguments.add("--server");
  //   arguments.add("http://some.private.host");
  // }
  var finalArgs = <String>['publish'];
  var pubUrl = Platform.environment['PRIVATE_PUB_URL'] ?? '';
  if (pubUrl.isEmpty && arguments.isNotEmpty) {
    var serverArg = arguments.firstWhere(
        (element) => element.contains('--server'),
        orElse: () => '');
    if (serverArg.isEmpty) {
      throw Exception(
          'you should provide a pub server url, you can offer --server=<your server url> or set environment value naming PRIVATE_PUB_URL');
    }
    finalArgs.add(serverArg);
  } else {
    finalArgs.add('--server=$pubUrl');
  }

  PubCommandRunner().run(finalArgs);
}
