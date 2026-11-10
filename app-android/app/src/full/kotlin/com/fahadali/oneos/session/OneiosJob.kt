package com.fahadali.oneos.session

import android.content.Context
import android.net.Uri
import com.fahadali.oneos.BuildConfig
import com.fahadali.oneos.core.device.FactProbe
import com.fahadali.oneos.core.model.Hashes
import com.fahadali.oneos.core.model.Level
import com.fahadali.oneos.core.model.OneiosKind
import com.fahadali.oneos.core.model.OneiosManifest
import com.fahadali.oneos.core.model.OneiosManifests
import com.fahadali.oneos.core.model.OneiosPackage
import com.fahadali.oneos.core.model.OneiosReleases
import com.fahadali.oneos.core.model.OneiosSystem
import com.fahadali.oneos.core.model.Profiles
import com.fahadali.oneos.core.model.Units
import com.fahadali.oneos.core.root.OneiosRoot
import com.fahadali.oneos.core.root.OneiosStatus
import com.fahadali.oneos.core.root.RootProbe
import com.fahadali.oneos.core.root.RootReply
import com.fahadali.oneos.core.root.RootShell
import com.github.luben.zstd.ZstdInputStream
import java.io.BufferedInputStream
import java.io.File
import java.io.IOException
import java.io.InputStream
import java.net.HttpURLConnection
import java.net.URL
import java.security.MessageDigest

/**
 * Everything the app does for the iOS 27 (OneiOS) system (docs/oneios.md):
 * read what is staged, download the runtime package from OneiOS's releases,
 * import a runtime package or the iOS image set from a file the user picked,
 * switch, and remove. Each change is a verb of `oneios_root.sh` through
 * [OneiosRoot]'s launcher; the image set is never downloaded.
 *
 * A package is read twice from its source: once for its manifest, once to
 * hand every listed file to root (`receive`), hashed by the app on the way and
 * by root as it lands. Nothing replaces what is staged until `finish`.
 */
object OneiosJob : BackgroundJob<OneiosJob.State>(State(), "oneos-oneios") {
    enum class Phase { IDLE, CHECKING, DOWNLOADING, STAGING, SWITCHING, REMOVING }

    data class State(
        val phase: Phase = Phase.IDLE,
        /** What root last reported; null until the first check. */
        val status: OneiosStatus? = null,
        /** This phone takes the system ([OneiosSystem.offeredOn]); null until read. */
        val offered: Boolean? = null,
        /** The step in words while busy; afterwards the result or the reason it failed. */
        val message: String? = null,
        val failed: Boolean = false,
        val done: Long = 0,
        val total: Long = 0,
    ) {
        val busy: Boolean get() = phase != Phase.IDLE
    }

    private class Failed(message: String) : IOException(message)

    @Volatile private var cancelled = false

    @Volatile private var shell: RootShell? = null

    @Volatile private var connection: HttpURLConnection? = null

    private fun othersBusy() = StageCheck.state.busy || PrepareJob.state.busy || LaunchJob.state.busy || LogJob.state.busy ||
        OldStagesJob.state.busy || RemoveJob.state.busy

    fun canStart(): Boolean = !state.busy && !othersBusy()

    fun cancel() {
        cancelled = true
        shell?.cancel()
        runCatching { connection?.disconnect() }
    }

    // --- Root ---------------------------------------------------------------------

    private class Reply(val reply: RootReply, val end: RootShell.End) {
        val ok: Boolean get() = end.exitCode == 0 && reply.ok != null && end.error == null
        val problem: String
            get() = when {
                end.error != null -> end.error!!
                end.cancelled -> "stopped"
                end.killed && reply.refused == null -> "root did not answer in time"
                else -> reply.problem(end.exitCode) ?: "no answer from root"
            }
    }

    /** The root script, exactly the pinned bytes. */
    private fun rootScript(app: Context): ByteArray {
        val b = app.assets.open(OneiosRoot.ASSET).use { it.readBytes() }
        if (b.size.toLong() != BuildConfig.ONEIOS_ROOT_BYTES || Hashes.sha256(b) != BuildConfig.ONEIOS_ROOT_SHA256) {
            throw Failed("the OneiOS root script in the app is not the pinned one")
        }
        return b
    }

    private fun root(
        app: Context,
        verb: OneiosRoot.Verb,
        args: List<String> = emptyList(),
        data: RootShell.Feed? = null,
        silenceMs: Long = 120_000,
        totalMs: Long = 6 * 60 * 60_000L,
    ): Reply {
        val script = rootScript(app)
        val command = OneiosRoot.launcher(verb, args, BuildConfig.ONEIOS_ROOT_SHA256, BuildConfig.ONEIOS_ROOT_BYTES)
        val input = when (verb.stdin) {
            OneiosRoot.Stdin.SCRIPT -> RootShell.Feed { it.write(script) }
            OneiosRoot.Stdin.DATA -> requireNotNull(data) { "${verb.word} needs its data" }
            OneiosRoot.Stdin.NONE -> null
        }
        val sh = RootShell(command)
        shell = sh
        val reply = RootReply()
        val end = try {
            sh.run(input, { line -> reply.accept(line) }, { silenceMs }, totalMs)
        } finally {
            shell = null
        }
        return Reply(reply, end)
    }

    private fun must(r: Reply): Reply {
        if (cancelled) throw Failed("stopped")
        if (!r.ok) throw Failed(r.problem)
        return r
    }

    private fun readStatus(app: Context): OneiosStatus = OneiosStatus.parse(must(root(app, OneiosRoot.Verb.STATUS, silenceMs = 180_000)).reply.results)

    private fun offered(app: Context): Boolean =
        runCatching { OneiosSystem.offeredOn(Profiles.resolve(FactProbe(app).collect(RootProbe(app).signals())).profile) }.getOrDefault(false)

    /** Runs [work] as the one job; afterwards reads the status again and shows [work]'s result line or its failure. */
    private fun job(ctx: Context, phase: Phase, first: String, work: (Context) -> String?) {
        if (!canStart()) return
        val app = ctx.applicationContext
        cancelled = false
        update(state.copy(phase = phase, message = first, failed = false, done = 0, total = 0))
        executor.execute {
            val result = runCatching { work(app) }
            val offered = state.offered ?: offered(app)
            val status = runCatching { cancelled = false; readStatus(app) }.getOrNull() ?: state.status
            val why = result.exceptionOrNull()?.let { it.message ?: it.javaClass.simpleName }
            update(State(Phase.IDLE, status, offered, why ?: result.getOrNull(), failed = why != null))
        }
    }

    // --- What the screen calls --------------------------------------------------------

    /** Read only: what is staged and whether a switch would start. */
    fun refresh(ctx: Context) = job(ctx, Phase.CHECKING, "Checking what is on this phone…") { null }

    /** The runtime package of OneiOS's latest release, or of [tag]. */
    fun downloadRuntime(ctx: Context, tag: String?) = job(ctx, Phase.DOWNLOADING, "Looking for the OneiOS runtime…") { app ->
        val t = tag?.trim()?.takeIf { it.isNotEmpty() }
        if (t != null && !OneiosReleases.validTag(t)) throw Failed("'$t' is not a release tag")
        val api = http(OneiosReleases.apiUrl(t), accept = "application/vnd.github+json")
        if (api.first == 404) throw Failed(OneiosReleases.noRelease(t))
        if (api.first != 200) throw Failed("GitHub answered ${api.first} for the release")
        val release = OneiosReleases.parse(api.second.toString(Charsets.UTF_8)).getOrElse { throw Failed(it.message ?: "no runtime in the release") }
        val shaAnswer = http(release.sha256Url)
        if (shaAnswer.first != 200) throw Failed("${release.assetName}.sha256 could not be downloaded (${shaAnswer.first})")
        val sha = OneiosReleases.parseSha256(shaAnswer.second.toString(Charsets.UTF_8), release.assetName)
            ?: throw Failed("${release.assetName}.sha256 does not hold its SHA-256")
        val dir = File(app.cacheDir, "oneios").apply { mkdirs() }
        dir.listFiles()?.forEach { it.delete() }
        val file = File(dir, release.assetName)
        try {
            download(release.assetUrl, file, release.assetBytes, sha)
            val m = stage(app, OneiosKind.RUNTIME) { file.inputStream() }
            runtimeLine(m) + " (release ${release.tag})"
        } finally {
            file.delete()
        }
    }

    /** "I have the file": a runtime package or the iOS image set, through the picker's read grant. */
    fun importFile(ctx: Context, kind: OneiosKind, uri: Uri) = job(ctx, Phase.STAGING, "Reading the file…") { app ->
        val m = stage(app, kind) {
            app.contentResolver.openInputStream(uri) ?: throw Failed("the picked file cannot be opened")
        }
        when (kind) {
            OneiosKind.RUNTIME -> runtimeLine(m)
            OneiosKind.IMAGE -> "iOS ${m.version}${m.build?.let { " ($it)" }.orEmpty()} image set is staged: ${m.files.size} files, ${Units.bytes(m.bytes)}."
        }
    }

    /**
     * The switch. [ticked] is the experimental tick; the gate and root's own
     * preflight both have to pass, and a refusal changes nothing. When it works
     * One UI's framework stops, and this app with it.
     */
    fun switch(ctx: Context, ticked: Boolean) = job(ctx, Phase.SWITCHING, "Checking before the switch…") { app ->
        val profile = Profiles.resolve(FactProbe(app).collect(RootProbe(app).signals())).profile
        val gate = OneiosSystem.gate(profile, ticked)
        if (gate.level != Level.OK) throw Failed(if (gate.level == Level.BLOCK) gate.detail else "Tick the box first: ${gate.title}.")
        must(root(app, OneiosRoot.Verb.SWITCH, listOf(BuildConfig.VERSION_CODE.toString(), "1"), silenceMs = 180_000))
        "Switching to ${OneiosSystem.SHORT_NAME}…"
    }

    fun remove(ctx: Context) = job(ctx, Phase.REMOVING, "Removing the iOS files…") { app ->
        must(root(app, OneiosRoot.Verb.REMOVE, silenceMs = 10 * 60_000L))
        File(app.cacheDir, "oneios").deleteRecursively()
        "The iOS runtime, image set and data were removed from this phone."
    }

    private fun runtimeLine(m: OneiosManifest): String =
        if (m.placeholder) "OneiOS runtime ${m.version} is staged. It carries a placeholder instead of xnuhost, so it cannot start iOS yet."
        else "OneiOS runtime ${m.version} is staged."

    // --- Staging ----------------------------------------------------------------------

    private fun tar(raw: InputStream): InputStream =
        // The window both packages are packed with is at most 2^27 (OneiOS's oneos/interface.md).
        ZstdInputStream(BufferedInputStream(raw, 1 shl 20)).setContinuous(false).setLongMax(27)

    private fun progress(what: String, done: Long, total: Long) {
        val s = state
        // A state per MB at most.
        if (s.message == what && done - s.done < (1 shl 20) && done < total) return
        update(s.copy(message = what, done = done, total = total))
    }

    private fun stage(app: Context, kind: OneiosKind, open: () -> InputStream): OneiosManifest {
        val label = kind.label
        progress("Reading the $label's ${kind.manifestName}…", 0, 0)
        val found = try {
            tar(open()).use { OneiosPackage.readManifest(it, kind) }
        } catch (e: IOException) {
            throw Failed(notOurs(kind, e))
        }
        val manifest = OneiosManifests.parse(kind, found.text).getOrElse { throw Failed(it.message ?: "${kind.manifestName} is not valid") }
        if (kind == OneiosKind.RUNTIME && manifest.sessionAbi != OneiosSystem.SESSION_ABI) {
            throw Failed("This runtime speaks session ABI ${manifest.sessionAbi}; this version of OneOS speaks ${OneiosSystem.SESSION_ABI}.")
        }
        manifest.minOneosFork?.let { need ->
            if (!OneiosManifests.versionAtLeast(BuildConfig.VERSION_NAME, need)) {
                throw Failed("This runtime needs OneOS $need or newer; this is ${BuildConfig.VERSION_NAME}.")
            }
        }
        val total = manifest.bytes
        must(root(app, OneiosRoot.Verb.BEGIN, listOf(kind.word)))
        // The session scripts this build pins, with every staging: they are small, and always this app's.
        for ((name, pin) in listOf("oneios_switch.sh" to BuildConfig.ONEIOS_SWITCH_SHA256, "oneios_return.sh" to BuildConfig.ONEIOS_RETURN_SHA256)) {
            val b = app.assets.open("oneios/$name").use { it.readBytes() }
            if (Hashes.sha256(b) != pin) throw Failed("$name in the app is not the pinned one")
            must(root(app, OneiosRoot.Verb.SCRIPT, listOf(name, b.size.toString(), pin), RootShell.Feed { it.write(b) }))
        }
        val text = found.text.toByteArray(Charsets.UTF_8)
        must(root(app, OneiosRoot.Verb.RECEIVE, listOf(kind.word, kind.manifestName, text.size.toString(), Hashes.sha256(text), "0644"),
            RootShell.Feed { it.write(text) }))
        try {
            tar(open()).use { stream ->
                OneiosPackage.unpack(stream, manifest, found.prefix, { f, data ->
                    if (cancelled) throw Failed("stopped")
                    val what = "Staging ${f.path} (${Units.bytes(f.size)})"
                    progress(what, state.done, total)
                    val r = root(
                        app, OneiosRoot.Verb.RECEIVE, listOf(kind.word, f.path, f.size.toString(), f.sha256, f.mode),
                        RootShell.Feed { out ->
                            val buf = ByteArray(1 shl 20)
                            while (true) {
                                if (cancelled) throw IOException("stopped")
                                val n = data.read(buf)
                                if (n < 0) break
                                out.write(buf, 0, n)
                            }
                        },
                        // Root hashes the file after the last byte: minutes for several GB.
                        silenceMs = 20 * 60_000L,
                    )
                    must(r)
                }) { done -> progress(state.message ?: label, done, total) }
            }
        } catch (e: Failed) {
            throw e
        } catch (e: IOException) {
            throw Failed("The $label is damaged or incomplete: ${e.message}. Nothing staged before was changed.")
        }
        progress("Putting the $label in place…", total, total)
        val count = (manifest.files.size + 1).toString()
        val finish = when (kind) {
            OneiosKind.RUNTIME -> listOf(
                kind.word, count, manifest.version, manifest.sessionAbi.toString(), manifest.xnuhost!!,
                manifest.imageFormats.joinToString(","), if (manifest.placeholder) "1" else "0",
            )
            OneiosKind.IMAGE -> listOf(kind.word, count, manifest.format.toString(), manifest.version, manifest.build ?: "unknown")
        }
        must(root(app, OneiosRoot.Verb.FINISH, finish, silenceMs = 10 * 60_000L))
        return manifest
    }

    private fun notOurs(kind: OneiosKind, e: IOException): String {
        val m = e.message.orEmpty()
        return when {
            e is OneiosPackage.Problem -> m
            m.contains("tar") -> "This file is not a ${kind.label} ($m)."
            else -> "This file is not a .tar.zst ${kind.label}: $m"
        }
    }

    // --- Downloads (the runtime only, only from OneiOS's releases) ---------------------

    private fun open(url: String, accept: String?): HttpURLConnection {
        val c = URL(url).openConnection() as HttpURLConnection
        c.connectTimeout = 20_000
        c.readTimeout = 30_000
        c.instanceFollowRedirects = true
        c.setRequestProperty("User-Agent", "OneOS/${BuildConfig.VERSION_NAME}")
        if (accept != null) c.setRequestProperty("Accept", accept)
        connection = c
        return c
    }

    /** A small answer (the release JSON, the .sha256 file): its status and at most 1 MiB of it. */
    private fun http(url: String, accept: String? = null): Pair<Int, ByteArray> {
        val c = open(url, accept)
        try {
            val code = try {
                c.responseCode
            } catch (e: IOException) {
                throw Failed("No connection to GitHub (${e.message}).")
            }
            if (code != 200) return code to ByteArray(0)
            val out = java.io.ByteArrayOutputStream()
            c.inputStream.use { input ->
                val buf = ByteArray(1 shl 14)
                while (out.size() <= 1 shl 20) {
                    val n = input.read(buf)
                    if (n < 0) break
                    out.write(buf, 0, n)
                }
            }
            if (out.size() > 1 shl 20) throw Failed("the answer from GitHub is too long")
            return code to out.toByteArray()
        } finally {
            c.disconnect()
            connection = null
        }
    }

    private fun download(url: String, file: File, bytes: Long, sha256: String) {
        val c = open(url, "application/octet-stream")
        try {
            val code = try {
                c.responseCode
            } catch (e: IOException) {
                throw Failed("No connection to GitHub (${e.message}).")
            }
            if (code != 200) throw Failed("${file.name} could not be downloaded ($code)")
            val md = MessageDigest.getInstance("SHA-256")
            var n = 0L
            c.inputStream.use { input ->
                file.outputStream().use { out ->
                    val buf = ByteArray(1 shl 16)
                    while (true) {
                        if (cancelled) throw Failed("stopped")
                        val k = input.read(buf)
                        if (k < 0) break
                        n += k
                        if (n > bytes) throw Failed("${file.name} is larger than its release says")
                        md.update(buf, 0, k)
                        out.write(buf, 0, k)
                        progress("Downloading ${file.name} (${Units.bytes(bytes)})", n, bytes)
                    }
                }
            }
            if (n != bytes || Hashes.hex(md.digest()) != sha256) {
                throw Failed("${file.name} did not arrive intact (size or SHA-256 differs). Try again.")
            }
        } catch (e: Failed) {
            throw e
        } catch (e: IOException) {
            throw Failed("The download stopped (${e.message}). Try again.")
        } finally {
            c.disconnect()
            connection = null
        }
    }
}
