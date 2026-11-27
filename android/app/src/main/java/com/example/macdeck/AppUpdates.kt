package com.example.macdeck

import android.app.AlertDialog
import android.content.Intent
import android.content.pm.PackageManager
import android.os.Build
import android.provider.Settings
import android.net.Uri
import androidx.core.content.FileProvider
import androidx.lifecycle.lifecycleScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext
import org.json.JSONObject
import java.io.File
import java.net.URL
import java.security.MessageDigest

private const val RELEASES = "https://github.com/master-x9/MacDeck/releases/"

@Suppress("DEPRECATION")
internal fun MainActivity.checkForAppUpdate(): kotlinx.coroutines.Job = lifecycleScope.launch {
    val release = withContext(Dispatchers.IO) {
        runCatching {
            val connection = URL(RELEASES + "latest/download/android-update.json").openConnection()
            connection.connectTimeout = 10000
            connection.readTimeout = 10000
            connection.getInputStream().bufferedReader().use { JSONObject(it.readText()) }
        }.getOrNull()
    } ?: return@launch
    val installed = packageManager.getPackageInfo(packageName, PackageManager.GET_SIGNATURES)
    val code = release.optInt("versionCode")
    val tag = release.optString("tag")
    val digest = release.optString("sha256")
    if (code <= installed.versionCode || !Regex("[A-Za-z0-9._-]+").matches(tag) ||
        !Regex("[0-9a-f]{64}").matches(digest) || isFinishing) return@launch
    val prefs = getSharedPreferences("updates", android.content.Context.MODE_PRIVATE)
    if (prefs.getInt("later", 0) == code && System.currentTimeMillis() - prefs.getLong("dismissed", 0) < 86400000L) return@launch
    AlertDialog.Builder(this@checkForAppUpdate)
        .setTitle("MacDeck " + release.optString("versionName") + " is available")
        .setMessage(release.optString("notes"))
        .setNegativeButton("Later") { _, _ -> prefs.edit().putInt("later", code).putLong("dismissed", System.currentTimeMillis()).apply() }
        .setPositiveButton("Download update") { _, _ ->
            lifecycleScope.launch {
                if (Build.VERSION.SDK_INT >= 26 && !packageManager.canRequestPackageInstalls()) {
                    requestUpdatePermission(Intent(Settings.ACTION_MANAGE_UNKNOWN_APP_SOURCES, Uri.parse("package:$packageName")))
                    return@launch
                }
                val progress = AlertDialog.Builder(this@checkForAppUpdate)
                    .setMessage("Downloading MacDeck…").setCancelable(false).show()
                try {
                    val apk = withContext(Dispatchers.IO) {
                        val dir = File(cacheDir, "updates").apply { mkdirs() }
                        val file = File.createTempFile("MacDeck-", ".apk", dir)
                        try {
                            val hash = MessageDigest.getInstance("SHA-256")
                            val connection = URL(RELEASES + "download/" + tag + "/MacDeck.apk").openConnection()
                            connection.connectTimeout = 15000
                            connection.readTimeout = 30000
                            connection.getInputStream().use { input ->
                                file.outputStream().use { output ->
                                    java.security.DigestInputStream(input, hash).copyTo(output)
                                }
                            }
                            require(hash.digest().joinToString("") { "%02x".format(it) } == digest)
                            val archive = packageManager.getPackageArchiveInfo(file.path, PackageManager.GET_SIGNATURES)
                            require(archive != null && archive.packageName == packageName && archive.versionCode == code &&
                                archive.signatures?.toSet() == installed.signatures?.toSet())
                            dir.listFiles()?.filter { it != file && it.lastModified() < System.currentTimeMillis()-86400000L }?.forEach { it.delete() }
                            file
                        } catch (e: Exception) { file.delete(); throw e }
                    }
                    val uri = FileProvider.getUriForFile(this@checkForAppUpdate, "$packageName.updates", apk)
                    startActivity(Intent(Intent.ACTION_VIEW).setDataAndType(uri, "application/vnd.android.package-archive")
                        .addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION))
                } catch (e: kotlinx.coroutines.CancellationException) {
                    throw e
                } catch (e: Exception) {
                    AlertDialog.Builder(this@checkForAppUpdate).setMessage("The update could not be installed. Try again later.").setPositiveButton("OK", null).show()
                } finally { if (!isDestroyed) progress.dismiss() }
            }
        }.show()
}
