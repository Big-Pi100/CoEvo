package com.coevo.coevo_app

import android.Manifest
import android.content.pm.PackageManager
import android.media.MediaRecorder
import android.os.Build
import androidx.core.app.ActivityCompat
import androidx.core.content.ContextCompat
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import java.io.File

class MainActivity : FlutterActivity() {
    private val CHANNEL = "coevo/audio_recorder"
    private val RECORD_REQUEST_CODE = 1001
    private var recorder: MediaRecorder? = null
    private var pendingResult: MethodChannel.Result? = null
    private var pendingPath: String = ""

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, CHANNEL).setMethodCallHandler { call, result ->
            when (call.method) {
                "hasPermission" -> {
                    val granted = ContextCompat.checkSelfPermission(this, Manifest.permission.RECORD_AUDIO)
                    result.success(granted == PackageManager.PERMISSION_GRANTED)
                }
                "requestPermission" -> {
                    pendingResult = result
                    ActivityCompat.requestPermissions(this, arrayOf(Manifest.permission.RECORD_AUDIO), RECORD_REQUEST_CODE)
                }
                "startRecording" -> {
                    val path = call.argument<String>("path") ?: ""
                    if (ContextCompat.checkSelfPermission(this, Manifest.permission.RECORD_AUDIO) != PackageManager.PERMISSION_GRANTED) {
                        result.error("noPermission", "需要麦克风权限", null)
                        return@setMethodCallHandler
                    }
                    try {
                        recorder = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) {
                            MediaRecorder(applicationContext)
                        } else {
                            MediaRecorder()
                        }
                        recorder?.apply {
                            setAudioSource(MediaRecorder.AudioSource.MIC)
                            setOutputFormat(MediaRecorder.OutputFormat.MPEG_4)
                            setAudioEncoder(MediaRecorder.AudioEncoder.AAC)
                            setAudioSamplingRate(16000)
                            setAudioChannels(1)
                            setAudioEncodingBitRate(64000)
                            setOutputFile(File(path).absolutePath)
                            prepare()
                            start()
                        }
                        result.success(true)
                    } catch (e: Exception) {
                        recorder?.release()
                        recorder = null
                        result.error("startFailed", e.message, null)
                    }
                }
                "stopRecording" -> {
                    try {
                        recorder?.apply {
                            stop()
                            release()
                        }
                        recorder = null
                        result.success(true)
                    } catch (e: Exception) {
                        recorder?.release()
                        recorder = null
                        result.error("stopFailed", e.message, null)
                    }
                }
                else -> result.notImplemented()
            }
        }
    }

    override fun onRequestPermissionsResult(requestCode: Int, permissions: Array<String>, grantResults: IntArray) {
        super.onRequestPermissionsResult(requestCode, permissions, grantResults)
        if (requestCode == RECORD_REQUEST_CODE) {
            val granted = grantResults.isNotEmpty() && grantResults[0] == PackageManager.PERMISSION_GRANTED
            pendingResult?.success(granted)
            pendingResult = null
        }
    }
}
