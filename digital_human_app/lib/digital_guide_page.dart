import 'dart:math';
import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import 'dart:convert';
import 'package:speech_to_text/speech_to_text.dart' as stt;
import 'package:flutter_tts/flutter_tts.dart';

class DigitalGuidePage extends StatefulWidget {
  const DigitalGuidePage({super.key});

  @override
  State<DigitalGuidePage> createState() => _DigitalGuidePageState();
}

class _DigitalGuidePageState extends State<DigitalGuidePage>
    with SingleTickerProviderStateMixin {
  // 动画控制
  late AnimationController _animController;
  double _mouthOpen = 0.0;
  bool _isSpeaking = false;

  // 对话相关
  final TextEditingController _textController = TextEditingController();
  final List<Map<String, String>> _messages = [];
  bool _isLoading = false;

  // 语音相关
  late stt.SpeechToText _speech;
  bool _isListening = false;
  late FlutterTts _flutterTts;
  bool _ttsReady = false;

  // API地址
  final String _apiUrl = "http://10.3.163.254:8000/chat";

  @override
  void initState() {
    super.initState();

    // 初始化动画控制器
    _animController =
        AnimationController(
          vsync: this,
          duration: const Duration(milliseconds: 100),
        )..addListener(() {
          if (_isSpeaking) {
            setState(() {
              _mouthOpen = 0.3 + 0.4 * sin(_animController.value * 10 * pi);
            });
          }
        });

    // 初始化语音识别
    _speech = stt.SpeechToText();

    // 初始化语音合成
    _flutterTts = FlutterTts();
    _initTts();

    // 添加欢迎消息
    _messages.add({'role': 'ai', 'text': '您好！我是AI导游，请问有什么可以帮助您的？'});
  }

  // 初始化语音合成
  Future<void> _initTts() async {
    try {
      await _flutterTts.setLanguage("zh-CN");
      await _flutterTts.setSpeechRate(0.5);
      await _flutterTts.setVolume(1.0);
      await _flutterTts.setPitch(1.0);

      // 监听语音开始和结束
      _flutterTts.setStartHandler(() {
        setState(() => _isSpeaking = true);
        _animController.repeat();
      });

      _flutterTts.setCompletionHandler(() {
        setState(() {
          _isSpeaking = false;
          _mouthOpen = 0.0;
        });
        _animController.stop();
      });

      setState(() => _ttsReady = true);
      print("✅ 语音合成初始化成功");
    } catch (e) {
      print("❌ 语音合成初始化失败: $e");
    }
  }

  // 开始语音输入
  Future<void> _startListening() async {
    try {
      bool available = await _speech.initialize(
        onStatus: (status) => print("语音状态: $status"),
        onError: (error) => print("语音错误: $error"),
      );

      if (available) {
        setState(() => _isListening = true);

        await _speech.listen(
          onResult: (result) {
            setState(() {
              _textController.text = result.recognizedWords;
            });
          },
          localeId: "zh_CN",
          listenFor: const Duration(seconds: 10),
          pauseFor: const Duration(seconds: 3),
        );
      } else {
        _showSnackBar("语音识别不可用，请检查麦克风权限");
      }
    } catch (e) {
      print("❌ 语音输入失败: $e");
      _showSnackBar("语音输入失败: $e");
    }
  }

  // 停止语音输入
  Future<void> _stopListening() async {
    await _speech.stop();
    setState(() => _isListening = false);

    // 如果识别到文字，自动发送
    if (_textController.text.isNotEmpty) {
      _sendMessage(_textController.text);
    }
  }

  // 语音播报
  Future<void> _speak(String text) async {
    if (!_ttsReady) {
      print("⚠️ 语音合成未就绪");
      return;
    }

    try {
      await _flutterTts.speak(text);
    } catch (e) {
      print("❌ 语音播报失败: $e");
    }
  }

  // 发送消息
  Future<void> _sendMessage(String question) async {
    if (question.isEmpty) return;

    setState(() {
      _messages.add({'role': 'user', 'text': question});
      _isLoading = true;
    });
    _textController.clear();

    try {
      final response = await http.post(
        Uri.parse(_apiUrl),
        headers: {'Content-Type': 'application/json'},
        body: jsonEncode({
          'user_id': 'flutter_user',
          'session_id': 'demo_session',
          'question': question,
        }),
      );

      if (response.statusCode == 200) {
        final data = jsonDecode(response.body);
        final answer = data['data']['answer'];

        setState(() {
          _messages.add({'role': 'ai', 'text': answer});
          _isLoading = false;
        });

        // 语音播报回答
        _speak(answer);
      }
    } catch (e) {
      setState(() {
        _messages.add({'role': 'ai', 'text': '抱歉，连接服务器失败：$e'});
        _isLoading = false;
      });
    }
  }

  @override
  void dispose() {
    _animController.dispose();
    _textController.dispose();
    _speech.stop();
    _flutterTts.stop();
    super.dispose();
  }

  void _showSnackBar(String message) {
    ScaffoldMessenger.of(
      context,
    ).showSnackBar(SnackBar(content: Text(message)));
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFFF5F7FA),
      appBar: AppBar(
        title: const Text('AI 数字人导游'),
        centerTitle: true,
        backgroundColor: const Color(0xFF667EEA),
        foregroundColor: Colors.white,
        elevation: 0,
      ),
      body: Column(
        children: [
          // 数字人显示区域
          _buildDigitalPerson(),

          // 聊天记录
          Expanded(child: _buildChatList()),

          // 输入区域
          _buildInputArea(),
        ],
      ),
    );
  }

  Widget _buildDigitalPerson() {
    return Container(
      height: 240,
      decoration: const BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: [Color(0xFF667EEA), Color(0xFF764BA2)],
        ),
      ),
      child: Stack(
        children: [
          // 背景装饰
          Positioned(
            right: -30,
            top: -30,
            child: CircleAvatar(
              radius: 60,
              backgroundColor: Colors.white.withOpacity(0.1),
            ),
          ),
          Positioned(
            left: -20,
            bottom: -20,
            child: CircleAvatar(
              radius: 40,
              backgroundColor: Colors.white.withOpacity(0.08),
            ),
          ),

          // 数字人
          Center(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                CustomPaint(
                  size: const Size(160, 180),
                  painter: GuidePainter(mouthOpen: _mouthOpen),
                ),
                // 语音状态指示
                if (_isListening)
                  Container(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 12,
                      vertical: 4,
                    ),
                    decoration: BoxDecoration(
                      color: Colors.white.withOpacity(0.2),
                      borderRadius: BorderRadius.circular(20),
                    ),
                    child: const Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Icon(Icons.mic, color: Colors.white, size: 16),
                        SizedBox(width: 4),
                        Text(
                          "正在聆听...",
                          style: TextStyle(color: Colors.white, fontSize: 12),
                        ),
                      ],
                    ),
                  ),
                if (_isSpeaking)
                  Container(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 12,
                      vertical: 4,
                    ),
                    decoration: BoxDecoration(
                      color: Colors.white.withOpacity(0.2),
                      borderRadius: BorderRadius.circular(20),
                    ),
                    child: const Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Icon(Icons.volume_up, color: Colors.white, size: 16),
                        SizedBox(width: 4),
                        Text(
                          "正在说话...",
                          style: TextStyle(color: Colors.white, fontSize: 12),
                        ),
                      ],
                    ),
                  ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildChatList() {
    return ListView.builder(
      padding: const EdgeInsets.all(16),
      itemCount: _messages.length + (_isLoading ? 1 : 0),
      itemBuilder: (context, index) {
        if (index < _messages.length) {
          return _buildMessageBubble(_messages[index]);
        }
        return const Padding(
          padding: EdgeInsets.all(16),
          child: Center(child: CircularProgressIndicator()),
        );
      },
    );
  }

  Widget _buildMessageBubble(Map<String, String> message) {
    final isUser = message['role'] == 'user';
    return Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: Row(
        mainAxisAlignment: isUser
            ? MainAxisAlignment.end
            : MainAxisAlignment.start,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (!isUser)
            Container(
              margin: const EdgeInsets.only(right: 8),
              child: CircleAvatar(
                backgroundColor: const Color(0xFF667EEA),
                radius: 18,
                child: const Icon(
                  Icons.support_agent,
                  color: Colors.white,
                  size: 20,
                ),
              ),
            ),
          Flexible(
            child: Container(
              padding: const EdgeInsets.all(14),
              decoration: BoxDecoration(
                color: isUser ? const Color(0xFF667EEA) : Colors.white,
                borderRadius: BorderRadius.circular(16).copyWith(
                  bottomLeft: isUser ? const Radius.circular(16) : Radius.zero,
                  bottomRight: isUser ? Radius.zero : const Radius.circular(16),
                ),
                boxShadow: [
                  BoxShadow(
                    color: Colors.black.withOpacity(0.05),
                    blurRadius: 5,
                    offset: const Offset(0, 2),
                  ),
                ],
              ),
              child: Text(
                message['text'] ?? '',
                style: TextStyle(
                  color: isUser ? Colors.white : Colors.black87,
                  fontSize: 15,
                ),
              ),
            ),
          ),
          if (isUser)
            Container(
              margin: const EdgeInsets.only(left: 8),
              child: CircleAvatar(
                backgroundColor: Colors.orange[100],
                radius: 18,
                child: const Icon(Icons.person, color: Colors.orange, size: 20),
              ),
            ),
        ],
      ),
    );
  }

  Widget _buildInputArea() {
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: Colors.white,
        boxShadow: [
          BoxShadow(
            color: Colors.black.withOpacity(0.05),
            blurRadius: 10,
            offset: const Offset(0, -2),
          ),
        ],
      ),
      child: Row(
        children: [
          // 语音输入按钮
          GestureDetector(
            onLongPress: _startListening,
            onLongPressUp: _stopListening,
            child: Container(
              width: 48,
              height: 48,
              decoration: BoxDecoration(
                color: _isListening ? Colors.red[400] : Colors.grey[200],
                shape: BoxShape.circle,
              ),
              child: Icon(
                _isListening ? Icons.mic : Icons.mic_none,
                color: _isListening ? Colors.white : Colors.grey[600],
              ),
            ),
          ),
          const SizedBox(width: 10),
          // 文本输入框
          Expanded(
            child: TextField(
              controller: _textController,
              decoration: InputDecoration(
                hintText: _isListening ? "正在聆听..." : "输入您的问题...",
                border: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(25),
                  borderSide: BorderSide.none,
                ),
                filled: true,
                fillColor: Colors.grey[100],
                contentPadding: const EdgeInsets.symmetric(
                  horizontal: 20,
                  vertical: 12,
                ),
              ),
              onSubmitted: (value) => _sendMessage(value),
            ),
          ),
          const SizedBox(width: 10),
          // 发送按钮
          GestureDetector(
            onTap: () => _sendMessage(_textController.text.trim()),
            child: Container(
              width: 48,
              height: 48,
              decoration: const BoxDecoration(
                color: Color(0xFF667EEA),
                shape: BoxShape.circle,
              ),
              child: const Icon(Icons.send, color: Colors.white),
            ),
          ),
        ],
      ),
    );
  }
}

// 数字人绘制器
class GuidePainter extends CustomPainter {
  final double mouthOpen;

  GuidePainter({this.mouthOpen = 0.0});

  @override
  void paint(Canvas canvas, Size size) {
    final cx = size.width / 2;
    final cy = size.height / 2;

    // 头发
    final hairPaint = Paint()
      ..color = Colors.brown[700]!
      ..style = PaintingStyle.fill;
    canvas.drawPath(
      Path()
        ..moveTo(cx - 80, cy - 60)
        ..quadraticBezierTo(cx - 100, cy - 110, cx - 40, cy - 120)
        ..quadraticBezierTo(cx, cy - 130, cx + 40, cy - 120)
        ..quadraticBezierTo(cx + 100, cy - 105, cx + 80, cy - 55)
        ..close(),
      hairPaint,
    );

    // 脸
    canvas.drawCircle(
      Offset(cx, cy - 10),
      70,
      Paint()
        ..color = const Color(0xFFFFE0BD)
        ..style = PaintingStyle.fill,
    );

    // 眼睛
    canvas.drawCircle(
      Offset(cx - 22, cy - 25),
      10,
      Paint()..color = Colors.white,
    );
    canvas.drawCircle(
      Offset(cx + 22, cy - 25),
      10,
      Paint()..color = Colors.white,
    );
    canvas.drawCircle(
      Offset(cx - 22, cy - 25),
      6,
      Paint()..color = Colors.black87,
    );
    canvas.drawCircle(
      Offset(cx + 22, cy - 25),
      6,
      Paint()..color = Colors.black87,
    );

    // 嘴巴
    final mouthPaint = Paint()
      ..color = const Color(0xFFE57373)
      ..style = PaintingStyle.fill;

    if (mouthOpen > 0.1) {
      canvas.drawOval(
        Rect.fromCenter(
          center: Offset(cx, cy + 15),
          width: 22,
          height: 8 + mouthOpen * 18,
        ),
        mouthPaint,
      );
    } else {
      canvas.drawPath(
        Path()
          ..moveTo(cx - 15, cy + 15)
          ..quadraticBezierTo(cx, cy + 5, cx + 15, cy + 15)
          ..close(),
        mouthPaint,
      );
    }

    // 身体
    final bodyPaint = Paint()
      ..color = Colors.blue[400]!
      ..style = PaintingStyle.fill;
    canvas.drawRRect(
      RRect.fromRectAndCorners(
        Rect.fromLTWH(cx - 35, cy + 60, 70, 80),
        topLeft: const Radius.circular(10),
        topRight: const Radius.circular(10),
      ),
      bodyPaint,
    );
  }

  @override
  bool shouldRepaint(GuidePainter oldDelegate) =>
      oldDelegate.mouthOpen != mouthOpen;
}
