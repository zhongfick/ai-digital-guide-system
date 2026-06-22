import 'avatar_bridge.dart';
import 'avatar_frame.dart';
import 'speech_input.dart';
import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import 'dart:convert';
import 'package:flutter_tts/flutter_tts.dart';
import 'package:flutter_inappwebview/flutter_inappwebview.dart';
import 'package:file_picker/file_picker.dart';

enum _PortalSide { visitor, admin }

class DigitalGuidePage extends StatefulWidget {
  const DigitalGuidePage({super.key});

  @override
  State<DigitalGuidePage> createState() => _DigitalGuidePageState();
}

class SentimentReportPage extends StatelessWidget {
  final String report;
  const SentimentReportPage({super.key, required this.report});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('游客感受度报告')),
      body: SingleChildScrollView(
        padding: const EdgeInsets.all(20),
        child: Container(
          width: double.infinity,
          padding: const EdgeInsets.all(20),
          decoration: BoxDecoration(
            color: Colors.white,
            borderRadius: BorderRadius.circular(20),
          ),
          child: Text(report, style: const TextStyle(fontSize: 15, height: 1.6)),
        ),
      ),
    );
  }
}

class _DigitalGuidePageState extends State<DigitalGuidePage> {
  bool _isSpeaking = false;
  int _speakToken = 0;
  static const String _backendBaseUrl = 'http://127.0.0.1:8000';

  // 对话相关
  final TextEditingController _textController = TextEditingController();
  final List<Map<String, String>> _messages = [];
  bool _isLoading = false;

  // 知识库管理
  bool _isUploadingKnowledge = false;
  bool _isLoadingKnowledgeFiles = false;
  bool _isLoadingMetrics = false;
  List<Map<String, dynamic>> _knowledgeFiles = [];
  Map<String, dynamic>? _dashboardMetrics;

  // 语音相关
  bool _isListening = false;
  late FlutterTts _flutterTts;
  bool _ttsReady = false;

  // WebView控制器
  InAppWebViewController? _webController;
  bool _avatarReady = false;
  final List<String> _pendingAvatarActions = [];
  _PortalSide _selectedSide = _PortalSide.visitor;
  String _selectedGuideType = 'mouse';
  int _avatarViewNonce = 0;


  // API地址
  final String _apiUrl = "http://127.0.0.1:8000/chat";
  final String _knowledgeListUrl = '$_backendBaseUrl/knowledge/files';
  final String _knowledgeUploadUrl = '$_backendBaseUrl/knowledge/upload';

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

    _loadDashboardMetrics();
    _loadKnowledgeFiles();

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
        _startAvatarTalking();
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
    debugPrint('➡️ 准备发送数字人动作: $action, web=$kIsWeb, ready=$_avatarReady, controller=${_webController != null}');

    final delivered = await _dispatchAvatarAction(action);
    if (!delivered) {
      _pendingAvatarActions.add(action);
      debugPrint('⚠️ 数字人未就绪或控制器不可用，指令排队: $action');
    }
  }

  Future<bool> _dispatchAvatarAction(String action) async {
    final controller = _webController;
    if (controller != null && _avatarReady) {
      try {
        await controller.evaluateJavascript(
          source: "window.__setAvatarAction__ && window.__setAvatarAction__('$action');",
        );
        debugPrint('✅ 写入数字人待处理动作(WebView): $action');
        return true;
      } catch (e) {
        debugPrint('❌ 写入数字人待处理动作(WebView)失败: $e');
      }
    }

    if (kIsWeb) {
      final sent = sendAvatarCommandToIframe(action);
      debugPrint('🌐 iframe发送结果: action=$action sent=$sent');
      return sent;
    }

    return false;
  }

  String _avatarUrlForGuide(String guideType) {
    final base = avatarFrameUrl;
    final uri = Uri.parse(base);
    return uri.replace(queryParameters: {
      ...uri.queryParameters,
      'guide': guideType,
      'v': _avatarViewNonce.toString(),
    }).toString();
  }

  Future<void> _reloadAvatarForGuide(String guideType) async {
    final controller = _webController;
    if (controller == null) {
      debugPrint('⚠️ WebView 控制器不可用，无法重载数字人页面');
      return;
    }

    _avatarViewNonce += 1;
    final url = _avatarUrlForGuide(guideType);
    debugPrint('🟣 重新加载数字人页面: $url');

    try {
      _avatarReady = false;
      await controller.loadUrl(urlRequest: URLRequest(url: WebUri(url)));
      debugPrint('✅ 已触发数字人页面重载: $guideType');
    } catch (e) {
      debugPrint('❌ 重载数字人页面失败: $e');
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
    _sendAvatarAction(_selectedGuideType == 'mouse' ? 'guideMouse' : 'guideHuman');
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
    debugPrint('🛑 语音结束，准备切回待机');
    setState(() => _isSpeaking = false);
    _sendAvatarAction('stopTalking');
  }

  Future<void> _startAvatarTalking() async {
    _speakToken += 1;
    final token = _speakToken;
    setState(() => _isSpeaking = true);
    debugPrint('🗣️ 数字人进入说话状态, token=$token');
    await _sendAvatarAction('startTalking');
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
      await _startAvatarTalking();
      debugPrint('🗣️ 即将开始 TTS 播报，文本长度=${text.length}');
      final result = await _flutterTts.speak(text);
      debugPrint('🗣️ TTS speak 返回: $result');
    } catch (e) {
      debugPrint("❌ 语音播报失败: $e");
      await _sendAvatarAction('stopTalking');
    }
  }

  Future<void> _syncAvatarTalkingState(String answer) async {
    if (answer.trim().isEmpty) return;
    await _startAvatarTalking();
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
        await _syncAvatarTalkingState(answer);
        await _speak(answer);
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

  Future<void> _loadDashboardMetrics() async {
    setState(() => _isLoadingMetrics = true);
    try {
      final response = await http.get(Uri.parse('$_backendBaseUrl/dashboard/metrics'));
      if (response.statusCode == 200) {
        final data = jsonDecode(response.body) as Map<String, dynamic>;
        final metrics = data['data'] as Map<String, dynamic>?;
        if (metrics != null && mounted) {
          setState(() => _dashboardMetrics = metrics);
        }
      }
    } catch (e) {
      _showSnackBar('加载概览数据失败: $e');
    } finally {
      if (mounted) {
        setState(() => _isLoadingMetrics = false);
      }
    }
  }

  Future<void> _loadKnowledgeFiles() async {
    setState(() => _isLoadingKnowledgeFiles = true);
    try {
      final response = await http.get(Uri.parse(_knowledgeListUrl));
      if (response.statusCode == 200) {
        final data = jsonDecode(response.body) as Map<String, dynamic>;
        final files = (data['data'] as List<dynamic>? ?? [])
            .cast<Map<String, dynamic>>();
        setState(() => _knowledgeFiles = files);
      }
    } catch (e) {
      _showSnackBar('加载知识库失败: $e');
    } finally {
      if (mounted) {
        setState(() => _isLoadingKnowledgeFiles = false);
      }
    }
  }

  Future<void> _pickAndUploadKnowledgeFile() async {
    if (_isUploadingKnowledge) return;
    try {
      final result = await FilePicker.platform.pickFiles(
        allowMultiple: false,
        withData: true,
        withReadStream: true,
      );
      if (result == null || result.files.isEmpty) return;

      final file = result.files.first;

      setState(() => _isUploadingKnowledge = true);

      final request = http.MultipartRequest(
        'POST',
        Uri.parse(_knowledgeUploadUrl),
      );

      final bytes = file.bytes;
      if (bytes != null) {
        request.files.add(http.MultipartFile.fromBytes(
          'file',
          bytes,
          filename: file.name,
        ));
      } else if (file.readStream != null) {
        request.files.add(http.MultipartFile(
          'file',
          file.readStream!,
          file.size,
          filename: file.name,
        ));
      } else {
        _showSnackBar('未读取到文件内容，请重新选择文件');
        return;
      }

      final response = await request.send();
      if (response.statusCode == 200) {
        _showSnackBar('文档上传成功');
        await _loadKnowledgeFiles();
      } else {
        _showSnackBar('上传失败：${response.statusCode}');
      }
    } catch (e) {
      _showSnackBar('上传失败: $e');
    } finally {
      if (mounted) {
        setState(() => _isUploadingKnowledge = false);
      }
    }
  }

  Future<void> _deleteKnowledgeFile(String filename) async {
    try {
      final response = await http.delete(Uri.parse('$_backendBaseUrl/knowledge/files/$filename'));
      if (response.statusCode == 200) {
        _showSnackBar('删除成功');
        await _loadKnowledgeFiles();
      } else {
        _showSnackBar('删除失败：${response.statusCode}');
      }
    } catch (e) {
      _showSnackBar('删除失败: $e');
    }
  }

  Future<void> _generateSentimentReport() async {
    try {
      setState(() => _isLoading = true);
      final response = await http.post(
        Uri.parse('$_backendBaseUrl/reports/sentiment'),
        headers: {'Content-Type': 'application/json'},
        body: jsonEncode({'limit': 30}),
      );
      if (response.statusCode == 200) {
        final data = jsonDecode(response.body) as Map<String, dynamic>;
        final report = data['data']?['report']?.toString() ?? '暂无报告内容';
        if (!mounted) return;
        Navigator.of(context).push(
          MaterialPageRoute(
            builder: (_) => SentimentReportPage(report: report),
          ),
        );
      } else {
        _showSnackBar('生成失败：${response.statusCode}');
      }
    } catch (e) {
      _showSnackBar('生成失败: $e');
    } finally {
      if (mounted) setState(() => _isLoading = false);
    }
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
            subtitle: '欢迎各位游客,导游已接入DEEPSEEK大模型，准备为您提供全方位的景区讲解与智能问答服务！',
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
                    child: Column(
                      children: [
                        _buildKnowledgeLibraryPanel(),
                        const SizedBox(height: 16),
                        _buildInfoTile(Icons.folder_open_rounded, '说明', '点击“文档上传”导入文件，点击“内容维护”刷新并查看列表。'),
                      ],
                    ),
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
                    subtitle: '基于历史问答记录，实时生成综合感受度分析报告。',
                    accent: const Color(0xFF18A999),
                    child: _buildSentimentReportPanel(),
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
              final metrics = _dashboardMetrics;
              return Wrap(
                spacing: 12,
                runSpacing: 12,
                children: [
                  _buildMetricCard('今日服务人次', metrics?['today_services']?.toString() ?? '0', Icons.people_alt_rounded, constraints.maxWidth),
                  _buildMetricCard('本周问答', metrics?['weekly_questions']?.toString() ?? '0', Icons.question_answer_rounded, constraints.maxWidth),
                  _buildMetricCard('满意度趋势', '${(metrics?['satisfaction_rate'] ?? 0).toString()}%', Icons.sentiment_satisfied_alt_rounded, constraints.maxWidth),
                  _buildMetricCard('新增知识文档', metrics?['knowledge_docs']?.toString() ?? '0', Icons.note_add_rounded, constraints.maxWidth),
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
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Row(
          children: [
            Expanded(
              child: _buildActionTile(
                icon: Icons.upload_file_rounded,
                title: '文档上传',
                desc: '支持讲解词、文史资料、FAQ 批量导入',
                onTap: _isUploadingKnowledge ? null : _pickAndUploadKnowledgeFile,
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: _buildActionTile(
                icon: Icons.edit_note_rounded,
                title: '内容维护',
                desc: '查看已导入的文档并进行删除维护',
                onTap: _loadKnowledgeFiles,
              ),
            ),
          ],
        ),
        const SizedBox(height: 16),
        _buildKnowledgeFileList(),
      ],
    );
  }

  Widget _buildAvatarManagementPanel() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        SegmentedButton<String>(
          segments: const [
            ButtonSegment(value: 'mouse', label: Text('小鼠导游'), icon: Icon(Icons.pets)),
            ButtonSegment(value: 'human', label: Text('人类导游'), icon: Icon(Icons.person)),
          ],
          selected: {_selectedGuideType},
          onSelectionChanged: (set) {
            final value = set.first;
            debugPrint('🟣 点击切换导游类型: $value, 当前=$_selectedGuideType');
            setState(() => _selectedGuideType = value);
            final action = value == 'mouse' ? 'guideMouse' : 'guideHuman';
            debugPrint('🟣 即将调用 _sendAvatarAction($action)');
            setState(() {
              _avatarReady = false;
              _avatarViewNonce += 1;
            });
            _reloadAvatarForGuide(value).then((_) {
              _sendAvatarAction(action);
            });
          },
          showSelectedIcon: false,
        ),
        const SizedBox(height: 16),
        _buildInfoTile(Icons.checkroom_rounded, '动作配置', '小鼠使用 Idle/Talking，人类使用 humanidle/humantalking'),
      ],
    );
  }

  Widget _buildSentimentReportPanel() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _buildActionTile(
          icon: Icons.analytics_rounded,
          title: '生成感受度报告',
          desc: '基于历史问答记录生成综合报告',
          onTap: _generateSentimentReport,
        ),
      ],
    );
  }



  Widget _buildActionTile({
    required IconData icon,
    required String title,
    required String desc,
    required VoidCallback? onTap,
  }) {
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(16),
      child: Container(
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
                  Row(
                    children: [
                      Expanded(
                        child: Text(
                          title,
                          style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w700),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                      const SizedBox(width: 4),
                      Icon(Icons.chevron_right_rounded, color: Colors.grey.shade400, size: 18),
                    ],
                  ),
                  const SizedBox(height: 4),
                  Text(desc, style: TextStyle(fontSize: 12, color: Colors.grey.shade600, height: 1.35)),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildKnowledgeFileList() {
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: Colors.grey.shade200),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              const Text('已导入文档', style: TextStyle(fontSize: 15, fontWeight: FontWeight.w700)),
              const Spacer(),
              if (_isLoadingKnowledgeFiles)
                const SizedBox(
                  width: 16,
                  height: 16,
                  child: CircularProgressIndicator(strokeWidth: 2),
                ),
            ],
          ),
          const SizedBox(height: 12),
          if (_knowledgeFiles.isEmpty)
            Text('暂无已导入文档', style: TextStyle(color: Colors.grey.shade600))
          else
            ..._knowledgeFiles.map((file) {
              final name = file['name']?.toString() ?? '';
              final originalName = name.contains('_') ? name.split('_').skip(1).join('_') : name;
              return Container(
                margin: const EdgeInsets.only(bottom: 10),
                padding: const EdgeInsets.all(12),
                decoration: BoxDecoration(
                  color: const Color(0xFFF8FAFF),
                  borderRadius: BorderRadius.circular(14),
                  border: Border.all(color: const Color(0xFFE6ECFF)),
                ),
                child: Row(
                  children: [
                    const Icon(Icons.description_rounded, color: Color(0xFF667EEA)),
                    const SizedBox(width: 10),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(originalName, style: const TextStyle(fontWeight: FontWeight.w600)),
                          const SizedBox(height: 4),
                          Text(name, style: TextStyle(fontSize: 12, color: Colors.grey.shade600)),
                        ],
                      ),
                    ),
                    TextButton.icon(
                      onPressed: () => _deleteKnowledgeFile(name),
                      icon: const Icon(Icons.delete_outline, size: 18),
                      label: const Text('删除'),
                    ),
                  ],
                ),
              );
            }),
        ],
      ),
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
              key: ValueKey('avatar-webview-$_avatarViewNonce'),
              initialUrlRequest: URLRequest(url: WebUri(_avatarUrlForGuide(_selectedGuideType))),
              onLoadError: (controller, url, code, message) {
                debugPrint('数字人资源加载失败: $message');
              },
              onWebViewCreated: (controller) {
                debugPrint('🟢 WebView 创建完成');
                _webController = controller;
                if (!kIsWeb) {
                  controller.addJavaScriptHandler(
                    handlerName: 'avatarReady',
                    callback: (args) {
                      debugPrint('🟢 收到 avatarReady handler 回调');
                      _onAvatarReady();
                    },
                  );
                } else {
                  debugPrint('🌐 Web 平台跳过 addJavaScriptHandler，改用 iframe/postMessage');
                }
              },
              onLoadStop: (controller, url) async {
                debugPrint('✅ 数字人页面HTML加载完成: $url');
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
