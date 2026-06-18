import 'dart:io' show Platform;
import 'package:speech_to_text/speech_to_text.dart' as stt;

final stt.SpeechToText _speech = stt.SpeechToText();
bool speechInputAvailable = false;
String? speechInputLocale;

bool get isSpeechInputSupportedPlatform {
  return Platform.isAndroid || Platform.isIOS || Platform.isMacOS;
}

Future<bool> initSpeechInput({
  void Function(String status)? onStatus,
  void Function(String error)? onError,
}) async {
  if (!isSpeechInputSupportedPlatform) {
    speechInputAvailable = false;
    return false;
  }

  speechInputAvailable = await _speech.initialize(
    onStatus: onStatus,
    onError: (error) => onError?.call(error.errorMsg),
  );

  if (speechInputAvailable) {
    final locales = await _speech.locales();
    speechInputLocale = _pickChineseLocale(locales);
  }
  return speechInputAvailable;
}

Future<bool> startSpeechInput({
  required void Function(String text, bool isFinal) onResult,
  void Function(String status)? onStatus,
  void Function(String error)? onError,
  String? locale,
}) async {
  if (!speechInputAvailable) return false;

  await _speech.listen(
    onResult: (result) {
      onResult(result.recognizedWords, result.finalResult);
    },
    localeId: locale ?? speechInputLocale,
    listenFor: const Duration(seconds: 30),
    pauseFor: const Duration(seconds: 3),
    partialResults: true,
    cancelOnError: true,
    listenMode: stt.ListenMode.dictation,
  );
  return true;
}

Future<void> stopSpeechInput() => _speech.stop();

Future<void> cancelSpeechInput() => _speech.cancel();

String? _pickChineseLocale(List<stt.LocaleName> locales) {
  for (final locale in locales) {
    if (locale.localeId.toLowerCase().startsWith('zh') ||
        locale.name.contains('中文')) {
      return locale.localeId;
    }
  }
  return locales.isNotEmpty ? locales.first.localeId : null;
}

String get speechInputUnsupportedMessage {
  if (Platform.isWindows) {
    return 'Windows 桌面版暂不支持语音输入，请使用 Edge 运行：flutter run -d edge';
  }
  if (Platform.isLinux) {
    return 'Linux 桌面版暂不支持语音输入，请使用 Chrome/Edge 浏览器运行';
  }
  return '当前平台不支持语音输入，请使用 Chrome/Edge 浏览器';
}
