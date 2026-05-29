import Flutter
import UIKit
import UserNotifications

@main
@objc class AppDelegate: FlutterAppDelegate {
  override func application(
    _ application: UIApplication,
    didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?
  ) -> Bool {
    // Register plugins eagerly so firebase_messaging's APNs swizzling is
    // installed BEFORE iOS delivers the APNs device token. With the implicit
    // engine pattern, plugin registration happens after the first engine init,
    // which can race the system's didRegisterForRemoteNotificationsWithDeviceToken
    // callback — Firebase then never sees the token and getAPNSToken() returns nil.
    GeneratedPluginRegistrant.register(with: self)

    // Belt-and-braces: if permission was previously granted, force a fresh
    // remote-notification registration this launch. Firebase usually does
    // this automatically once requestPermission grants, but we've seen it
    // miss on first install.
    UNUserNotificationCenter.current().getNotificationSettings { settings in
      if settings.authorizationStatus == .authorized || settings.authorizationStatus == .provisional {
        DispatchQueue.main.async {
          application.registerForRemoteNotifications()
        }
      }
    }

    return super.application(application, didFinishLaunchingWithOptions: launchOptions)
  }
}
