import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../state/auth.dart';

// Google-branded sign-in button. Closely matches Google's own button
// guidelines: full-width pill, white surface with light border in light mode,
// dark surface in dark mode, the official 4-color "G" mark, and "Continue
// with Google" in Roboto-equivalent weight.
class GoogleSignInButton extends ConsumerStatefulWidget {
  const GoogleSignInButton({super.key});
  @override
  ConsumerState<GoogleSignInButton> createState() => _GoogleSignInButtonState();
}

class _GoogleSignInButtonState extends ConsumerState<GoogleSignInButton> {
  bool _busy = false;

  Future<void> _onTap() async {
    setState(() => _busy = true);
    try {
      await ref.read(authProvider.notifier).signInWithGoogle();
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(e.toString())),
        );
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final dark = Theme.of(context).brightness == Brightness.dark;
    final surface = dark ? const Color(0xFF131314) : Colors.white;
    final fg = dark ? const Color(0xFFE3E3E3) : const Color(0xFF1F1F1F);
    final borderColor = dark ? const Color(0xFF8E918F) : const Color(0xFFDADCE0);

    return SizedBox(
      width: double.infinity,
      height: 52,
      child: Material(
        color: surface,
        borderRadius: BorderRadius.circular(26),
        child: InkWell(
          borderRadius: BorderRadius.circular(26),
          onTap: _busy ? null : _onTap,
          child: Ink(
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(26),
              border: Border.all(color: borderColor),
            ),
            child: Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                if (_busy)
                  SizedBox(
                    width: 20,
                    height: 20,
                    child: CircularProgressIndicator(strokeWidth: 2.4, color: fg),
                  )
                else
                  const _GoogleGLogo(size: 20),
                const SizedBox(width: 12),
                Text(
                  'Continue with Google',
                  style: TextStyle(
                    color: fg,
                    fontSize: 15,
                    fontWeight: FontWeight.w500,
                    letterSpacing: 0.2,
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

// Official Google "G" mark, drawn via CustomPaint so we don't ship an asset.
// Path data taken from Google's brand kit (it's the same G everyone has
// reproduced for years — values normalized to a 48×48 viewBox below).
class _GoogleGLogo extends StatelessWidget {
  final double size;
  const _GoogleGLogo({this.size = 20});
  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: size,
      height: size,
      child: CustomPaint(painter: _GoogleGPainter()),
    );
  }
}

class _GoogleGPainter extends CustomPainter {
  static const _blue = Color(0xFF4285F4);
  static const _green = Color(0xFF34A853);
  static const _yellow = Color(0xFFFBBC05);
  static const _red = Color(0xFFEA4335);

  @override
  void paint(Canvas canvas, Size size) {
    // The path data below is for a 48×48 viewBox. Scale to whatever size the
    // widget was given.
    final s = size.width / 48.0;
    canvas.scale(s);

    // Blue — right side of G + crossbar.
    final blue = Path()
      ..moveTo(47.532, 24.5528)
      ..cubicTo(47.532, 22.9214, 47.3997, 21.2811, 47.1175, 19.6764)
      ..lineTo(24.48, 19.6764)
      ..lineTo(24.48, 28.9143)
      ..lineTo(37.4434, 28.9143)
      ..cubicTo(36.9055, 31.8961, 35.177, 34.5341, 32.6461, 36.2106)
      ..lineTo(32.6461, 42.2123)
      ..lineTo(40.3801, 42.2123)
      ..cubicTo(44.9217, 38.0324, 47.532, 31.8602, 47.532, 24.5528)
      ..close();
    canvas.drawPath(blue, Paint()..color = _blue);

    // Green — bottom-left curve.
    final green = Path()
      ..moveTo(24.48, 48)
      ..cubicTo(30.9529, 48, 36.4116, 45.8755, 40.3884, 42.2127)
      ..lineTo(32.6544, 36.2110)
      ..cubicTo(30.5023, 37.671, 27.7259, 38.5037, 24.4882, 38.5037)
      ..cubicTo(18.2275, 38.5037, 12.9173, 34.2818, 11.0149, 28.6006)
      ..lineTo(3.03296, 28.6006)
      ..lineTo(3.03296, 34.7866)
      ..cubicTo(7.10718, 42.8748, 15.4054, 48, 24.48, 48)
      ..close();
    canvas.drawPath(green, Paint()..color = _green);

    // Yellow — left vertical band.
    final yellow = Path()
      ..moveTo(11.0067, 28.6004)
      ..cubicTo(10.0036, 25.6186, 10.0036, 22.3914, 11.0067, 19.4096)
      ..lineTo(11.0067, 13.2236)
      ..lineTo(3.03298, 13.2236)
      ..cubicTo(-0.371021, 20.0028, -0.371021, 28.0072, 3.03298, 34.7866)
      ..lineTo(11.0067, 28.6004)
      ..close();
    canvas.drawPath(yellow, Paint()..color = _yellow);

    // Red — top arc.
    final red = Path()
      ..moveTo(24.48, 9.49932)
      ..cubicTo(27.9026, 9.44641, 31.2102, 10.7335, 33.6883, 13.0973)
      ..lineTo(40.5328, 6.25287)
      ..cubicTo(36.2, 2.18373, 30.4435, -0.0530585, 24.48, 0.000847)
      ..cubicTo(15.4054, 0.000847, 7.10718, 5.12604, 3.03296, 13.2236)
      ..lineTo(11.0067, 19.4099)
      ..cubicTo(12.9, 13.7197, 18.2275, 9.49932, 24.48, 9.49932)
      ..close();
    canvas.drawPath(red, Paint()..color = _red);
  }

  @override
  bool shouldRepaint(covariant CustomPainter old) => false;
}
