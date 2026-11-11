package com.kuncarlos91.mailburrow

import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import android.app.Activity
import android.content.Intent
import android.content.ClipData
import android.content.ActivityNotFoundException
import android.net.Uri
import java.io.File

class MainActivity : FlutterActivity() {
    private var pendingSave: MethodChannel.Result? = null
    private var pendingSource: File? = null
    private var pendingMimeType: String? = null
    private var pendingLocate: MethodChannel.Result? = null
    private val savedUris = mutableMapOf<String, Int>()
    private val savedTypes = SavedAttachmentTypes()
    private val retainedReadUris = mutableSetOf<Uri>()
    private var diagnosticsEnabled = false

    // Diagnostic builds opt in; events are fixed categories, never user values.
    private fun trace(event: String) {
        if (diagnosticsEnabled) android.util.Log.i("MailShelfFiles", event)
    }

    // Keep only the read grant needed to reopen a user-selected document.
    // Never persist write access or ask for broad storage/media permissions.
    private fun retainReadAccess(uri: Uri, resultFlags: Int) {
        if (resultFlags and Intent.FLAG_GRANT_READ_URI_PERMISSION == 0 ||
            resultFlags and Intent.FLAG_GRANT_PERSISTABLE_URI_PERMISSION == 0) {
            trace("grant_not_persistable")
            return
        }
        try {
            if (contentResolver.persistedUriPermissions.any { it.uri == uri && it.isReadPermission }) {
                trace("grant_already_retained")
                return
            }
            contentResolver.takePersistableUriPermission(uri, Intent.FLAG_GRANT_READ_URI_PERMISSION)
            retainedReadUris.add(uri)
            trace("grant_read_retained")
        } catch (_: SecurityException) {
            trace("grant_retention_denied")
            // Some document providers support temporary access only.
        }
    }

    private fun releaseSavedUri(location: String) {
        val references = savedUris[location] ?: return
        if (references > 1) {
            savedUris[location] = references - 1
            return
        }
        savedUris.remove(location)
        savedTypes.forget(location)
        releaseRetainedRead(Uri.parse(location))
    }

    private fun releaseRetainedRead(uri: Uri) {
        if (!retainedReadUris.remove(uri)) return
        try {
            contentResolver.releasePersistableUriPermission(uri, Intent.FLAG_GRANT_READ_URI_PERMISSION)
        } catch (_: SecurityException) {
            // The provider may already have revoked access. Never delete the file.
        }
    }

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "mailshelf/saved_files").setMethodCallHandler { call, result ->
            if (call.argument<Boolean>("diagnostics") == true) diagnosticsEnabled = true
            when (call.method) {
                "save" -> {
                    if (pendingSave != null || pendingLocate != null) {
                        result.error("busy", "A save dialog is already open.", null)
                    } else {
                        val source = File(call.argument<String>("source") ?: "").canonicalFile
                        if (!source.path.startsWith(cacheDir.canonicalPath + File.separator) || !source.isFile) {
                            result.error("invalid_source", "Private download file unavailable.", null)
                        } else {
                            pendingSave = result
                            pendingSource = source
                            pendingMimeType = savedTypes.forSave(
                                call.argument<String>("name") ?: source.name,
                                call.argument<String>("type")
                            )
                            val intent = Intent(Intent.ACTION_CREATE_DOCUMENT).apply {
                                addCategory(Intent.CATEGORY_OPENABLE)
                                type = pendingMimeType
                                putExtra(Intent.EXTRA_TITLE, call.argument<String>("name") ?: "attachment")
                            }
                            try {
                                startActivityForResult(intent, 7401)
                            } catch (_: Exception) {
                                pendingSave = null
                                pendingSource = null
                                pendingMimeType = null
                                result.error("save_unavailable", "File picker unavailable.", null)
                            }
                        }
                    }
                }
                "locate" -> {
                    if (pendingSave != null || pendingLocate != null) {
                        result.error("busy", "A file picker is already open.", null)
                    } else {
                        val intent = Intent(Intent.ACTION_OPEN_DOCUMENT).apply {
                            addCategory(Intent.CATEGORY_OPENABLE)
                            // Providers can report inconsistent MIME types for saved files.
                            type = "*/*"
                        }
                        pendingLocate = result
                        try {
                            startActivityForResult(intent, 7402)
                        } catch (_: Exception) {
                            pendingLocate = null
                            result.error("picker_unavailable", "Could not show saved files.", null)
                        }
                    }
                }
                "open" -> {
                    val location = call.argument<String>("location") ?: ""
                    if (!savedUris.containsKey(location)) {
                        trace("open_session_expired")
                        result.success("session_expired")
                    } else {
                        val uri = Uri.parse(location)
                        // Do not pre-read cloud documents just to launch a viewer. The
                        // provider may fetch/refresh a document on read. The explicit
                        // viewer owns that I/O; Android still enforces URI read access.
                        // Preserve the saved type across chooser cancellations and viewer
                        // returns. Downloads/cloud providers may later report a generic type.
                        val mimeType = savedTypes.forOpen(location) { contentResolver.getType(uri) }
                        val intent = Intent(Intent.ACTION_VIEW).apply {
                            setDataAndType(uri, mimeType)
                            addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION)
                            clipData = ClipData.newRawUri("Saved attachment", uri)
                        }
                        try {
                            startActivity(intent)
                            // Accepted by Android; it does not prove a viewer was selected.
                            trace("open_opened")
                            result.success("opened")
                        } catch (_: ActivityNotFoundException) {
                            trace("open_no_app")
                            result.success("no_app")
                        } catch (_: SecurityException) {
                            trace("open_viewer_permission_denied")
                            result.success("viewer_permission_denied")
                        } catch (_: Exception) {
                            trace("open_viewer_error")
                            result.success("viewer_error")
                        }
                    }
                }
                "release" -> {
                    trace("reader_release")
                    releaseSavedUri(call.argument<String>("location") ?: "")
                    result.success(null)
                }
                else -> result.notImplemented()
            }
        }
    }

    override fun onActivityResult(requestCode: Int, resultCode: Int, data: Intent?) {
        if (requestCode == 7402) {
            val result = pendingLocate ?: return
            pendingLocate = null
            val uri = data?.data
            if (resultCode != Activity.RESULT_OK || uri == null) {
                result.success(null)
                return
            }
            retainReadAccess(uri, data.flags)
            savedUris[uri.toString()] = (savedUris[uri.toString()] ?: 0) + 1
            trace("existing_file_registered")
            result.success(uri.toString())
            return
        }
        if (requestCode != 7401) {
            super.onActivityResult(requestCode, resultCode, data)
            return
        }
        val result = pendingSave ?: return
        val source = pendingSource
        val mimeType = pendingMimeType ?: "application/octet-stream"
        pendingSave = null
        pendingSource = null
        pendingMimeType = null
        val uri = data?.data
        if (resultCode != Activity.RESULT_OK || uri == null || source == null) {
            result.success(null)
            return
        }
        retainReadAccess(uri, data.flags)
        Thread {
            try {
                val output = contentResolver.openOutputStream(uri, "wt") ?: throw java.io.IOException()
                output.use { destination -> source.inputStream().use { it.copyTo(destination) } }
                runOnUiThread {
                    savedUris[uri.toString()] = (savedUris[uri.toString()] ?: 0) + 1
                    savedTypes.remember(uri.toString(), mimeType)
                    trace("save_registered")
                    result.success(uri.toString())
                }
            } catch (_: Exception) {
                runOnUiThread {
                    if (!savedUris.containsKey(uri.toString())) releaseRetainedRead(uri)
                    result.error("save_failed", "Could not save to the selected destination.", null)
                }
            }
        }.start()
    }
}
