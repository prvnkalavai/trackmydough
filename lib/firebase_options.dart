// File generated by FlutterFire CLI.
// ignore_for_file: type=lint
import 'package:firebase_core/firebase_core.dart' show FirebaseOptions;
import 'package:flutter/foundation.dart'
    show defaultTargetPlatform, kIsWeb, TargetPlatform;

/// Default [FirebaseOptions] for use with your Firebase apps.
///
/// Example:
/// ```dart
/// import 'firebase_options.dart';
/// // ...
/// await Firebase.initializeApp(
///   options: DefaultFirebaseOptions.currentPlatform,
/// );
/// ```
class DefaultFirebaseOptions {
  static FirebaseOptions get currentPlatform {
    if (kIsWeb) {
      return web;
    }
    switch (defaultTargetPlatform) {
      case TargetPlatform.android:
        return android;
      case TargetPlatform.iOS:
        return ios;
      case TargetPlatform.macOS:
        return macos;
      case TargetPlatform.windows:
        return windows;
      case TargetPlatform.linux:
        throw UnsupportedError(
          'DefaultFirebaseOptions have not been configured for linux - '
          'you can reconfigure this by running the FlutterFire CLI again.',
        );
      default:
        throw UnsupportedError(
          'DefaultFirebaseOptions are not supported for this platform.',
        );
    }
  }

  static const FirebaseOptions web = FirebaseOptions(
    apiKey: 'AIzaSyBU-_E2qteQ7siv5tgAB3fENzLkWBf_plo',
    appId: '1:1026802612394:web:a11431ff0109048ffaf8d3',
    messagingSenderId: '1026802612394',
    projectId: 'trackmydough-293b6',
    authDomain: 'trackmydough-293b6.firebaseapp.com',
    storageBucket: 'trackmydough-293b6.firebasestorage.app',
    measurementId: 'G-PTV4BWGNQE',
  );

  static const FirebaseOptions android = FirebaseOptions(
    apiKey: 'AIzaSyAyTZ-oA2BFPWrtxI_yznaur-uIguRxRWE',
    appId: '1:1026802612394:android:7f3bfde28be22a9ffaf8d3',
    messagingSenderId: '1026802612394',
    projectId: 'trackmydough-293b6',
    storageBucket: 'trackmydough-293b6.firebasestorage.app',
  );

  static const FirebaseOptions ios = FirebaseOptions(
    apiKey: 'AIzaSyAHdu5OIB7J4gMGiHEo8jC10yi-H33GeWY',
    appId: '1:1026802612394:ios:acc3d1e1f9d2aad9faf8d3',
    messagingSenderId: '1026802612394',
    projectId: 'trackmydough-293b6',
    storageBucket: 'trackmydough-293b6.firebasestorage.app',
    iosBundleId: 'com.example.trackmydough',
  );

  static const FirebaseOptions macos = FirebaseOptions(
    apiKey: 'AIzaSyAHdu5OIB7J4gMGiHEo8jC10yi-H33GeWY',
    appId: '1:1026802612394:ios:acc3d1e1f9d2aad9faf8d3',
    messagingSenderId: '1026802612394',
    projectId: 'trackmydough-293b6',
    storageBucket: 'trackmydough-293b6.firebasestorage.app',
    iosBundleId: 'com.example.trackmydough',
  );

  static const FirebaseOptions windows = FirebaseOptions(
    apiKey: 'AIzaSyBU-_E2qteQ7siv5tgAB3fENzLkWBf_plo',
    appId: '1:1026802612394:web:acb238f184f4ae18faf8d3',
    messagingSenderId: '1026802612394',
    projectId: 'trackmydough-293b6',
    authDomain: 'trackmydough-293b6.firebaseapp.com',
    storageBucket: 'trackmydough-293b6.firebasestorage.app',
    measurementId: 'G-PSY5620T4M',
  );
}
