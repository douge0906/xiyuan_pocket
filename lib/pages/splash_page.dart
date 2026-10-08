import 'package:flutter/material.dart';
import '../app.dart';
import '../theme/app_theme.dart';

class SplashPage extends StatefulWidget {
  const SplashPage({super.key});

  @override
  State<SplashPage> createState() => _SplashPageState();
}

class _SplashPageState extends State<SplashPage>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller;
  late final Animation<double> _scaleAnimation;
  late final Animation<double> _fadeAnimation;
  late final Animation<double> _rotateAnimation;

  @override
  void initState() {
    super.initState();
    _controller = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 1800),
    );

    _scaleAnimation = TweenSequence<double>([
      TweenSequenceItem(tween: Tween(begin: 0.0, end: 1.15), weight: 55),
      TweenSequenceItem(tween: Tween(begin: 1.15, end: 1.0), weight: 25),
      TweenSequenceItem(tween: Tween(begin: 1.0, end: 1.0), weight: 20),
    ]).animate(CurvedAnimation(
      parent: _controller,
      curve: Curves.easeOutCubic,
    ));

    _fadeAnimation = Tween<double>(begin: 0.0, end: 1.0).animate(
      CurvedAnimation(
        parent: _controller,
        curve: const Interval(0.0, 0.6, curve: Curves.easeIn),
      ),
    );

    _rotateAnimation = Tween<double>(begin: -0.15, end: 0.0).animate(
      CurvedAnimation(
        parent: _controller,
        curve: const Interval(0.0, 0.6, curve: Curves.easeOutCubic),
      ),
    );

    _controller.forward();
    _navigateToHome();
  }

  void _navigateToHome() async {
    // 启动等待 400ms（原 900ms）：浅色原生背景→浅色 splash 无缝衔接，
    // 无黑屏/黑闪，动画仍完整展示 Logo。v2.2.14
    await Future.delayed(const Duration(milliseconds: 400));
    if (!mounted) return;
    Navigator.of(context).pushReplacement(
      PageRouteBuilder(
        pageBuilder: (context, animation, secondaryAnimation) => const MainApp(),
        transitionsBuilder: (context, animation, secondaryAnimation, child) {
          return FadeTransition(opacity: animation, child: child);
        },
        transitionDuration: const Duration(milliseconds: 400),
      ),
    );
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    // v2.2.14：浅色品牌启动页（原生启动背景 #F8F9FC 无缝衔接，无黑屏黑闪）。
    return Scaffold(
      body: Container(
        decoration: const BoxDecoration(
          color: Color(0xFFF8F9FC),
        ),
        child: Center(
          child: AnimatedBuilder(
            animation: _controller,
            builder: (context, child) {
              return Opacity(
                opacity: _fadeAnimation.value,
                child: Transform.scale(
                  scale: _scaleAnimation.value,
                  child: Transform.rotate(
                    angle: _rotateAnimation.value,
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Container(
                          width: 120,
                          height: 120,
                          decoration: BoxDecoration(
                            color: AppTheme.textPrimaryLight,
                            shape: BoxShape.circle,
                            boxShadow: [
                              BoxShadow(
                                color: Colors.black.withOpacity(0.12),
                                blurRadius: 30,
                                offset: const Offset(0, 12),
                              ),
                            ],
                          ),
                          child: const Icon(
                            Icons.school_rounded,
                            size: 64,
                            color: Colors.white,
                          ),
                        ),
                        const SizedBox(height: 28),
                        const Text(
                          '掌上锡院',
                          style: TextStyle(
                            fontSize: 32,
                            fontWeight: FontWeight.bold,
                            color: AppTheme.textPrimaryLight,
                            letterSpacing: 2,
                          ),
                        ),
                        const SizedBox(height: 12),
                        Text(
                          'Wuxi University Toolbox',
                          style: TextStyle(
                            fontSize: 14,
                            color: AppTheme.primaryColor.withOpacity(0.55),
                            letterSpacing: 1,
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              );
            },
          ),
        ),
      ),
    );
  }
}
