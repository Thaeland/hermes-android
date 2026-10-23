package com.hermesagent.hermes_android

import android.app.NotificationManager
import android.content.Context
import org.json.JSONArray
import org.json.JSONObject
import org.junit.Assert.*
import org.junit.Before
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.Robolectric
import org.robolectric.RobolectricTestRunner
import org.robolectric.RuntimeEnvironment
import org.robolectric.annotation.Config
import org.unifiedpush.android.connector.data.PushEndpoint
import org.unifiedpush.android.connector.data.PushMessage
import org.unifiedpush.android.connector.data.PublicKeySet
import javax.crypto.KeyGenerator

/** JVM evidence of native/headless policy, persistence and encryption envelope.
 * AndroidKeystore acquisition itself and real distributor delivery require a
 * physical device. The connector's decrypted boolean is deliberately controlled. */
@RunWith(RobolectricTestRunner::class)
@Config(sdk = [28])
class MobilePushReceiverTest {
    private lateinit var context: Context
    private lateinit var manager: NotificationManager
    private val expiry get() = System.currentTimeMillis() / 1000 + 3600
    @Before fun setup() {
        context = RuntimeEnvironment.getApplication()
        val key = KeyGenerator.getInstance("AES").apply { init(256) }.generateKey()
        MobilePushStore.keyProvider = { key }
        manager = context.getSystemService(NotificationManager::class.java)
        context.getSharedPreferences("mobile_push_sealed", Context.MODE_PRIVATE).edit().clear().commit()
        manager.cancelAll()
        MobilePushBridge.detach() // no attached Flutter engine or Activity
        save()
    }
    private fun save(active: Boolean = true) {
        MobilePushStore.write(context, JSONObject().put("enabled", true).put("active", active)
            .put("installation", "i").put("nonce", "private-nonce").put("revision", 2)
            .put("generation", if (active) 3 else 0).put("connection", "c").put("master", true)
            .put("sessions", JSONArray(listOf("durable-session"))).put("kinds", JSONArray(listOf("turn_done")))
            .put("endpoint", "https://distributor.invalid/private-endpoint")
            .put("keys", JSONObject().put("p256dh", "fixture-public").put("auth", "private-auth-secret")))
    }
    private fun payload(kind: String = "turn_done", generation: Int = 3) = JSONObject()
        .put("schema", 1).put("event_id", "event").put("kind", kind).put("generation", generation)
        .put("registration_nonce", "private-nonce").put("expires_at", expiry)
    private fun deliver(hint: JSONObject = payload(), decrypted: Boolean = true) {
        val service = Robolectric.buildService(MobilePushService::class.java).create().get()
        service.onMessage(PushMessage(hint.toString().toByteArray(), decrypted), "i")
        service.onDestroy()
    }
    @Test fun headlessGenericNotificationAndDurableDedupAcrossServiceRecreation() {
        deliver()
        assertEquals(1, manager.activeNotifications.size)
        val notification = manager.activeNotifications.single().notification
        assertEquals("Hermes", notification.extras.getString("android.title"))
        assertEquals("Server activity is available. Open Hermes to check.", notification.extras.getString("android.text"))
        assertEquals(1, MobilePushStore.read(context).getJSONArray("seen").length())
        deliver() // a new Service object, no cached authority
        assertEquals(1, manager.activeNotifications.size)
        assertEquals(1, MobilePushStore.read(context).getJSONArray("seen").length())
    }
    @Test fun plaintextNeverPostsEvenWhenJsonLooksValid() {
        deliver(decrypted = false)
        assertEquals(0, manager.activeNotifications.size)
        assertFalse(MobilePushStore.read(context).has("seen"))
    }
    @Test fun envelopeContainsNoRawEndpointAuthNonceOrChallenge() {
        save(active = false)
        deliver(payload("challenge").put("challenge", "private-challenge"))
        val raw = context.getSharedPreferences("mobile_push_sealed", Context.MODE_PRIVATE).all.toString()
        listOf("private-endpoint", "private-auth-secret", "private-nonce", "private-challenge", "durable-session").forEach { assertFalse(raw.contains(it)) }
        assertEquals("private-challenge", MobilePushStore.read(context).getJSONArray("challenges").getJSONObject(0).getString("challenge"))
        assertEquals(0, manager.activeNotifications.size)
    }
    @Test fun disableClearsChallengesAndAllLocalAuthorityBeforeNetwork() {
        save(active = false); deliver(payload("challenge").put("challenge", "proof"))
        MobilePushBridge.command(context, "disable", emptyMap<Any, Any>())
        val state = MobilePushStore.read(context)
        assertFalse(state.getBoolean("enabled")); assertFalse(state.has("challenges"))
        assertFalse(state.has("keys")); assertFalse(state.has("endpoint"))
        deliver(); assertEquals(0, manager.activeNotifications.size)
    }
    @Test fun nativePreferencesImmediatelySuppressAndCancel() {
        deliver(); assertEquals(1, manager.activeNotifications.size)
        MobilePushBridge.command(context, "preferences", mapOf("master" to false, "kinds" to emptyList<String>()))
        assertEquals(0, manager.activeNotifications.size)
        deliver(payload().put("event_id", "second")); assertEquals(0, manager.activeNotifications.size)
    }
    @Test fun renewalInvalidatesOldGenerationBeforeForegroundHttp() {
        deliver()
        MobilePushBridge.endpoint(context, PushEndpoint("https://new.invalid/endpoint", PublicKeySet("new-public", "new-auth"), false), "i")
        val state = MobilePushStore.read(context)
        assertFalse(state.getBoolean("active")); assertEquals(0L, state.getLong("generation"))
        assertNotEquals("private-nonce", state.getString("nonce"))
        assertEquals(0, manager.activeNotifications.size)
        deliver(); assertEquals(0, manager.activeNotifications.size)
    }
    @Test fun editingOtherConnectionDoesNotRevokeButBoundConnectionDoes() {
        MobilePushBridge.command(context, "connectionChanged", mapOf("connection" to "other"))
        assertTrue(MobilePushStore.read(context).getBoolean("enabled"))
        MobilePushBridge.command(context, "connectionChanged", mapOf("connection" to "c"))
        assertFalse(MobilePushStore.read(context).getBoolean("enabled"))
        deliver(); assertEquals(0, manager.activeNotifications.size)
    }
    @Test fun dedupIsBoundedAndCiphertextTamperingFailsClosed() {
        for (i in 0..260) deliver(payload().put("event_id", "event-$i"))
        assertEquals(256, MobilePushStore.read(context).getJSONArray("seen").length())
        assertEquals(256, MobilePushStore.read(context).getJSONArray("issued").length())
        context.getSharedPreferences("mobile_push_sealed", Context.MODE_PRIVATE).edit().putString("state", "tampered").commit()
        val before = manager.activeNotifications.size
        deliver(payload().put("event_id", "after-corruption"))
        assertEquals(before, manager.activeNotifications.size)
    }
}
