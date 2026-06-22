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
  final iframes = html.document.querySelectorAll('iframe');
  html.window.console.log('[flutter-bridge] sendAvatarCommandToIframe action=$action iframeCount=${iframes.length}');

  void dispatchToFrame(html.IFrameElement frame) {
    html.window.console.log('[flutter-bridge] dispatch to iframe src=${frame.src} id=${frame.id}');
    
    // 直接通过 postMessage 发送，不使用 localStorage
    try {
      frame.contentWindow?.postMessage(payload, '*');
      html.window.console.log('[flutter-bridge] postMessage success action=$action targetOrigin=*');
    } catch (e) {
      html.window.console.log('[flutter-bridge] postMessage failed action=$action error=$e');
    }
  }

  var sent = false;
  final iframeById = html.document.querySelector('#avatar-frame');
  if (iframeById is html.IFrameElement) {
    dispatchToFrame(iframeById);
    sent = true;
  }

  for (final node in iframes) {
    if (node is html.IFrameElement) {
      dispatchToFrame(node);
      sent = true;
    }
  }

  return sent;
}