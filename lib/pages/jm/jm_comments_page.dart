import 'package:flutter/material.dart';

class JmCommentsPage extends StatelessWidget {
  const JmCommentsPage({super.key});
  @override
  Widget build(BuildContext context) => const SizedBox();
}

void showComments(BuildContext context, String jmId, int commentsLength) {
  Navigator.of(context).push(
    MaterialPageRoute(
      builder: (context) => const JmCommentsPage(),
    ),
  );
}

