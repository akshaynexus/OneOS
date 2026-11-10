package com.fahadali.oneos.core.root

import com.fahadali.oneos.core.model.Hashes
import org.junit.After
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Assume.assumeTrue
import org.junit.Test
import java.io.File
import java.nio.file.Files

/**
 * The OneiOS root script, its launcher and the session script's stage checks,
 * run under the machine's shells against a fake root folder
 * (`ONEIOS_TEST_ROOT`): nothing is started there, and the scripts refuse the
 * test root as uid 0.
 */
class OneiosScriptTest {
    private val rootScript = File(Shipped.fullAssets, OneiosRoot.ASSET)
    private val switchScript = File(Shipped.switcherAssets, "oneios_switch.sh")
    private val returnScript = File(Shipped.switcherAssets, "oneios_return.sh")

    private val shells: List<String> =
        (listOf("/bin/sh") + TestShell.available().map { it.path }).filter { File(it).canExecute() }.distinct()

    private val roots = mutableListOf<File>()

    @After
    fun cleanUp() {
        roots.forEach { it.deleteRecursively() }
    }

    private inner class Fake(val sh: String) {
        val root: File = Files.createTempDirectory("oneios-fakeroot").toFile().also { roots += it }
        val stage = File(root, "data/local/tmp/oneios")
        private val uid = run("id", "-u")
        private val gid = run("id", "-g")
        val layout = OneiosRoot.Layout(stage.path, sh, File(root, "proc").path, uid, "$uid:$gid")
        private val script = rootScript.readBytes()

        init {
            File(root, "data/local/tmp").mkdirs()
            for (d in listOf("proc/1", "proc/self", "proc/sys/kernel/random")) File(root, d).mkdirs()
            val mounts = "1 0 8:1 / / rw - ext4 /dev/root rw\n"
            File(root, "proc/1/mountinfo").writeText(mounts)
            File(root, "proc/self/mountinfo").writeText(mounts)
            File(root, "proc/sys/kernel/random/boot_id").writeText("boot-1\n")
        }

        private fun run(vararg cmd: String): String =
            ProcessBuilder(*cmd).redirectErrorStream(true).start().let { p -> p.inputStream.readBytes().toString(Charsets.UTF_8).trim().also { p.waitFor() } }

        inner class Out(val exit: Int, val text: String) {
            val reply = RootReply().also { r -> text.lines().forEach { r.accept(it) } }
            val status: OneiosStatus get() = OneiosStatus.parse(reply.results)
        }

        fun verb(verb: OneiosRoot.Verb, args: List<String> = emptyList(), data: ByteArray? = null): Out {
            val cmd = OneiosRoot.launcher(verb, args, Hashes.sha256(script), script.size.toLong(), layout)
            val pb = ProcessBuilder(sh, "-c", cmd).redirectErrorStream(true)
            pb.environment()["ONEIOS_TEST_ROOT"] = root.path
            val p = pb.start()
            val input = when (verb.stdin) {
                OneiosRoot.Stdin.SCRIPT -> script
                OneiosRoot.Stdin.DATA -> data!!
                OneiosRoot.Stdin.NONE -> null
            }
            val writer = Thread {
                runCatching { p.outputStream.use { o -> input?.let { o.write(it) } } }
            }.also { it.start() }
            val text = p.inputStream.readBytes().toString(Charsets.UTF_8)
            writer.join()
            return Out(p.waitFor(), text)
        }

        fun receive(kind: String, path: String, bytes: ByteArray, mode: String = "0644", sha: String = Hashes.sha256(bytes)) =
            verb(OneiosRoot.Verb.RECEIVE, listOf(kind, path, bytes.size.toString(), sha, mode), bytes)

        fun scripts() {
            for (f in listOf(switchScript, returnScript)) {
                val b = f.readBytes()
                assertOk(verb(OneiosRoot.Verb.SCRIPT, listOf(f.name, b.size.toString(), Hashes.sha256(b)), b))
            }
        }

        fun runtime(withXnuhost: Boolean = true, abi: Int = 1, formats: String = "1", placeholder: Boolean = false): Out {
            assertOk(verb(OneiosRoot.Verb.BEGIN, listOf("runtime")))
            assertOk(receive("runtime", "runtime.json", "{}".toByteArray()))
            assertOk(receive("runtime", "bin/stub", ByteArray(100) { 1 }, "0755"))
            if (withXnuhost) assertOk(receive("runtime", "bin/xnuhost", ELF, "0755"))
            return verb(OneiosRoot.Verb.FINISH, listOf("runtime", if (withXnuhost) "3" else "2", "0.1.0", abi.toString(), "bin/xnuhost", formats, if (placeholder) "1" else "0"))
        }

        fun image(format: Int = 1): Out {
            assertOk(verb(OneiosRoot.Verb.BEGIN, listOf("image")))
            assertOk(receive("image", "manifest.json", "{}".toByteArray()))
            assertOk(receive("image", "os.img", ByteArray(5000) { it.toByte() }))
            assertOk(receive("image", "overlay/kernel.kc", "kc".toByteArray()))
            return verb(OneiosRoot.Verb.FINISH, listOf("image", "3", format.toString(), "27.0.1", "24A446"))
        }
    }

    private fun assertOk(o: Fake.Out) = assertTrue(o.text, o.exit == 0 && o.reply.ok != null)

    private fun assertRefused(o: Fake.Out, part: String) {
        assertEquals(o.text, 2, o.exit)
        assertTrue("'${o.reply.refused}' lacks '$part'", o.reply.refused.orEmpty().contains(part))
    }

    private fun each(body: (Fake) -> Unit) {
        assumeTrue("no shell to run the scripts under", shells.isNotEmpty())
        for (sh in shells) body(Fake(sh))
    }

    @Test
    fun statusOnAPhoneWithoutAStageMakesNone() = each { f ->
        val o = f.verb(OneiosRoot.Verb.STATUS)
        assertOk(o)
        assertFalse(o.status.staged)
        assertFalse(f.stage.exists())
        assertOk(f.verb(OneiosRoot.Verb.REMOVE))
        assertFalse(f.stage.exists())
    }

    @Test
    fun onlyBeginStatusAndRemoveInstallTheScript() = each { f ->
        assertRefused(f.verb(OneiosRoot.Verb.SWITCH, listOf("100", "1")), "not in the stage")
        assertRefused(f.verb(OneiosRoot.Verb.FINISH, listOf("image", "3", "1", "27.0.1", "24A446")), "not in the stage")
        assertFalse(f.stage.exists())
        assertOk(f.verb(OneiosRoot.Verb.BEGIN, listOf("runtime")))
        assertTrue(File(f.stage, "bin/oneios_root.sh").isFile)
        assertEquals(Hashes.sha256(rootScript.readBytes()), Hashes.sha256(File(f.stage, "bin/oneios_root.sh").readBytes()))
    }

    /** Until a runtime with xnuhost is staged, the switch refuses with one line that says so. */
    @Test
    fun withoutARuntimeTheSwitchRefusesWithTheReason() = each { f ->
        assertOk(f.verb(OneiosRoot.Verb.BEGIN, listOf("image")))
        f.scripts()
        assertOk(f.image())
        val s = f.verb(OneiosRoot.Verb.STATUS).status
        assertTrue(s.staged)
        assertEquals(null, s.runtime)
        assertEquals("27.0.1", s.image?.version)
        assertEquals("24A446", s.image?.build)
        assertEquals(5004L, s.image?.bytes)
        assertFalse(s.ready)
        assertTrue(s.notReady, s.notReady!!.contains("no OneiOS runtime is staged") && s.notReady!!.contains("xnuhost"))
        assertFalse(s.notReady!!.contains("\n"))
        assertRefused(f.verb(OneiosRoot.Verb.SWITCH, listOf("100", "1")), "no OneiOS runtime is staged")
    }

    @Test
    fun aRuntimeWithoutXnuhostCannotBeStaged() = each { f ->
        assertRefused(f.runtime(withXnuhost = false), "the runtime has no bin/xnuhost")
        assertFalse(File(f.stage, "runtime").exists())
        assertFalse(File(f.stage, "runtime.conf").exists())
    }

    @Test
    fun aStagedPairPassesTheStageChecksAndNothingStarts() = each { f ->
        assertOk(f.runtime())
        f.scripts()
        var s = f.verb(OneiosRoot.Verb.STATUS).status
        assertEquals(OneiosStatus.Runtime("0.1.0", "1", "bin/xnuhost", "1", placeholder = false), s.runtime)
        assertTrue(s.notReady, s.notReady!!.contains("no iOS image set is staged"))
        assertOk(f.image())
        s = f.verb(OneiosRoot.Verb.STATUS).status
        assertTrue(s.notReady.orEmpty(), s.ready)
        assertFalse(s.sessionOpen)
        // The test root never starts a session.
        assertRefused(f.verb(OneiosRoot.Verb.SWITCH, listOf("100", "1")), "nothing was started")
        assertRefused(f.verb(OneiosRoot.Verb.SWITCH, listOf("100", "0")), "experimental tick")
        assertFalse(File(f.stage, "session").exists())
        // What root recorded: every file with its hash, the manifest included.
        assertEquals(
            setOf("runtime.json", "bin/stub", "bin/xnuhost"),
            File(f.stage, "runtime.sha256").readLines().map { it.substringAfter("  ") }.toSet(),
        )
        assertOk(f.verb(OneiosRoot.Verb.REMOVE))
        assertFalse(f.stage.exists())
    }

    @Test
    fun aChangedFileOrAMismatchedPairIsRefused() = each { f ->
        assertOk(f.runtime())
        f.scripts()
        assertOk(f.image())
        assertTrue(f.verb(OneiosRoot.Verb.STATUS).status.ready)
        fun why() = f.verb(OneiosRoot.Verb.STATUS).status.also { assertFalse(it.ready) }.notReady!!

        // xnuhost changed after staging (same size).
        val x = File(f.stage, "runtime/bin/xnuhost")
        x.writeBytes(ELF.copyOf().also { it[40] = 9 })
        assertTrue(why(), why().contains("runtime/bin/xnuhost does not match its SHA-256"))
        // Not an arm64 program.
        assertOk(f.verb(OneiosRoot.Verb.BEGIN, listOf("runtime")))
        assertOk(f.receive("runtime", "runtime.json", "{}".toByteArray()))
        assertOk(f.receive("runtime", "bin/xnuhost", "#!/bin/sh\n".toByteArray() + ByteArray(60), "0755"))
        assertOk(f.verb(OneiosRoot.Verb.FINISH, listOf("runtime", "2", "0.1.1", "1", "bin/xnuhost", "1", "0")))
        assertTrue(why(), why().contains("not an arm64 program"))
        // OneiOS's stand-in for an xnuhost that is not built yet: staged, shown, and never started.
        assertOk(f.runtime(placeholder = true))
        assertTrue(f.verb(OneiosRoot.Verb.STATUS).status.runtime!!.placeholder)
        assertTrue(why(), why().contains("placeholder instead of xnuhost"))
        assertRefused(f.verb(OneiosRoot.Verb.SWITCH, listOf("100", "1")), "placeholder instead of xnuhost")
        // Another session ABI, another image format.
        assertOk(f.runtime(abi = 2))
        assertTrue(why(), why().contains("session ABI 2"))
        assertOk(f.runtime(formats = "2,3"))
        assertTrue(why(), why().contains("image set is format 1"))
        assertOk(f.runtime())
        assertTrue(f.verb(OneiosRoot.Verb.STATUS).status.ready)
        // An image file replaced since it was staged, and a file nobody listed.
        val os = File(f.stage, "image/os.img")
        val copy = File(f.stage, "image/os.copy").also { it.writeBytes(os.readBytes()) }
        assertTrue(why(), why().contains("holds files its list does not name"))
        os.delete()
        assertTrue(copy.renameTo(os))
        assertTrue(why(), why().contains("image/os.img changed since it was staged"))
    }

    @Test
    fun receiveChecksSizeHashAndPath() = each { f ->
        assertOk(f.verb(OneiosRoot.Verb.BEGIN, listOf("image")))
        assertRefused(f.receive("image", "os.img", ByteArray(10), sha = "0".repeat(64)), "did not arrive intact")
        assertFalse(File(f.stage, "image.new/os.img").exists())
        assertFalse(File(f.stage, "image.new/os.img.part").exists())
        val short = f.verb(OneiosRoot.Verb.RECEIVE, listOf("image", "os.img", "20", Hashes.sha256(ByteArray(10)), "0644"), ByteArray(10))
        assertRefused(short, "10 of 20 bytes")
        assertOk(f.receive("image", "os.img", ByteArray(10)))
        assertRefused(f.receive("image", "os.img", ByteArray(10)), "already received")
        // A finish that does not match what was received.
        assertRefused(f.verb(OneiosRoot.Verb.FINISH, listOf("image", "3", "1", "27.0.1", "24A446")), "1 of 3 files")
        assertRefused(f.verb(OneiosRoot.Verb.FINISH, listOf("image", "2", "1", "27.0.1", "24A446")), "1 of 2 files")
        assertOk(f.receive("image", "a/b/c.bin", ByteArray(3)))
        assertRefused(f.verb(OneiosRoot.Verb.FINISH, listOf("image", "2", "1", "27.0.1", "24A446")), "manifest.json was not received")
        // Nothing is staged without a begin.
        assertRefused(f.receive("runtime", "bin/xnuhost", ELF, "0755"), "begin first")
    }

    @Test
    fun theLauncherCarriesOnlyPlainArguments() {
        fun bad(verb: OneiosRoot.Verb, vararg args: String) =
            assertTrue("$verb ${args.toList()}", OneiosRoot.problems(verb, args.toList()).isNotEmpty())
        fun good(verb: OneiosRoot.Verb, vararg args: String) =
            assertEquals("$verb ${args.toList()}", emptyList<String>(), OneiosRoot.problems(verb, args.toList()))
        val h = "a".repeat(64)
        good(OneiosRoot.Verb.STATUS)
        good(OneiosRoot.Verb.BEGIN, "image")
        good(OneiosRoot.Verb.RECEIVE, "image", "overlay/kernel.kc", "12", h, "0644")
        good(OneiosRoot.Verb.FINISH, "runtime", "3", "0.1.0", "1", "bin/xnuhost", "1,2", "0")
        bad(OneiosRoot.Verb.FINISH, "runtime", "3", "0.1.0", "1", "bin/xnuhost", "1,2")
        bad(OneiosRoot.Verb.FINISH, "runtime", "3", "0.1.0", "1", "bin/xnuhost", "1,2", "yes")
        good(OneiosRoot.Verb.FINISH, "image", "3", "1", "27.0.1", "24A446")
        good(OneiosRoot.Verb.SWITCH, "100", "1")
        bad(OneiosRoot.Verb.BEGIN, "system")
        bad(OneiosRoot.Verb.BEGIN, "image", "x")
        bad(OneiosRoot.Verb.RECEIVE, "image", "../os.img", "12", h, "0644")
        bad(OneiosRoot.Verb.RECEIVE, "image", "/os.img", "12", h, "0644")
        bad(OneiosRoot.Verb.RECEIVE, "image", "os.img;reboot", "12", h, "0644")
        bad(OneiosRoot.Verb.RECEIVE, "image", "os.img", "12", h, "4755")
        bad(OneiosRoot.Verb.RECEIVE, "image", "os.img", "1 2", h, "0644")
        bad(OneiosRoot.Verb.RECEIVE, "image", "os.img", "12", "\$(id)", "0644")
        bad(OneiosRoot.Verb.SCRIPT, "oneos_switch.sh", "12", h)
        bad(OneiosRoot.Verb.FINISH, "runtime", "3", "0.1.0", "1", "bin/xnuhost", "1;2", "0")
        bad(OneiosRoot.Verb.FINISH, "image", "3", "1", "27.0.1", "24A446 x")
        bad(OneiosRoot.Verb.SWITCH, "100", "yes")
        bad(OneiosRoot.Verb.REMOVE, "all")
        assertTrue(runCatching { OneiosRoot.launcher(OneiosRoot.Verb.BEGIN, listOf("image; reboot"), h, 10) }.isFailure)
        val text = OneiosRoot.launcher(OneiosRoot.Verb.RECEIVE, listOf("image", "os.img", "12", h, "0644"), h, 10)
        assertTrue(text.contains("set -- receive image os.img 12 $h 0644\n"))
        assertTrue(text.contains("S=/data/local/tmp/oneios\n"))
        assertFalse(Regex("@[A-Z]+@").containsMatchIn(text))
    }

    @Test
    fun statusLinesParse() {
        val s = OneiosStatus.parse(
            listOf(
                "stage present", "runtime 0.1.0 1 bin/xnuhost 1,2", "image 1 27.0.1 24A446 12345", "session open running",
                "outcome failsafe 1700000000 processes still in the session's namespace: 12", "ready 0 an iOS session of this boot is still open (running)",
            ),
        )
        assertTrue(s.staged)
        assertEquals("1,2", s.runtime?.imageFormats)
        assertEquals(12345L, s.image?.bytes)
        assertTrue(s.sessionOpen)
        assertEquals("failsafe", s.lastReturn)
        assertEquals("processes still in the session's namespace: 12", s.lastReturnDetail)
        assertEquals("an iOS session of this boot is still open (running)", s.notReady)
        val none = OneiosStatus.parse(listOf("stage present", "runtime none", "image none", "session none never", "outcome none", "ready 1"))
        assertEquals(null, none.runtime)
        assertEquals(null, none.image)
        assertTrue(none.ready)
        assertEquals(null, none.notReady)
    }

    // --- The session scripts' guards, on their text --------------------------------

    private fun code(f: File): List<String> = f.readLines().filterNot { it.trimStart().startsWith("#") }

    /** An iOS session never changes SELinux, a persist property, or anything of One UI's lock screen and keys. */
    @Test
    fun theSessionScriptsKeepOneUisGuards() {
        for (f in listOf(switchScript, returnScript, rootScript)) {
            val text = code(f).joinToString("\n")
            for (never in listOf(
                "setenforce", "setprop persist", "locksettings", "gatekeeper", "weaver", "/data/system/", "/data/misc/",
                "/data/user/", "/data/app/", " pm ", "cmd lock_settings", "vdc cryptfs", "keystore_cli",
            )) {
                assertFalse("${f.name} has '$never'", text.contains(never))
            }
        }
        val sw = code(switchScript).joinToString("\n")
        // xnuhost's namespace has the stage over /data, and the session refuses to go on if One UI's data shows.
        assertTrue(sw.contains("mount --bind \"\$STAGE\" /data"))
        assertTrue(sw.contains("One UI's /data is still visible in the session's namespace"))
        assertTrue(sw.contains("remount,bind,ro"))
        // Its own stage, never the Android guests'.
        assertTrue(sw.contains("STAGE=\"\$T/data/local/tmp/oneios\""))
        assertEquals(OneiosRoot.STAGE, "/data/local/tmp/oneios")
        assertFalse(OneiosRoot.STAGE == RootScript.STAGE)
        // The S24 Ultra only, checked by the script itself.
        assertTrue(sw.contains("SM-S928*") && sw.contains("e3q") && sw.contains("SM8650"))
    }

    /** Every refusal of the switch comes before its first change: nothing above "THE SESSION" stops or starts anything. */
    @Test
    fun theSwitchRefusesBeforeItChangesAnything() {
        val lines = code(switchScript)
        val preflight = lines.indexOfFirst { it.contains("id -u 2>/dev/null)\" = 0 ] || refuse") }
        val session = lines.indexOfFirst { it.contains("echo \"=== [1/5]") }
        assertTrue(preflight in 1 until session)
        val before = lines.subList(preflight, session).joinToString("\n")
        for (change in listOf("ctl.stop", "ctl.start", "kill ", "wake_lock 2", "mkdir", "rm -", "mount --", "unshare -m", "> \"\$SESSION")) {
            assertFalse("the preflight has '$change'", before.contains(change))
        }
        val after = lines.subList(session, lines.size).joinToString("\n")
        assertFalse("a refusal after the first change", Regex("""(^|\s)refuse "(?!\${'$'}SESSION is a symlink|could not make)""").containsMatchIn(after))
        // The way back is armed before One UI's zygote stops.
        assertTrue(after.indexOf("--watch") in 0 until after.indexOf("setprop ctl.stop zygote"))
        assertTrue(after.indexOf("--keys") in 0 until after.indexOf("setprop ctl.stop zygote"))
        // The return starts One UI's zygote only after its checks, and reboots when one fails.
        val ret = code(returnScript).joinToString("\n")
        assertTrue(ret.indexOf("Gate A") in 0 until ret.indexOf("setprop ctl.start zygote"))
        assertTrue(ret.contains("failsafe \"processes still in the session's namespace"))
        assertTrue(ret.contains("setprop sys.powerctl \"reboot,\$1\""))
        // A switch that ended before the stop is not a reason to restart One UI's framework or the phone:
        // the stop is marked, and without the mark the return only ends the helpers.
        assertTrue(after.indexOf("\"\$SESSION/stopped\"") in 0 until after.indexOf("setprop ctl.stop zygote"))
        val unmarked = ret.indexOf("if [ ! -e \"\$SESSION/stopped\" ]")
        assertTrue(unmarked in 0 until ret.indexOf("Gate A"))
        assertTrue(ret.indexOf("exit 0", unmarked) in unmarked until ret.indexOf("Gate A"))
        // A return with no open session does nothing.
        assertTrue(ret.indexOf("nothing to return from") in 0 until ret.indexOf("kill -TERM"))
    }

    private companion object {
        /** A 64-byte arm64 ELF header: "\u007fELF", 64-bit, e_machine 0xb7. */
        val ELF: ByteArray = ByteArray(64).also {
            byteArrayOf(0x7f, 'E'.code.toByte(), 'L'.code.toByte(), 'F'.code.toByte(), 2, 1, 1).copyInto(it)
            it[16] = 2
            it[18] = 0xb7.toByte()
        }
    }
}
