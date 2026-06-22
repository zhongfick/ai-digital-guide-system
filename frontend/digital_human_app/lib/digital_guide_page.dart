import 'avatar_bridge.dart';
import 'avatar_frame.dart';
import 'speech_input.dart';
import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import 'dart:convert';
import 'package:flutter_tts/flutter_tts.dart';
import 'package:flutter_inappwebview/flutter_inappwebview.dart';

enum _PortalSide { visitor, admin }

class DigitalGuidePage extends StatefulWidget {
  const DigitalGuidePage({super.key});

  @override
  State<DigitalGuidePage> createState() => _DigitalGuidePageState();
}

class _DigitalGuidePageState extends State<DigitalGuidePage> {
  bool _isSpeaking = false;

  // 对话相关
  final TextEditingController _textController = TextEditingController();
  final List<Map<String, String>> _messages = [];
  bool _isLoading = false;

  // 语音相关
  bool _isListening = false;
  late FlutterTts _flutterTts;
  bool _ttsReady = false;

  // WebView控制器
  InAppWebViewController? _webController;
  bool _avatarReady = false;
  final List<String> _pendingAvatarActions = [];
  _PortalSide _selectedSide = _PortalSide.visitor;


  // API地址
  final String _apiUrl = "http://127.0.0.1:8000/chat";

  @override
  void initState() {
    super.initState();

    // 初始化语音识别
    _initSpeech();

    // 初始化语音合成
    _flutterTts = FlutterTts();
    _initTts();

    // 添加欢迎消息
    _messages.add({'role': 'ai', 'text': '您好！我是AI导游，请问有什么可以帮助您的？'});

    // Flutter Web 通过 postMessage 接收数字人就绪信号
    setupAvatarMessageListener(_onAvatarReady);
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
        _sendAvatarAction('startTalking');
      });

      _flutterTts.setCompletionHandler(() {
        _onSpeechEnded();
      });

      _flutterTts.setCancelHandler(() {
        _onSpeechEnded();
      });

      setState(() => _ttsReady = true);
      debugPrint("✅ 语音合成初始化成功");
    } catch (e) {
      debugPrint("❌ 语音合成初始化失败: $e");
    }
  }

  // 初始化语音识别
  Future<void> _initSpeech() async {
    try {
      final available = await initSpeechInput(
        onStatus: (status) {
          debugPrint("语音状态: $status");
          if ((status == 'done' ||
                  status == 'notListening' ||
                  status == 'doneNoResult') &&
              _isListening) {
            setState(() => _isListening = false);
          }
        },
        onError: (error) {
          debugPrint("语音错误: $error");
          setState(() => _isListening = false);
          _showSnackBar("语音识别失败: $error");
        },
      );

      if (available) {
        debugPrint("✅ 语音识别初始化成功，语言: $speechInputLocale");
      } else {
        debugPrint("❌ 语音识别不可用");
      }
    } catch (e) {
      debugPrint("❌ 语音识别初始化失败: $e");
    }
  }

  // 点击切换语音输入
  Future<void> _toggleListening() async {
    if (_isListening) {
      await _finishListening(sendMessage: true);
      return;
    }

    if (!speechInputAvailable) {
      await _initSpeech();
      if (!speechInputAvailable) {
        _showSnackBar(speechInputUnsupportedMessage);
        return;
      }
    }

    if (_isSpeaking) {
      await _stopSpeaking();
    }

    setState(() => _isListening = true);

    try {
      final started = await startSpeechInput(
        onResult: (text, isFinal) {
          setState(() {
            _textController.text = text;
          });
          if (isFinal) {
            _finishListening(sendMessage: true);
          }
        },
        onStatus: (status) {
         debugPrint("语音状态: $status");
          if (status == 'notListening' && _isListening) {
            _finishListening(sendMessage: true);
          }
        },
        onError: (error) {
          setState(() => _isListening = false);
          if (error.contains('未检测到语音')) {
            _showSnackBar(error);
          } else {
            _showSnackBar("语音识别失败: $error");
          }
        },
        locale: speechInputLocale,
      );

      if (!started) {
        setState(() => _isListening = false);
        _showSnackBar("无法启动语音识别，请检查麦克风权限");
      }
    } catch (e) {
      setState(() => _isListening = false);
      debugPrint("❌ 语音输入失败: $e");
      _showSnackBar("语音输入失败: $e");
    }
  }

  Future<void> _finishListening({required bool sendMessage}) async {
    if (!_isListening) return;

    await stopSpeechInput();
    setState(() => _isListening = false);

    final text = _textController.text.trim();
    if (sendMessage && text.isNotEmpty) {
      _sendMessage(text);
    }
  }

  // 向数字人发送动作指令
  Future<void> _sendAvatarAction(String action) async {
    if (kIsWeb) {
      final sent = sendAvatarCommandToIframe(action);
      if (!sent) {
        _pendingAvatarActions.add(action);
        debugPrint("⚠️ iframe未找到，指令排队: $action");
        return;
      }
      debugPrint("✅ 发送数字人动作(Web): $action");
      return;
    }

    if (_webController == null) {
      _pendingAvatarActions.add(action);
      debugPrint("⚠️ WebView未创建，指令排队: $action");
      return;
    }
    if (!_avatarReady) {
      _pendingAvatarActions.add(action);
      debugPrint("⚠️ 数字人JS未就绪，指令排队: $action");
      return;
    }
    try {
      await _webController!.evaluateJavascript(
        source: "window.sendAvatarCommand('$action');",
      );
      debugPrint("✅ 发送数字人动作: $action");
    } catch (e) {
      debugPrint("❌ 发送数字人动作失败: $e");
    }
  }

  Future<void> _flushPendingAvatarActions() async {
    final pending = List<String>.from(_pendingAvatarActions);
    _pendingAvatarActions.clear();
    for (final action in pending) {
      await _sendAvatarAction(action);
    }
  }

  void _onAvatarReady() {
    if (_avatarReady) return;
    setState(() => _avatarReady = true);
    debugPrint("✅ 数字人JS桥接就绪");
    _flushPendingAvatarActions();
  }

  Future<void> _waitForAvatarReady(InAppWebViewController controller) async {
    if (kIsWeb) {
      // Web 平台用 postMessage，不用 evaluateJavascript（跨域会被拦截）
      return;
    }
    for (var i = 0; i < 30 && !_avatarReady; i++) {
      await Future.delayed(const Duration(milliseconds: 500));
      try {
        final ready = await controller.evaluateJavascript(
          source:
              "(window.avatarControl && window.sendAvatarCommand) ? 'ready' : 'not_ready';",
        );
        final readyStr = ready?.toString() ?? '';
        if (readyStr.contains('ready') && !readyStr.contains('not_ready')) {
          _onAvatarReady();
          return;
        }
      } catch (e) {
        debugPrint("轮询数字人就绪失败: $e");
      }
    }
    debugPrint("⚠️ 数字人就绪超时");
  }

  void _onSpeechEnded() {
    if (!_isSpeaking) return;
    setState(() => _isSpeaking = false);
    _sendAvatarAction('stopTalking');
  }

  // 停止语音播报
  Future<void> _stopSpeaking() async {
    if (!_isSpeaking) return;
    try {
      await _flutterTts.stop();
    } catch (e) {
      debugPrint("❌ 停止语音播报失败: $e");
      _onSpeechEnded();
    }
  }

  // 语音播报
  Future<void> _speak(String text) async {
    if (!_ttsReady) {
      debugPrint("⚠️ 语音合成未就绪");
      return;
    }

    try {
      if (_isSpeaking) {
        await _flutterTts.stop();
      }
      await _sendAvatarAction('startTalking');
      await _flutterTts.speak(text);
    } catch (e) {
      debugPrint("❌ 语音播报失败: $e");
      await _sendAvatarAction('stopTalking');
    }
  }

  void _syncAvatarTalkingState(String answer) {
    if (answer.trim().isEmpty) return;
    _sendAvatarAction('startTalking');
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

        // 语音播报回答，同时让数字人保持谈话状态，直到播报结束再切回待机
        _syncAvatarTalkingState(answer);
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
    _textController.dispose();
    cancelSpeechInput();
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
          _buildModeSwitch(),
          Expanded(
            child: AnimatedSwitcher(
              duration: const Duration(milliseconds: 250),
              child: _selectedSide == _PortalSide.visitor
                  ? _buildVisitorPanel(key: const ValueKey('visitor'))
                  : _buildAdminPanel(key: const ValueKey('admin')),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildModeSwitch() {
    return Container(
      padding: const EdgeInsets.all(16),
      color: const Color(0xFFF5F7FA),
      child: SegmentedButton<_PortalSide>(
        segments: const [
          ButtonSegment(value: _PortalSide.visitor, label: Text('游客交互'), icon: Icon(Icons.record_voice_over)),
          ButtonSegment(value: _PortalSide.admin, label: Text('管理后台'), icon: Icon(Icons.admin_panel_settings)),
        ],
        selected: {_selectedSide},
        onSelectionChanged: (set) {
          setState(() => _selectedSide = set.first);
        },
        showSelectedIcon: false,
      ),
    );
  }

  Widget _buildVisitorPanel({Key? key}) {
    return Container(
      key: key,
      margin: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(24),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withOpacity(0.08),
            blurRadius: 24,
            offset: const Offset(0, 12),
          ),
        ],
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          _buildSectionHeader(
            title: '导游在此！',
            subtitle: '欢迎各位游客',
          ),
          Expanded(
            child: ClipRRect(
              borderRadius: BorderRadius.circular(24),
              child: Column(
                children: [
                  Expanded(child: _buildDigitalPerson()),
                  SafeArea(
                    top: false,
                    child: _buildInputArea(),
                  ),
                ],
              ),
            ),
          ),
          SizedBox(height: 220, child: _buildChatList()),
        ],
      ),
    );
  }

  Widget _buildAdminPanel({Key? key}) {
    return Container(
      key: key,
      margin: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(24),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withOpacity(0.08),
            blurRadius: 24,
            offset: const Offset(0, 12),
          ),
        ],
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          _buildSectionHeader(
            title: '管理后台',
            subtitle: '知识库、数字人配置、游客分析与数据概览',
            trailing: Container(
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
              decoration: BoxDecoration(
                color: const Color(0xFF667EEA),
                borderRadius: BorderRadius.circular(999),
              ),
              child: const Text(
                '运营总览',
                style: TextStyle(color: Colors.white, fontWeight: FontWeight.w600),
              ),
            ),
          ),
          Expanded(
            child: SingleChildScrollView(
              padding: const EdgeInsets.all(16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  _buildDashboardOverview(),
                  const SizedBox(height: 16),
                  _buildAdminSectionCard(
                    icon: Icons.menu_book_rounded,
                    title: '知识库管理',
                    subtitle: '上传、更新和维护景区讲解词、文史资料、常见问题及答案等知识文档。',
                    accent: const Color(0xFF5B8DEF),
                    child: _buildKnowledgeLibraryPanel(),
                  ),
                  const SizedBox(height: 16),
                  _buildAdminSectionCard(
                    icon: Icons.face_retouching_natural_rounded,
                    title: '数字人形象管理',
                    subtitle: '配置数字人的外观、服装、声音与风格，使其更贴合景区文化特色。',
                    accent: const Color(0xFF7C5CFF),
                    child: _buildAvatarManagementPanel(),
                  ),
                  const SizedBox(height: 16),
                  _buildAdminSectionCard(
                    icon: Icons.analytics_rounded,
                    title: '游客感受度报告',
                    subtitle: '分析交互记录，生成游客关注点、情感趋势与服务建议反馈。',
                    accent: const Color(0xFF18A999),
                    child: _buildVisitorReportPanel(),
                  ),

                ],
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildDashboardOverview() {
    return Container(
      padding: const EdgeInsets.all(18),
      decoration: BoxDecoration(
        gradient: const LinearGradient(
          colors: [Color(0xFF667EEA), Color(0xFF764BA2)],
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
        ),
        borderRadius: BorderRadius.circular(22),
        boxShadow: [
          BoxShadow(
            color: const Color(0xFF667EEA).withOpacity(0.25),
            blurRadius: 20,
            offset: const Offset(0, 10),
          ),
        ],
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text(
            '管理后台概览',
            style: TextStyle(color: Colors.white, fontSize: 20, fontWeight: FontWeight.w700),
          ),
          const SizedBox(height: 8),
          Text(
            '统一查看知识运营、数字人配置、用户反馈和服务运营表现。',
            style: TextStyle(color: Colors.white.withOpacity(0.9), fontSize: 13),
          ),
          const SizedBox(height: 18),
          LayoutBuilder(
            builder: (context, constraints) {
              return Wrap(
                spacing: 12,
                runSpacing: 12,
                children: [
                  _buildMetricCard('今日服务人次', '1,286', Icons.people_alt_rounded, constraints.maxWidth),
                  _buildMetricCard('本周问答', '42', Icons.question_answer_rounded, constraints.maxWidth),
                  _buildMetricCard('满意度趋势', '96.4%', Icons.sentiment_satisfied_alt_rounded, constraints.maxWidth),
                  _buildMetricCard('新增知识文档', '18', Icons.note_add_rounded, constraints.maxWidth),
                ],
              );
            },
          ),
        ],
      ),
    );
  }

  Widget _buildMetricCard(String label, String value, IconData icon, double width) {
    final cardWidth = width > 700 ? (width - 36) / 4 : width > 500 ? (width - 12) / 2 : width;
    return Container(
      width: cardWidth,
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: Colors.white.withOpacity(0.14),
        borderRadius: BorderRadius.circular(18),
        border: Border.all(color: Colors.white.withOpacity(0.18)),
      ),
      child: Row(
        children: [
          Container(
            padding: const EdgeInsets.all(10),
            decoration: BoxDecoration(
              color: Colors.white.withOpacity(0.18),
              borderRadius: BorderRadius.circular(14),
            ),
            child: Icon(icon, color: Colors.white, size: 22),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(value, style: const TextStyle(color: Colors.white, fontSize: 18, fontWeight: FontWeight.w700)),
                const SizedBox(height: 2),
                Text(label, style: TextStyle(color: Colors.white.withOpacity(0.9), fontSize: 12)),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildAdminSectionCard({
    required IconData icon,
    required String title,
    required String subtitle,
    required Color accent,
    required Widget child,
  }) {
    return Container(
      padding: const EdgeInsets.all(18),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(20),
        border: Border.all(color: Colors.grey.shade200),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withOpacity(0.03),
            blurRadius: 18,
            offset: const Offset(0, 8),
          ),
        ],
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Container(
                padding: const EdgeInsets.all(12),
                decoration: BoxDecoration(
                  color: accent.withOpacity(0.12),
                  borderRadius: BorderRadius.circular(16),
                ),
                child: Icon(icon, color: accent, size: 24),
              ),
              const SizedBox(width: 14),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(title, style: const TextStyle(fontSize: 17, fontWeight: FontWeight.w700)),
                    const SizedBox(height: 4),
                    Text(subtitle, style: TextStyle(fontSize: 13, color: Colors.grey.shade600)),
                  ],
                ),
              ),
            ],
          ),
          const SizedBox(height: 16),
          child,
        ],
      ),
    );
  }

  Widget _buildKnowledgeLibraryPanel() {
    return Wrap(
      spacing: 12,
      runSpacing: 12,
      children: [
        _buildInfoTile(Icons.upload_file_rounded, '文档上传', '支持讲解词、文史资料、FAQ 批量导入'),
        _buildInfoTile(Icons.edit_note_rounded, '内容维护', '支持版本更新、审核与发布回滚'),
       
        
      ],
    );
  }

  Widget _buildAvatarManagementPanel() {
    return Wrap(
      spacing: 12,
      runSpacing: 12,
      children: [
        _buildInfoTile(Icons.checkroom_rounded, '外观配置', '设置数字人形象、发型、配色与风格'),
      ],
    );
  }

  Widget _buildVisitorReportPanel() {
    return Column(
      children: [
        _buildInfoTile(Icons.insights_rounded, '关注点分析', '统计游客最常询问的景点、路线与服务问题'),
        const SizedBox(height: 12),
        _buildInfoTile(Icons.auto_graph_rounded, '情感趋势报告', '分析咨询过程中的情绪变化与满意度波动'),
        const SizedBox(height: 12),
        _buildInfoTile(Icons.feedback_rounded, '服务建议', '输出高频投诉点、优化建议与改进优先级'),
      ],
    );
  }



  Widget _buildInfoTile(IconData icon, String title, String desc) {
    return Container(
      constraints: const BoxConstraints(minWidth: 170),
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: const Color(0xFFF8FAFF),
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: const Color(0xFFE6ECFF)),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Container(
            padding: const EdgeInsets.all(10),
            decoration: BoxDecoration(
              color: const Color(0xFF667EEA).withOpacity(0.12),
              borderRadius: BorderRadius.circular(12),
            ),
            child: Icon(icon, color: const Color(0xFF667EEA), size: 20),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(title, style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w700)),
                const SizedBox(height: 4),
                Text(desc, style: TextStyle(fontSize: 12, color: Colors.grey.shade600, height: 1.35)),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildSectionHeader({
    required String title,
    required String subtitle,
    Widget? trailing,
  }) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 16),
      decoration: BoxDecoration(
        gradient: LinearGradient(
          colors: [Colors.blueGrey.shade50, Colors.white],
        ),
        border: Border(bottom: BorderSide(color: Colors.grey.shade200)),
      ),
      child: Row(
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(title, style: const TextStyle(fontSize: 18, fontWeight: FontWeight.w700)),
                const SizedBox(height: 4),
                Text(subtitle, style: TextStyle(fontSize: 12, color: Colors.grey.shade600)),
              ],
            ),
          ),
          if (trailing != null) trailing,
        ],
      ),
    );
  }

  Widget _buildStatusChip(IconData icon, String text, {bool showStop = false}) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
      decoration: BoxDecoration(
        color: Colors.white.withOpacity(0.2),
        borderRadius: BorderRadius.circular(20),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, color: Colors.white, size: 16),
          const SizedBox(width: 4),
          Text(text, style: const TextStyle(color: Colors.white, fontSize: 12)),
          if (showStop) ...[
            const SizedBox(width: 6),
            const Icon(Icons.stop_circle, color: Colors.white, size: 16),
          ],
        ],
      ),
    );
  }

  Widget _buildDigitalPerson() {
    return Container(
      width: double.infinity,
      height: double.infinity,
      decoration: const BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: [Color(0xFF667EEA), Color(0xFF764BA2)],
        ),
      ),
      child: Stack(
        fit: StackFit.expand,
        children: [
          Positioned(
            right: -30,
            top: -30,
            child: CircleAvatar(radius: 60, backgroundColor: Colors.white.withOpacity(0.1)),
          ),
          Positioned(
            left: -20,
            bottom: -20,
            child: CircleAvatar(radius: 40, backgroundColor: Colors.white.withOpacity(0.08)),
          ),
          Positioned.fill(
            child: InAppWebView(
              initialSettings: InAppWebViewSettings(
                javaScriptEnabled: true,
                domStorageEnabled: true,
                allowsInlineMediaPlayback: true,
                mediaPlaybackRequiresUserGesture: false,
                transparentBackground: true,
                isInspectable: kIsWeb,
              ),
              initialUrlRequest: URLRequest(url: WebUri(avatarFrameUrl)),
              onWebViewCreated: (controller) {
                _webController = controller;
                if (!kIsWeb) {
                  controller.addJavaScriptHandler(
                    handlerName: 'avatarReady',
                    callback: (args) {
                      _onAvatarReady();
                    },
                  );
                }
              },
              onLoadStop: (controller, url) async {
                print("✅ 数字人页面HTML加载完成");
                await _waitForAvatarReady(controller);
              },
              onConsoleMessage: (controller, msg) {
                print("🌐 WebView: ${msg.message}");
              },
            ),
          ),
          Positioned(
            bottom: 10,
            left: 0,
            right: 0,
            child: Center(
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  if (_isListening)
                    _buildStatusChip(Icons.mic, '正在聆听...'),
                  if (_isSpeaking) ...[
                    const SizedBox(width: 8),
                    GestureDetector(
                      onTap: _stopSpeaking,
                      child: _buildStatusChip(Icons.volume_up, '正在说话...', showStop: true),
                    ),
                  ],
                ],
              ),
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
        border: Border(top: BorderSide(color: Colors.grey.shade200)),
      ),
      child: Row(
        children: [
          GestureDetector(
            onTap: _toggleListening,
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
          if (_isSpeaking)
            GestureDetector(
              onTap: _stopSpeaking,
              child: Container(
                width: 48,
                height: 48,
                decoration: BoxDecoration(
                  color: Colors.red[400],
                  shape: BoxShape.circle,
                ),
                child: const Icon(Icons.stop, color: Colors.white),
              ),
            ),
          if (_isSpeaking) const SizedBox(width: 10),
          Expanded(
            child: TextField(
              controller: _textController,
              decoration: InputDecoration(
                hintText: _isListening ? "正在聆听，再次点击麦克风结束..." : "输入您的问题，或点击麦克风语音输入",
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
