import 'package:flutter/material.dart';
import 'digital_guide_page.dart';

void main() {
  runApp(const MyApp());
}

class MyApp extends StatelessWidget {
  const MyApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'AI 数字人导游',
      theme: ThemeData(primarySwatch: Colors.blue, useMaterial3: true),
      home: const DigitalGuidePage(),
    );
  }
}