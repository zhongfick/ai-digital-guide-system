import 'dart:convert';
// ignore: deprecated_member_use, avoid_web_libraries_in_flutter
import 'dart:html' as html;

void setupAvatarMessageListener(void Function() onReady) {
  html.window.onMessage.listen((event) {
    try {
      final raw = event.data;
      final Map<String, dynamic> data = raw is String
          ? jsonDecode(raw) as Map<String, dynamic>
          : Map<String, dynamic>.from(raw as Map);
      if (data['type'] == 'avatarReady') {
        onReady();
      }
    } catch (_) {}
  });
}

bool sendAvatarCommandToIframe(String action) {
  final payload = jsonEncode({'type': 'avatarCommand', 'action': action});

  final iframeById = html.document.querySelector('#avatar-frame');
  if (iframeById is html.IFrameElement) {
    iframeById.contentWindow?.postMessage(payload, '*');
    return true;
  }

  final anyIframe = html.document.querySelector('iframe');
  if (anyIframe is html.IFrameElement) {
    anyIframe.contentWindow?.postMessage(payload, '*');
    return true;
  }

  return false;
}
