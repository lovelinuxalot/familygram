package cc.lovelinuxalot.familygram

import android.os.Bundle
import android.view.WindowManager
import io.flutter.embedding.android.FlutterActivity

class MainActivity : FlutterActivity() {
    // FLAG_SECURE blocks screenshots and screen recording, and blanks the app
    // in the recents switcher. Android-only — iOS has no equivalent API, so
    // photos are never protected there. A second camera defeats both.
    override fun onCreate(savedInstanceState: Bundle?) {
        window.setFlags(
            WindowManager.LayoutParams.FLAG_SECURE,
            WindowManager.LayoutParams.FLAG_SECURE,
        )
        super.onCreate(savedInstanceState)
    }
}
