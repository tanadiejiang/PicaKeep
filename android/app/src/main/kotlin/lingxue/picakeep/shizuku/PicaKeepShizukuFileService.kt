package lingxue.picakeep.shizuku

import android.content.Context
import android.content.pm.PackageInfo
import android.os.IBinder
import android.util.Log
import java.io.File
import java.util.Locale
import kotlin.system.exitProcess
import rikka.shizuku.Shizuku
import rikka.shizuku.ShizukuBinderWrapper
import rikka.shizuku.SystemServiceHelper

class PicaKeepShizukuFileService() : IPicaKeepShizukuFileService.Stub() {
    private var serviceContext: Context? = null

    constructor(context: Context) : this() {
        serviceContext = context.applicationContext
    }

    override fun destroy() {
        exitProcess(0)
    }

    override fun listEntries(path: String): List<String> {
        return listEntriesInternal(path).map { entry ->
            "${if (entry.isDirectory) "directory" else "file"}\t${entry.name}"
        }
    }

    override fun listInstalledPackageNames(): List<String> {
        return loadInstalledPackageNames()
    }

    override fun fileExists(path: String): Boolean {
        for (candidate in candidatePathsForShizuku(path)) {
            if (File(candidate).exists()) {
                return true
            }
        }
        return false
    }

    override fun readFile(path: String): ByteArray {
        var lastError: String? = null
        for (candidate in candidatePathsForShizuku(path)) {
            val file = File(candidate)
            if (file.isFile) {
                return file.readBytes()
            }
            lastError =
                when {
                    file.exists() -> "目标不是文件"
                    else -> "文件不存在或当前应用不可访问"
                }
        }
        throw IllegalStateException(lastError ?: "文件读取失败")
    }

    override fun writeFile(path: String, bytes: ByteArray) {
        var lastError: String? = null
        for (candidate in candidatePathsForShizuku(path)) {
            val targetFile = File(candidate)
            val parent = targetFile.parentFile
            if (parent != null && !parent.exists() && !parent.mkdirs()) {
                lastError = "创建目录失败"
                continue
            }
            val tempFile = File("${targetFile.path}.__picakeep_tmp__")
            try {
                tempFile.writeBytes(bytes)
                if (targetFile.exists() && !targetFile.delete()) {
                    throw IllegalStateException("覆盖目标文件失败")
                }
                if (!tempFile.renameTo(targetFile)) {
                    throw IllegalStateException("临时文件写回失败")
                }
                return
            } catch (error: Throwable) {
                tempFile.delete()
                lastError = error.message ?: "文件写入失败"
            }
        }
        throw IllegalStateException(lastError ?: "文件写入失败")
    }

    override fun deletePath(path: String) {
        var lastError: String? = null
        for (candidate in candidatePathsForShizuku(path)) {
            val file = File(candidate)
            if (!file.exists()) {
                lastError = "路径不存在或当前应用不可访问"
                continue
            }
            if (file.deleteRecursively()) {
                return
            }
            lastError = "文件删除失败"
        }
        throw IllegalStateException(lastError ?: "文件删除失败")
    }

    override fun movePath(sourcePath: String, targetPath: String) {
        var lastError: String? = null
        val targetCandidates = candidatePathsForShizuku(targetPath)
        for (sourceCandidate in candidatePathsForShizuku(sourcePath)) {
            val sourceFile = File(sourceCandidate)
            if (!sourceFile.exists()) {
                lastError = "路径不存在或当前应用不可访问"
                continue
            }
            for (targetCandidate in targetCandidates) {
                val targetFile = File(targetCandidate)
                val parent = targetFile.parentFile
                if (parent != null && !parent.exists() && !parent.mkdirs()) {
                    lastError = "创建目标目录失败"
                    continue
                }
                if (sourceFile.renameTo(targetFile)) {
                    return
                }
                lastError = "文件移动失败"
            }
        }
        throw IllegalStateException(lastError ?: "文件移动失败")
    }

    private fun listEntriesInternal(path: String): List<DirectoryEntry> {
        val normalized = normalizePath(path)
        var lastError: String? = null
        for (candidate in candidatePathsForShizuku(normalized)) {
            val directory = File(candidate)
            val children =
                runCatching {
                    directory.listFiles()
                }.getOrNull()
            if (children != null) {
                val entries =
                    children
                        .filter { it.isDirectory || it.isFile }
                        .map { child ->
                            DirectoryEntry(
                                name = child.name.trim(),
                                isDirectory = child.isDirectory,
                            )
                        }.filter { it.name.isNotEmpty() }
                        .toMutableList()
                if (isAndroidDataRoot(normalized)) {
                    val packageEntries = listAndroidDataPackageEntries(candidate, entries)
                    entries.addAll(packageEntries)
                    val topLevelFileEntries = listAndroidDataTopLevelFileEntries(candidate, entries)
                    entries.addAll(topLevelFileEntries)
                    val mergedEntries = sortEntries(entries)
                    Log.i(
                        TAG,
                        "android_data_enum dirent=${children.size} pm=${packageEntries.size} files=${topLevelFileEntries.size} merged=${mergedEntries.size}",
                    )
                    return mergedEntries
                }
                return sortEntries(entries)
            }
            lastError =
                when {
                    directory.exists() && !directory.isDirectory -> "目标不是目录"
                    else -> "目录不存在或当前应用不可访问"
                }
        }
        if (isAndroidDataRoot(normalized)) {
            val injected = mutableListOf<DirectoryEntry>()
            for (candidate in candidatePathsForShizuku(normalized)) {
                val packageEntries = listAndroidDataPackageEntries(candidate, injected)
                injected.addAll(packageEntries)
                val topLevelFileEntries = listAndroidDataTopLevelFileEntries(candidate, injected)
                injected.addAll(topLevelFileEntries)
                val mergedEntries = sortEntries(injected)
                Log.i(
                    TAG,
                    "android_data_enum dirent=0 pm=${packageEntries.size} files=${topLevelFileEntries.size} merged=${mergedEntries.size}",
                )
            }
            if (injected.isNotEmpty()) {
                return sortEntries(injected)
            }
        }
        throw IllegalStateException(lastError ?: "目录读取失败")
    }

    private fun listAndroidDataPackageEntries(
        basePath: String,
        existingEntries: List<DirectoryEntry>,
    ): List<DirectoryEntry> {
        val existingNames = existingEntries.mapTo(linkedSetOf()) { it.name }
        val entries = mutableListOf<DirectoryEntry>()
        for (packageName in loadInstalledPackageNames()) {
            if (packageName.isBlank() || !existingNames.add(packageName)) {
                continue
            }
            val candidate = File(basePath, packageName)
            if (candidate.exists()) {
                entries.add(DirectoryEntry(packageName, true))
            }
        }
        return entries
    }

    private fun listAndroidDataTopLevelFileEntries(
        basePath: String,
        existingEntries: List<DirectoryEntry>,
    ): List<DirectoryEntry> {
        val existingNames = existingEntries.mapTo(linkedSetOf()) { it.name }
        val entries = mutableListOf<DirectoryEntry>()
        for (name in KNOWN_ANDROID_DATA_TOP_LEVEL_FILES) {
            if (!existingNames.add(name)) {
                continue
            }
            val candidate = File(basePath, name)
            if (candidate.isFile) {
                entries.add(DirectoryEntry(name, isDirectory = false))
            }
        }
        return entries
    }

    private fun loadInstalledPackageNames(): List<String> {
        val names = linkedSetOf<String>()
        runCatching {
            names.addAll(listInstalledPackageNamesWithBinder())
        }.onFailure { error ->
            Log.w(TAG, "Failed to query installed packages via IPackageManager", error)
        }
        if (names.isEmpty()) {
            runCatching {
                names.addAll(listInstalledPackageNamesWithContext())
            }.onFailure { error ->
                Log.w(TAG, "Failed to query installed packages via PackageManager", error)
            }
        }
        return names.sortedBy { it.lowercase(Locale.ROOT) }
    }

    private fun listInstalledPackageNamesWithBinder(): List<String> {
        if (Shizuku.checkSelfPermission() != android.content.pm.PackageManager.PERMISSION_GRANTED) {
            return emptyList()
        }
        val binder = SystemServiceHelper.getSystemService("package") ?: return emptyList()
        val wrappedBinder = ShizukuBinderWrapper(binder)
        val stubClass = Class.forName("android.content.pm.IPackageManager\$Stub")
        val asInterface = stubClass.getMethod("asInterface", IBinder::class.java)
        val packageManager = asInterface.invoke(null, wrappedBinder) ?: return emptyList()
        val methods =
            packageManager.javaClass.methods
                .filter { it.name == "getInstalledPackages" }
                .sortedBy { it.parameterTypes.size }
        for (method in methods) {
            val args = buildInstalledPackagesArgs(method.parameterTypes) ?: continue
            val result = runCatching {
                method.isAccessible = true
                method.invoke(packageManager, *args)
            }.getOrNull() ?: continue
            val packageNames = extractPackageNames(result)
            if (packageNames.isNotEmpty()) {
                return packageNames
            }
        }
        return emptyList()
    }

    private fun listInstalledPackageNamesWithContext(): List<String> {
        val context = serviceContext ?: return emptyList()
        val packages =
            context.packageManager.getInstalledPackages(
                android.content.pm.PackageManager.PackageInfoFlags.of(
                    ANDROID_DATA_PACKAGE_QUERY_FLAGS.toLong(),
                ),
            )
        return packages.mapNotNull { it.packageName }.distinct()
    }

    private fun buildInstalledPackagesArgs(parameterTypes: Array<Class<*>>): Array<Any?>? {
        val args = arrayOfNulls<Any>(parameterTypes.size)
        var numericArgIndex = 0
        parameterTypes.forEachIndexed { index, type ->
            args[index] =
                when {
                    type == Int::class.javaPrimitiveType || type == Int::class.javaObjectType -> {
                        if (numericArgIndex++ == 0) {
                            ANDROID_DATA_PACKAGE_QUERY_FLAGS
                        } else {
                            0
                        }
                    }
                    type == Long::class.javaPrimitiveType || type == Long::class.javaObjectType -> {
                        if (numericArgIndex++ == 0) {
                            ANDROID_DATA_PACKAGE_QUERY_FLAGS.toLong()
                        } else {
                            0L
                        }
                    }
                    type == String::class.java -> serviceContext?.packageName ?: DEFAULT_PACKAGE_NAME
                    else -> return null
                }
        }
        return args
    }

    private fun extractPackageNames(result: Any): List<String> {
        val list =
            when (result) {
                is List<*> -> result
                else -> {
                    val getList =
                        runCatching {
                            result.javaClass.getMethod("getList")
                        }.getOrNull() ?: return emptyList()
                    (getList.invoke(result) as? List<*>) ?: return emptyList()
                }
            }
        return list.mapNotNull { extractPackageName(it) }.distinct()
    }

    private fun extractPackageName(value: Any?): String? {
        return when (value) {
            is PackageInfo -> value.packageName
            null -> null
            else ->
                runCatching {
                    value.javaClass.getField("packageName").get(value) as? String
                }.getOrNull()
        }?.trim()?.takeIf { it.isNotEmpty() }
    }

    private fun sortEntries(entries: List<DirectoryEntry>): List<DirectoryEntry> {
        return entries
            .distinctBy { "${it.isDirectory}\u0000${it.name}" }
            .sortedWith(
                compareBy<DirectoryEntry> { !it.isDirectory }
                    .thenBy { it.name.lowercase(Locale.ROOT) },
            )
    }

    private fun candidatePathsForShizuku(path: String): LinkedHashSet<String> {
        val normalized = normalizePath(path)
        val candidates = linkedSetOf<String>()
        realSharedStoragePath(normalized)?.let { candidates.add(it) }
        candidates.addAll(candidatePaths(normalized))
        return candidates
    }

    private fun candidatePaths(path: String): LinkedHashSet<String> {
        val normalized = normalizePath(path)
        val candidates = linkedSetOf(normalized)
        if (normalized == "/data/user/0") {
            candidates.add("/data/data")
            candidates.add("/data_mirror/data_ce/null/0")
        }
        if (normalized.startsWith("/data/user/0/")) {
            candidates.add(normalized.replaceFirst("/data/user/0/", "/data/data/"))
            candidates.add(
                normalized.replaceFirst("/data/user/0/", "/data_mirror/data_ce/null/0/"),
            )
        }
        if (normalized == "/data/data") {
            candidates.add("/data/user/0")
            candidates.add("/data_mirror/data_ce/null/0")
        }
        if (normalized.startsWith("/data/data/")) {
            candidates.add(normalized.replaceFirst("/data/data/", "/data/user/0/"))
            candidates.add(
                normalized.replaceFirst("/data/data/", "/data_mirror/data_ce/null/0/"),
            )
        }
        if (normalized == "/data_mirror/data_ce/null/0") {
            candidates.add("/data/user/0")
            candidates.add("/data/data")
        }
        if (normalized.startsWith("/data_mirror/data_ce/null/0/")) {
            candidates.add(
                normalized.replaceFirst("/data_mirror/data_ce/null/0/", "/data/user/0/"),
            )
            candidates.add(
                normalized.replaceFirst("/data_mirror/data_ce/null/0/", "/data/data/"),
            )
        }
        if (normalized.startsWith("/storage/emulated/0/")) {
            candidates.add(normalized.replaceFirst("/storage/emulated/0/", "/sdcard/"))
        }
        if (normalized == "/storage/emulated/0") {
            candidates.add("/sdcard")
        }
        if (normalized.startsWith("/sdcard/")) {
            candidates.add(normalized.replaceFirst("/sdcard/", "/storage/emulated/0/"))
        }
        if (normalized == "/sdcard") {
            candidates.add("/storage/emulated/0")
        }
        return candidates
    }

    private fun realSharedStoragePath(path: String): String? {
        val normalized = normalizePath(path)
        return when {
            normalized == "/storage/emulated/0" -> "/data/media/0"
            normalized.startsWith("/storage/emulated/0/") ->
                normalized.replaceFirst("/storage/emulated/0/", "/data/media/0/")
            normalized == "/sdcard" -> "/data/media/0"
            normalized.startsWith("/sdcard/") ->
                normalized.replaceFirst("/sdcard/", "/data/media/0/")
            else -> null
        }
    }

    private fun normalizePath(path: String): String {
        val rawPath = path.trim().replace('\\', '/')
        if (rawPath.isEmpty()) {
            return "/"
        }
        var normalized = if (rawPath.startsWith('/')) rawPath else "/$rawPath"
        while (normalized.length > 1 && normalized.endsWith('/')) {
            normalized = normalized.dropLast(1)
        }
        return normalized.ifEmpty { "/" }
    }

    private fun isAndroidDataRoot(path: String): Boolean {
        val normalized = normalizePath(path)
        return normalized == "/storage/emulated/0/Android/data" ||
            normalized == "/sdcard/Android/data" ||
            normalized == "/data/media/0/Android/data"
    }

    private data class DirectoryEntry(
        val name: String,
        val isDirectory: Boolean,
    )

    companion object {
        private const val TAG = "PicaKeepShizukuFs"
        private const val DEFAULT_PACKAGE_NAME = "lingxue.picakeep"
        private const val ANDROID_DATA_PACKAGE_QUERY_FLAGS = 0x00002000 or 0x00000200
        private val KNOWN_ANDROID_DATA_TOP_LEVEL_FILES = listOf(".nomedia")
    }
}
