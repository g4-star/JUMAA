import 'dart:io';

import 'package:firebase_messaging/firebase_messaging.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

class NotificationService {
  NotificationService._();

  static final NotificationService instance = NotificationService._();

  final FirebaseMessaging _messaging = FirebaseMessaging.instance;
  final SupabaseClient _supabase = Supabase.instance.client;
  final FlutterLocalNotificationsPlugin _localNotifications =
      FlutterLocalNotificationsPlugin();

  static const AndroidNotificationChannel _channel = AndroidNotificationChannel(
    'jumaa_general',
    'JUMAA notifications',
    description: 'Messages and important JUMAA account updates',
    importance: Importance.max,
  );

  bool _initialized = false;

  Future<void> initialize() async {
    if (_initialized) return;
    try {
      const initializationSettings = InitializationSettings(
        android: AndroidInitializationSettings('@mipmap/ic_launcher'),
        iOS: DarwinInitializationSettings(
          requestAlertPermission: false,
          requestBadgePermission: false,
          requestSoundPermission: false,
        ),
      );

      await _localNotifications.initialize(
        settings: initializationSettings,
        onDidReceiveNotificationResponse: (response) {
          debugPrint('JUMAA local notification tapped: ${response.payload}');
        },
      );

      await _localNotifications
          .resolvePlatformSpecificImplementation<
              AndroidFlutterLocalNotificationsPlugin>()
          ?.createNotificationChannel(_channel);

      await _messaging.setForegroundNotificationPresentationOptions(
        alert: true,
        badge: true,
        sound: true,
      );

      FirebaseMessaging.onMessage.listen(_showForegroundNotification);
      FirebaseMessaging.onMessageOpenedApp.listen((message) {
        debugPrint('JUMAA push opened: ${message.data}');
      });

      final initialMessage = await _messaging.getInitialMessage();
      if (initialMessage != null) {
        debugPrint('JUMAA opened from push: ${initialMessage.data}');
      }

      _messaging.onTokenRefresh.listen((token) async {
        if (_supabase.auth.currentUser != null) {
          await _saveToken(token);
        }
      });

      _initialized = true;
    } catch (e) {
      debugPrint('Notification initialization failed: $e');
    }
  }

  Future<void> _showForegroundNotification(RemoteMessage message) async {
    // iOS foreground presentation is handled by Firebase's native presentation
    // options above. Android needs a local notification while the app is open.
    if (kIsWeb || Platform.isIOS) return;

    final notification = message.notification;
    if (notification == null) return;

    try {
      await _localNotifications.show(
        id: message.messageId?.hashCode ?? DateTime.now().millisecondsSinceEpoch,
        title: notification.title ?? 'JUMAA',
        body: notification.body ?? 'You have a new update.',
        notificationDetails: const NotificationDetails(
          android: AndroidNotificationDetails(
            'jumaa_general',
            'JUMAA notifications',
            channelDescription: 'Messages and important JUMAA account updates',
            importance: Importance.max,
            priority: Priority.high,
            playSound: true,
          ),
          iOS: DarwinNotificationDetails(
            presentAlert: true,
            presentBadge: true,
            presentSound: true,
          ),
        ),
        payload: message.data.toString(),
      );
    } catch (e) {
      debugPrint('Could not display foreground notification: $e');
    }
  }

  Future<AuthorizationStatus> requestPermission() async {
    try {
      final settings = await _messaging.requestPermission(
        alert: true,
        badge: true,
        sound: true,
        provisional: false,
      );
      debugPrint('FCM permission status: ${settings.authorizationStatus}');
      return settings.authorizationStatus;
    } catch (e) {
      debugPrint('Notification permission request failed: $e');
      return AuthorizationStatus.denied;
    }
  }

  Future<void> registerCurrentDevice() async {
    try {
      final user = _supabase.auth.currentUser;
      if (user == null) {
        debugPrint('FCM registration skipped: no authenticated user.');
        return;
      }

      final status = await requestPermission();
      if (status != AuthorizationStatus.authorized &&
          status != AuthorizationStatus.provisional) {
        debugPrint('FCM registration skipped: notification permission not granted.');
        return;
      }

      final token = await _messaging.getToken();
      if (token == null || token.isEmpty) {
        debugPrint('FCM token unavailable.');
        return;
      }

      await _saveToken(token);
      debugPrint('FCM device token registered for ${user.id}.');
    } catch (e) {
      debugPrint('Failed to register FCM device: $e');
    }
  }

  Future<void> _saveToken(String token) async {
    final user = _supabase.auth.currentUser;
    if (user == null) return;

    final platform = kIsWeb
        ? 'web'
        : Platform.isIOS
            ? 'ios'
            : 'android';

    final response = await _supabase.functions.invoke(
      'register-push-token',
      body: {'token': token, 'platform': platform},
    );

    if (response.status < 200 || response.status >= 300) {
      throw Exception('Push token registration failed: ${response.status}');
    }
  }

  /// Requests a server-side push for a message already saved in Supabase.
  /// A push failure must never turn a successfully saved message into a failed send.
  Future<void> notifyMessageRecipient(String messageId) async {
    if (messageId.trim().isEmpty || _supabase.auth.currentSession == null) {
      return;
    }
    try {
      final response = await _supabase.functions.invoke(
        'send-jumaa-notification',
        body: {'message_id': messageId},
      );
      if (response.status < 200 || response.status >= 300) {
        debugPrint('Message push request returned ${response.status}.');
      }
    } catch (e) {
      debugPrint('Message push request failed (message remains sent): $e');
    }
  }

  Future<void> removeCurrentDevice() async {
    try {
      final user = _supabase.auth.currentUser;
      if (user == null) return;

      final token = await _messaging.getToken();
      if (token == null || token.isEmpty) return;

      await _supabase
          .from('push_tokens')
          .delete()
          .eq('user_id', user.id)
          .eq('token', token);

      await _messaging.deleteToken();
      debugPrint('FCM device token removed.');
    } catch (e) {
      debugPrint('Failed to remove FCM device token: $e');
    }
  }
}
