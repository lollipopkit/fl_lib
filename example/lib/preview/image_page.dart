import 'package:flutter/material.dart';
import 'package:fl_lib/fl_lib.dart';

class PreviewImagePage extends StatelessWidget {
  const PreviewImagePage({super.key});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: CustomAppBar(title: const Text('ImagePage Preview')),
      body: Center(
        child: ImageCard(imageUrl: 'https://cdn.lollipopkit.com/logo.png'),
      ),
    );
  }
}
