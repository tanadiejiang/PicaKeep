import 'package:flutter/material.dart';
import 'package:dynamic_color/dynamic_color.dart';
import 'foundation/app.dart';
import 'base.dart';
import 'pages/main_page.dart';

void main() async {
  WidgetsFlutterBinding.ensureInitialized();

  await App.init();
  await appdata.readData();

  runApp(const PicaKeepApp());
}

class PicaKeepApp extends StatelessWidget {
  const PicaKeepApp({super.key});

  @override
  Widget build(BuildContext context) {
    return DynamicColorBuilder(
      builder: (ColorScheme? lightDynamic, ColorScheme? darkDynamic) {
        return MaterialApp(
          title: 'PicaKeep',
          navigatorKey: App.navigatorKey,
          debugShowCheckedModeBanner: false,
          theme: ThemeData(
            colorScheme:
                lightDynamic ?? ColorScheme.fromSeed(seedColor: Colors.blue),
            useMaterial3: true,
          ),
          darkTheme: ThemeData(
            colorScheme: darkDynamic ??
                ColorScheme.fromSeed(
                    seedColor: Colors.blue, brightness: Brightness.dark),
            useMaterial3: true,
          ),
          themeMode: ThemeMode.system,
          onGenerateRoute: (settings) {
            return MaterialPageRoute(
              builder: (context) {
                App.mainNavigatorKey = GlobalKey<NavigatorState>();
                return const MainPage();
              },
            );
          },
        );
      },
    );
  }
}
