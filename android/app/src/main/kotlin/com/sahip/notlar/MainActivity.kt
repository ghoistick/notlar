package com.sahip.notlar

import android.os.Handler
import android.os.Looper
import io.flutter.embedding.android.FlutterFragmentActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import net.lingala.zip4j.ZipFile
import net.lingala.zip4j.exception.ZipException
import net.lingala.zip4j.model.ZipParameters
import net.lingala.zip4j.model.enums.AesKeyStrength
import net.lingala.zip4j.model.enums.CompressionMethod
import net.lingala.zip4j.model.enums.EncryptionMethod
import java.io.File
import java.util.concurrent.Executors

class MainActivity : FlutterFragmentActivity() {
    private val worker = Executors.newSingleThreadExecutor()
    private val mainHandler = Handler(Looper.getMainLooper())

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)

        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "musvedde/zip")
            .setMethodCallHandler { call, result ->
                val args = call.arguments as? Map<*, *>
                // Zip işlemi ana iş parçacığını bloklamasın.
                worker.execute {
                    try {
                        when (call.method) {
                            "create" -> createZip(args!!)
                            "extract" -> extractZip(args!!)
                            else -> {
                                mainHandler.post { result.notImplemented() }
                                return@execute
                            }
                        }
                        mainHandler.post { result.success(null) }
                    } catch (e: ZipException) {
                        val code = if (e.type == ZipException.Type.WRONG_PASSWORD)
                            "WRONG_PASSWORD" else "ZIP_ERROR"
                        mainHandler.post { result.error(code, e.message, null) }
                    } catch (e: Exception) {
                        mainHandler.post { result.error("ERROR", e.message, null) }
                    }
                }
            }
    }

    /// source dosyasını AES-256 ile şifreli tek dosyalı ZIP'e yazar.
    private fun createZip(a: Map<*, *>) {
        val source = File(a["source"] as String)
        val archive = File(a["archive"] as String)
        val innerName = a["innerName"] as String
        val password = (a["password"] as String).toCharArray()

        if (archive.exists()) archive.delete()

        val params = ZipParameters().apply {
            isEncryptFiles = true
            encryptionMethod = EncryptionMethod.AES
            aesKeyStrength = AesKeyStrength.KEY_STRENGTH_256
            compressionMethod = CompressionMethod.DEFLATE
            fileNameInZip = innerName
        }
        ZipFile(archive, password).addFile(source, params)
    }

    /// ZIP içindeki innerName dosyasını dest yoluna çıkarır.
    private fun extractZip(a: Map<*, *>) {
        val archive = File(a["archive"] as String)
        val innerName = a["innerName"] as String
        val dest = File(a["dest"] as String)
        val password = (a["password"] as String).toCharArray()

        ZipFile(archive, password).extractFile(innerName, dest.parent, dest.name)
    }
}
