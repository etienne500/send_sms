import 'dart:async';

import 'package:flutter/services.dart';
import 'models.dart';

class SmsBridge {
  static const _channel =
      MethodChannel('com.example.camsms_campaign_manager/sms');
  static final Map<int, Future<void>> _sendTails = {};

  static Future<void> storeGatewayToken(String deviceId, String token) async {
    await _channel.invokeMethod<void>('storeGatewayToken', {
      'deviceId': deviceId,
      'token': token,
    });
  }

  static Future<String?> readGatewayToken(String deviceId) async =>
      _channel.invokeMethod<String>('readGatewayToken', {'deviceId': deviceId});

  static Future<void> deleteGatewayToken(String deviceId) async {
    await _channel
        .invokeMethod<void>('deleteGatewayToken', {'deviceId': deviceId});
  }

  static Future<List<SimCard>> getSims() async {
    final raw = await _channel.invokeMethod<List<dynamic>>('getSims');
    return (raw ?? [])
        .map((e) => SimCard.fromMap(Map<dynamic, dynamic>.from(e as Map)))
        .toList();
  }

  static Future<List<ContactDraft>> getPhoneContacts() async {
    final raw = await _channel.invokeMethod<List<dynamic>>('getPhoneContacts');
    return (raw ?? []).map((entry) {
      final contact = Map<dynamic, dynamic>.from(entry as Map);
      return ContactDraft(
        contact['name']?.toString() ?? '',
        contact['phone']?.toString() ?? '',
      );
    }).toList();
  }

  static Future<void> sendSms(
      int subscriptionId, String phone, String message) async {
    if (normalizeCameroonPhone(phone).isEmpty) {
      throw const FormatException(
          'Numéro invalide ou réservé aux tests; aucun SMS envoyé.');
    }
    final previous = _sendTails[subscriptionId] ?? Future<void>.value();
    final completer = Completer<void>();
    final tail = completer.future;
    _sendTails[subscriptionId] = tail;
    await previous;
    try {
      await _channel.invokeMethod('sendSms', {
        'subscriptionId': subscriptionId,
        'phone': phone,
        'message': message,
      });
    } finally {
      completer.complete();
      if (identical(_sendTails[subscriptionId], tail)) {
        _sendTails.remove(subscriptionId);
      }
    }
  }
}
