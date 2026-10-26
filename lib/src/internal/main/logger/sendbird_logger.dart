// Copyright (c) 2023 Sendbird, Inc. All rights reserved.

import 'package:logger/logger.dart';
import 'package:sendbird_chat_sdk/src/internal/main/logger/logger_stack_trace.dart';
import 'package:sendbird_chat_sdk/src/public/main/define/enums.dart';

final sbLog = SendbirdLogger();

class SendbirdLogger {
  Logger logger;

  static final _instance = SendbirdLogger._();

  SendbirdLogger._() : logger = Logger(level: Level.nothing) {
    _setLogLevel(Level.nothing);
  }

  factory SendbirdLogger() => _instance;

  void setLogLevel(LogLevel level) {
    _setLogLevel(_convertLogLevel(level));
  }

  void setLogLevelForTest() {
    _setLogLevel(Level.nothing);
  }

  void e(StackTrace stackTrace, [Object? message]) {
    logger.e(() => _getLogMessage(stackTrace, message));
  }

  void w(StackTrace stackTrace, [Object? message]) {
    logger.w(() => _getLogMessage(stackTrace, message));
  }

  void i(StackTrace stackTrace, [Object? message]) {
    logger.i(() => _getLogMessage(stackTrace, message));
  }

  void d(StackTrace stackTrace, [Object? message]) {
    logger.d(() => _getLogMessage(stackTrace, message));
  }

  void v(StackTrace stackTrace, [Object? message]) {
    logger.v(() => _getLogMessage(stackTrace, message));
  }

  void _setLogLevel(Level level) {
    logger = Logger(
        level: level,
        printer: PrefixPrinter(
          PrettyPrinter(
            methodCount: 0,
            // number of method calls to be displayed
            errorMethodCount: 8,
            // number of method calls if stacktrace is provided
            lineLength: 100,
            // width of the output
            colors: true,
            // Colorful log messages
            printEmojis: false,
            // Print an emoji for each log message
            printTime: true, // Should each log print contain a timestamp
          ),
          error: '[E]',
          warning: '[W]',
          info: '[I]',
          debug: '[D]',
          verbose: '[V]',
        ));
  }

  String _getLogMessage(StackTrace stackTrace, Object? message) {
    const emptyMessage = '';
    final value = message is String Function() ? message() : message;
    return '${_getLogPrefix(stackTrace)} ${value ?? emptyMessage}';
  }

  String _getLogPrefix(StackTrace stackTrace) {
    final trace = LoggerStackTrace.from(stackTrace);
    // return '[${trace.fileName}][${trace.functionName}]';
    return '[${trace.functionName}]';
  }

  Level _convertLogLevel(LogLevel level) {
    switch (level) {
      case LogLevel.error:
        return Level.error;
      case LogLevel.warning:
        return Level.warning;
      case LogLevel.info:
        return Level.info;
      case LogLevel.none:
        return Level.nothing;
    }
  }
}
