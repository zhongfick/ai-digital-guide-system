import 'dart:async';
import 'dart:convert';
import 'dart:js_interop';
// ignore: deprecated_member_use, avoid_web_libraries_in_flutter
import 'dart:html' as html;

bool speechInputAvailable = false;
String? speechInputLocale = 'zh-CN';

void Function(String text, bool isFinal)? _onResult;
void Function(String status)? _onStatus;
void Function(String error)? _onError;
StreamSubscription<html.MessageEvent>? _messageSub;

@JS('SpeechBridge')
extension type SpeechBridgeType(JSObject _) implements JSObject {
  external bool isSupported();
  external JSPromise<JSBoolean> requestMicPermission();
  external bool start(JSString locale);
  external void stop();
  external void abort();
}

@JS('SpeechBridge')
external SpeechBridgeType get speechBridge;

bool get isSpeechInputSupportedPlatform {
  try {
    return speechBridge.isSupported();
  } catch (_) {
    return false;
  }
}

Future<bool> initSpeechInput({
  void Function(String status)? onStatus,
  void Function(String error)? onError,
}) async {
  _messageSub ??= html.window.onMessage.listen(_handleMessage);
  try {
    speechInputAvailable = speechBridge.isSupported();
  } catch (_) {
    speechInputAvailable = false;
  }
  if (!speechInputAvailable) {
    onError?.call('not_supported');
  }
  return speechInputAvailable;
}

void _handleMessage(html.MessageEvent event) {
  try {
    final raw = event.data;
    final Map<String, dynamic> msg = raw is String
        ? jsonDecode(raw) as Map<String, dynamic>
        : Map<String, dynamic>.from(raw as Map);
    if (msg['type'] != 'speechBridge') return;

    final eventType = msg['event'];
    final data = (msg['data'] as Map?)?.cast<String, dynamic>() ?? {};

    if (eventType == 'result') {
      _onResult?.call(data['text']?.toString() ?? '', data['isFinal'] == true);
    } else if (eventType == 'status') {
      _onStatus?.call(data['status']?.toString() ?? '');
    } else if (eventType == 'error') {
      _onError?.call(_mapSpeechError(data['error']?.toString() ?? 'unknown'));
    }
  } catch (_) {}
}

String _mapSpeechError(String code) {
  switch (code) {
    case 'not-allowed':
    case 'service-not-allowed':
      return '麦克风权限被拒绝，请点击地址栏左侧图标允许麦克风';
    case 'no-speech':
      return '未检测到语音，请靠近麦克风再试一次';
    case 'network':
      return '语音识别需要网络连接';
    case 'not_supported':
      return '当前浏览器不支持语音识别';
    case 'aborted':
      return '语音识别已取消';
    default:
      return code;
  }
}

Future<bool> startSpeechInput({
  required void Function(String text, bool isFinal) onResult,
  void Function(String status)? onStatus,
  void Function(String error)? onError,
  String? locale,
}) async {
  if (!speechInputAvailable) return false;

  _onResult = onResult;
  _onStatus = onStatus;
  _onError = onError;

  try {
    final micOk = (await speechBridge.requestMicPermission().toDart).toDart;
    if (!micOk) {
      onError?.call('麦克风权限被拒绝，请在浏览器中允许麦克风访问');
      return false;
    }

    return speechBridge.start((locale ?? speechInputLocale ?? 'zh-CN').toJS);
  } catch (e) {
    onError?.call('启动语音识别失败: $e');
    return false;
  }
}

Future<void> stopSpeechInput() async {
  try {
    speechBridge.stop();
  } catch (_) {}
}

Future<void> cancelSpeechInput() async {
  try {
    speechBridge.abort();
  } catch (_) {}
}

String get speechInputUnsupportedMessage =>
    '语音识别不可用，请使用 Chrome/Edge 浏览器并允许麦克风权限';
