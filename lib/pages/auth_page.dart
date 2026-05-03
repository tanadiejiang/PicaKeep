import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';
import 'package:local_auth/local_auth.dart';
import 'package:picakeep/foundation/app.dart';
import 'package:picakeep/pages/main_page.dart';
import 'package:picakeep/tools/translations.dart';

class AuthPage extends StatefulWidget {
  const AuthPage({super.key});

  static bool lock = false;
  static bool initial = true;

  @override
  State<AuthPage> createState() => _AuthPageState();
}

class _AuthPageState extends State<AuthPage> with WidgetsBindingObserver {
  bool inProgress = false;

  @override
  void initState() {
    super.initState();
    AuthPage.lock = true;
    WidgetsBinding.instance.addObserver(this);
    if (SchedulerBinding.instance.lifecycleState == AppLifecycleState.resumed) {
      auth();
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    super.didChangeAppLifecycleState(state);
    if (state == AppLifecycleState.resumed &&
        AuthPage.lock &&
        mounted &&
        !inProgress) {
      auth();
    }
  }

  Future<void> auth() async {
    if (inProgress) {
      return;
    }
    inProgress = true;
    bool success = false;
    try {
      success = await LocalAuthentication().authenticate(
        localizedReason: '需要身份验证'.tl,
      );
    } catch (_) {
      success = false;
    }
    inProgress = false;

    if (!mounted || !success) {
      return;
    }

    AuthPage.lock = false;
    if (AuthPage.initial) {
      AuthPage.initial = false;
      App.offAll(() => const MainPage());
    } else {
      App.globalBack();
    }
  }

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: auth,
      child: Scaffold(
        body: PopScope(
          canPop: false,
          child: Center(
            child: SizedBox(
              height: 100,
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Icon(
                    Icons.security,
                    size: 40,
                    color: context.colorScheme.secondary,
                  ),
                  const SizedBox(height: 8),
                  Text('点击完成身份验证'.tl),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}