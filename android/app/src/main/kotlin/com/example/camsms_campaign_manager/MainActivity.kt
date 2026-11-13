package com.example.camsms_campaign_manager

import android.Manifest
import android.content.ContentResolver
import android.content.pm.PackageManager
import android.os.Build
import android.provider.ContactsContract
import android.security.KeyPairGeneratorSpec
import android.telephony.SmsManager
import android.telephony.SubscriptionManager
import android.util.Base64
import androidx.core.content.ContextCompat
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import java.math.BigInteger
import java.nio.charset.StandardCharsets
import java.security.KeyPairGenerator
import java.security.KeyStore
import java.security.SecureRandom
import java.util.Calendar
import javax.crypto.Cipher
import javax.crypto.spec.GCMParameterSpec
import javax.crypto.spec.SecretKeySpec
import javax.security.auth.x500.X500Principal

class MainActivity : FlutterActivity() {
    private val channelName = "com.example.camsms_campaign_manager/sms"
    private val gatewayTokenPreferences by lazy {
        getSharedPreferences("gateway_tokens", MODE_PRIVATE)
    }
    private val gatewayTokenKeyAlias = "com.example.camsms_campaign_manager.gateway_token_key"

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, channelName)
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "storeGatewayToken" -> {
                        val deviceId = call.argument<String>("deviceId")
                        val token = call.argument<String>("token")
                        if (deviceId.isNullOrBlank() || token.isNullOrBlank()) {
                            result.error("ARGUMENTS", "Identifiant appareil ou jeton manquant", null)
                            return@setMethodCallHandler
                        }
                        try {
                            gatewayTokenPreferences.edit()
                                .putString(deviceId, encryptGatewayToken(token))
                                .apply()
                            result.success(null)
                        } catch (e: Exception) {
                            result.error("TOKEN_STORAGE", e.message ?: "Impossible de protéger le jeton", null)
                        }
                    }
                    "readGatewayToken" -> {
                        val deviceId = call.argument<String>("deviceId")
                        if (deviceId.isNullOrBlank()) {
                            result.error("ARGUMENTS", "Identifiant appareil manquant", null)
                            return@setMethodCallHandler
                        }
                        try {
                            val encrypted = gatewayTokenPreferences.getString(deviceId, null)
                            result.success(encrypted?.let(::decryptGatewayToken))
                        } catch (e: Exception) {
                            result.error("TOKEN_STORAGE", e.message ?: "Impossible de lire le jeton protégé", null)
                        }
                    }
                    "deleteGatewayToken" -> {
                        val deviceId = call.argument<String>("deviceId")
                        if (deviceId.isNullOrBlank()) {
                            result.error("ARGUMENTS", "Identifiant appareil manquant", null)
                            return@setMethodCallHandler
                        }
                        gatewayTokenPreferences.edit().remove(deviceId).apply()
                        result.success(null)
                    }
                    "getPhoneContacts" -> {
                        if (ContextCompat.checkSelfPermission(this, Manifest.permission.READ_CONTACTS)
                            != PackageManager.PERMISSION_GRANTED) {
                            result.error("PERMISSION", "Permission READ_CONTACTS manquante", null)
                            return@setMethodCallHandler
                        }
                        try {
                            result.success(readPhoneContacts(contentResolver))
                        } catch (e: SecurityException) {
                            result.error("CONTACTS_ACCESS", e.message ?: "Accès au répertoire refusé", null)
                        } catch (e: Exception) {
                            result.error("CONTACTS_READ", e.message ?: "Impossible de lire le répertoire", null)
                        }
                    }
                    "getSims" -> {
                        if (ContextCompat.checkSelfPermission(this, Manifest.permission.READ_PHONE_STATE)
                            != PackageManager.PERMISSION_GRANTED) {
                            result.error("PERMISSION", "Permission READ_PHONE_STATE manquante", null)
                            return@setMethodCallHandler
                        }
                        try {
                            val manager = getSystemService(TELEPHONY_SUBSCRIPTION_SERVICE) as SubscriptionManager
                            val list = manager.activeSubscriptionInfoList ?: emptyList()
                            result.success(list.map { info ->
                                mapOf(
                                    "subscriptionId" to info.subscriptionId,
                                    "slotIndex" to info.simSlotIndex,
                                    "carrierName" to info.carrierName?.toString().orEmpty(),
                                    "displayName" to info.displayName?.toString().orEmpty()
                                )
                            })
                        } catch (e: SecurityException) {
                            result.error("SIM_ACCESS", e.message, null)
                        }
                    }
                    "sendSms" -> {
                        if (ContextCompat.checkSelfPermission(this, Manifest.permission.SEND_SMS)
                            != PackageManager.PERMISSION_GRANTED) {
                            result.error("PERMISSION", "Permission SEND_SMS manquante", null)
                            return@setMethodCallHandler
                        }
                        val subId = call.argument<Int>("subscriptionId")
                        val phone = call.argument<String>("phone")
                        val message = call.argument<String>("message")
                        if (subId == null || phone.isNullOrBlank() || message.isNullOrBlank()) {
                            result.error("ARGUMENTS", "Paramètres SMS invalides", null)
                            return@setMethodCallHandler
                        }
                        var normalizedPhone = phone.filter { it.isDigit() }
                        if (normalizedPhone.startsWith("00237")) {
                            normalizedPhone = normalizedPhone.removePrefix("00237")
                        } else if (normalizedPhone.startsWith("237")) {
                            normalizedPhone = normalizedPhone.removePrefix("237")
                        }
                        if (normalizedPhone.startsWith("000")) {
                            result.error(
                                "INVALID_PHONE",
                                "Les numéros fictifs réservés aux tests ne peuvent pas être envoyés",
                                null
                            )
                            return@setMethodCallHandler
                        }
                        try {
                            val manager = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) {
                                getSystemService(SmsManager::class.java).createForSubscriptionId(subId)
                            } else {
                                @Suppress("DEPRECATION")
                                SmsManager.getSmsManagerForSubscriptionId(subId)
                            }
                            val parts = manager.divideMessage(message)
                            if (parts.size > 1) manager.sendMultipartTextMessage(phone, null, parts, null, null)
                            else manager.sendTextMessage(phone, null, message, null, null)
                            result.success(true)
                        } catch (e: Exception) {
                            result.error("SEND_FAILED", e.message ?: "Échec d'envoi", null)
                        }
                    }
                    else -> result.notImplemented()
                }
            }
    }

    private fun readPhoneContacts(resolver: ContentResolver): List<Map<String, String>> {
            val contacts = mutableListOf<Map<String, String>>()
            val projection = arrayOf(
                ContactsContract.CommonDataKinds.Phone.DISPLAY_NAME,
                ContactsContract.CommonDataKinds.Phone.NUMBER
            )
            resolver.query(
                ContactsContract.CommonDataKinds.Phone.CONTENT_URI,
                projection,
                null,
                null,
                "${ContactsContract.CommonDataKinds.Phone.DISPLAY_NAME} COLLATE NOCASE ASC"
            )?.use { cursor ->
                val nameColumn = cursor.getColumnIndexOrThrow(ContactsContract.CommonDataKinds.Phone.DISPLAY_NAME)
                val phoneColumn = cursor.getColumnIndexOrThrow(ContactsContract.CommonDataKinds.Phone.NUMBER)
                while (cursor.moveToNext()) {
                    contacts.add(
                        mapOf(
                            "name" to cursor.getString(nameColumn).orEmpty(),
                            "phone" to cursor.getString(phoneColumn).orEmpty()
                        )
                    )
                }
            }
            return contacts
        }

    private fun encryptGatewayToken(token: String): String {
            val keyStore = getGatewayKeyStore()
            if (!keyStore.containsAlias(gatewayTokenKeyAlias)) {
                val start = Calendar.getInstance()
                val end = Calendar.getInstance().apply { add(Calendar.YEAR, 30) }
                val spec = KeyPairGeneratorSpec.Builder(this)
                    .setAlias(gatewayTokenKeyAlias)
                    .setSubject(X500Principal("CN=$gatewayTokenKeyAlias"))
                    .setSerialNumber(BigInteger.ONE)
                    .setStartDate(start.time)
                    .setEndDate(end.time)
                    .build()
                KeyPairGenerator.getInstance("RSA", "AndroidKeyStore").apply {
                    initialize(spec)
                }.generateKeyPair()
            }

            val aesKey = ByteArray(32).also { SecureRandom().nextBytes(it) }
            val iv = ByteArray(12).also { SecureRandom().nextBytes(it) }
            val aesCipher = Cipher.getInstance("AES/GCM/NoPadding").apply {
                init(Cipher.ENCRYPT_MODE, SecretKeySpec(aesKey, "AES"), GCMParameterSpec(128, iv))
            }
            val encryptedToken = aesCipher.doFinal(token.toByteArray(StandardCharsets.UTF_8))
            val rsaCipher = Cipher.getInstance("RSA/ECB/PKCS1Padding").apply {
                init(Cipher.ENCRYPT_MODE, keyStore.getCertificate(gatewayTokenKeyAlias).publicKey)
            }
            val wrappedKey = rsaCipher.doFinal(aesKey)
            return listOf(wrappedKey, iv, encryptedToken)
                .joinToString(".") { Base64.encodeToString(it, Base64.NO_WRAP) }
        }

    private fun decryptGatewayToken(encrypted: String): String {
            val parts = encrypted.split('.')
            require(parts.size == 3) { "Format de jeton protégé invalide" }
            val keyStore = getGatewayKeyStore()
            val privateKey = keyStore.getKey(gatewayTokenKeyAlias, null)
                ?: throw IllegalStateException("Clé de protection du jeton introuvable")
            val rsaCipher = Cipher.getInstance("RSA/ECB/PKCS1Padding").apply {
                init(Cipher.DECRYPT_MODE, privateKey)
            }
            val aesKey = rsaCipher.doFinal(Base64.decode(parts[0], Base64.NO_WRAP))
            val iv = Base64.decode(parts[1], Base64.NO_WRAP)
            val encryptedToken = Base64.decode(parts[2], Base64.NO_WRAP)
            val aesCipher = Cipher.getInstance("AES/GCM/NoPadding").apply {
                init(Cipher.DECRYPT_MODE, SecretKeySpec(aesKey, "AES"), GCMParameterSpec(128, iv))
            }
            return String(aesCipher.doFinal(encryptedToken), StandardCharsets.UTF_8)
        }

    private fun getGatewayKeyStore(): KeyStore =
        KeyStore.getInstance("AndroidKeyStore").apply { load(null) }
}
