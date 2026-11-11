package com.fahadali.oneos.ui

import android.content.Intent
import android.os.Bundle
import android.view.View
import android.view.ViewGroup
import android.widget.Button
import android.widget.EditText
import android.widget.LinearLayout
import android.widget.TextView
import androidx.activity.result.contract.ActivityResultContracts
import androidx.appcompat.app.AlertDialog
import androidx.appcompat.widget.AppCompatCheckBox
import androidx.core.widget.NestedScrollView
import com.fahadali.oneos.R
import com.fahadali.oneos.core.model.OneiosKind
import com.fahadali.oneos.core.model.OneiosReleases
import com.fahadali.oneos.core.model.Units
import com.fahadali.oneos.session.OneiosJob
import dev.oneuiproject.oneui.layout.ToolbarLayout

/**
 * The iOS 27 (OneiOS) system's screen (docs/oneios.md), opened from its card on
 * Choose a system, which only the Galaxy S24 Ultra shows. Three parts: the
 * runtime (downloaded from OneiOS's releases, or a file), the iOS image set
 * (always a file the user built), and the session with its experimental tick.
 * Everything it does is a job of [OneiosJob].
 */
class OneiosActivity : EdgeToEdgeActivity() {
    private var unsubscribe: (() -> Unit)? = null
    private var ticked = false
    private var pickKind = OneiosKind.IMAGE
    private val picker = registerForActivityResult(ActivityResultContracts.OpenDocument()) { uri ->
        if (uri != null) OneiosJob.importFile(this, pickKind, uri)
    }

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        ticked = savedInstanceState?.getBoolean(KEY_TICKED) ?: false
        pickKind = if (savedInstanceState?.getString(KEY_KIND) == OneiosKind.RUNTIME.word) OneiosKind.RUNTIME else OneiosKind.IMAGE
        setContentView(R.layout.activity_oneios)
        val footer = findViewById<View>(R.id.oneios_footer)
        val toolbar = findViewById<ToolbarLayout>(R.id.oneios_toolbar)
        toolbar.setTitle(getString(R.string.oneios_title))
        toolbar.showNavigationButtonAsBack = true
        toolbar.setNavigationButtonOnClickListener { onBackPressedDispatcher.onBackPressed() }
        toolbar.setAdaptiveMarginProvider(dev.oneuiproject.oneui.widget.AdaptiveCoordinatorLayout.MARGIN_PROVIDER_ZERO)
        toolbar.setEdgeInsetHorizontal(0f)
        applyEdgeToEdgeInsets(toolbar) { bottom -> footer.updateBottomMarginForNavigationBar(0, bottom) }
        toolbar.findViewById<dev.oneuiproject.oneui.widget.RoundedFrameLayout>(dev.oneuiproject.oneui.design.R.id.tbl_main_content).apply {
            roundedCorners = 0; fillHorizontalPadding = false
        }
        toolbar.findViewById<View>(dev.oneuiproject.oneui.design.R.id.tbl_bottom_corners).visibility = View.GONE
        val scroll = findViewById<NestedScrollView>(R.id.oneios_scroll)
        footer.addOnLayoutChangeListener { _, _, _, _, _, _, _, _, _ ->
            val navigation = (footer.layoutParams as ViewGroup.MarginLayoutParams).bottomMargin
            scroll.setPadding(0, 0, 0, footer.height + navigation + dp(24))
        }
        findViewById<Button>(R.id.oneios_switch).setOnClickListener { confirmSwitch() }
    }

    override fun onSaveInstanceState(outState: Bundle) {
        super.onSaveInstanceState(outState)
        outState.putBoolean(KEY_TICKED, ticked)
        outState.putString(KEY_KIND, pickKind.word)
    }

    override fun onStart() {
        super.onStart()
        unsubscribe = OneiosJob.observe { render(it) }
    }

    override fun onResume() {
        super.onResume()
        if (!OneiosJob.state.busy) OneiosJob.refresh(this)
    }

    override fun onStop() {
        unsubscribe?.invoke()
        unsubscribe = null
        super.onStop()
    }

    private fun render(s: OneiosJob.State) {
        val list = findViewById<LinearLayout>(R.id.oneios_list)
        list.removeAllViews()
        val idle = !s.busy
        val st = s.status

        PrebootCards.row(PrebootCards.section(list, gap = false), getString(R.string.oneios_title), getString(R.string.oneios_about))

        // What is happening now, or how the last action ended.
        if (s.message != null) {
            val card = PrebootCards.section(list)
            val line = if (s.busy && s.total > 0) {
                "${Units.bytes(s.done)} of ${Units.bytes(s.total)} (${(s.done * 100 / s.total).coerceIn(0, 100)}%)"
            } else null
            PrebootCards.row(card, s.message, line)
            if (s.busy && s.phase != OneiosJob.Phase.CHECKING && s.phase != OneiosJob.Phase.SWITCHING) {
                PrebootCards.row(card, getString(R.string.oneios_stop)) { OneiosJob.cancel() }
            }
        }

        val runtime = PrebootCards.section(list, getString(R.string.oneios_runtime))
        PrebootCards.row(
            runtime,
            st?.runtime?.let {
                getString(if (it.placeholder) R.string.oneios_runtime_placeholder else R.string.oneios_runtime_staged, it.version, it.xnuhost)
            } ?: getString(R.string.oneios_runtime_none),
        )
        PrebootCards.row(runtime, getString(R.string.oneios_runtime_download), getString(R.string.oneios_runtime_download_line), chevron = true, enabled = idle) {
            askTag()
        }
        PrebootCards.row(runtime, getString(R.string.oneios_have_file), getString(R.string.oneios_runtime_file_line), chevron = true, enabled = idle) {
            pick(OneiosKind.RUNTIME)
        }

        val image = PrebootCards.section(list, getString(R.string.oneios_image))
        PrebootCards.row(
            image,
            st?.image?.let {
                getString(R.string.oneios_image_staged, it.version, it.build, it.format, it.bytes?.let(Units::bytes) ?: "?")
            } ?: getString(R.string.oneios_image_none),
        )
        PrebootCards.row(image, getString(R.string.oneios_have_file), getString(R.string.oneios_image_file_line), chevron = true, enabled = idle) {
            pick(OneiosKind.IMAGE)
        }
        PrebootCards.row(image, getString(R.string.oneios_image_how), getString(R.string.oneios_image_how_line), chevron = true) {
            SystemsNav.open(this, "https://github.com/${OneiosReleases.REPO}#readme")
        }

        val session = PrebootCards.section(list, getString(R.string.oneios_session))
        val offered = s.offered != false
        when {
            !offered -> PrebootCards.row(session, getString(R.string.oneios_not_ready), getString(R.string.oneios_not_this_phone))
            st == null -> PrebootCards.row(session, getString(R.string.oneios_checking))
            st.ready -> PrebootCards.row(session, getString(R.string.oneios_ready))
            else -> PrebootCards.row(session, getString(R.string.oneios_not_ready), st.notReady)
        }
        // Back to One UI, while a session is still open and this app runs (the volume keys do the same).
        if (st?.sessionOpen == true) {
            PrebootCards.row(session, getString(R.string.oneios_back), getString(R.string.oneios_back_line), chevron = true, enabled = idle) {
                OneiosJob.backToOneUi(this)
            }
        }
        when (st?.lastReturn) {
            "inplace" -> PrebootCards.row(session, getString(R.string.oneios_last_return_inplace))
            "failsafe" -> PrebootCards.row(session, getString(R.string.oneios_last_return_failsafe, st.lastReturnDetail.orEmpty()))
            "reboot" -> PrebootCards.row(session, getString(R.string.oneios_last_return_reboot))
        }

        // Hardware checks: OneiOS's phone tools beside One UI, a screen of its own.
        val tools = PrebootCards.section(list)
        PrebootCards.row(tools, getString(R.string.oneios_checks), getString(R.string.oneios_checks_line), chevron = true) {
            startActivity(OneiosChecksActivity.intent(this))
        }
        // Session logs: what the last iOS sessions logged, read as root (read only).
        PrebootCards.row(tools, getString(R.string.oneios_logs), getString(R.string.oneios_logs_line), chevron = true) {
            startActivity(OneiosLogsActivity.intent(this))
        }

        // The experimental tick: asked every time, as for a phone a system was never tested on.
        val box = AppCompatCheckBox(this).apply {
            text = getString(R.string.oneios_ack)
            textSize = 15f
            isChecked = ticked
            isEnabled = idle && offered
            setPadding(dp(8), dp(12), dp(8), dp(12))
            setOnCheckedChangeListener { _, checked ->
                ticked = checked
                updateSwitch()
            }
        }
        list.addView(box, LinearLayout.LayoutParams(-1, -2).apply { topMargin = dp(16); marginStart = dp(8); marginEnd = dp(8) })

        if (st?.staged == true) {
            PrebootCards.row(PrebootCards.section(list), getString(R.string.oneios_remove), getString(R.string.oneios_remove_line), enabled = idle) {
                AlertDialog.Builder(this).setTitle(R.string.oneios_remove).setMessage(R.string.oneios_remove_confirm)
                    .setNegativeButton(android.R.string.cancel, null)
                    .setPositiveButton(android.R.string.ok) { _, _ -> OneiosJob.remove(this) }.show()
            }
        }
        updateSwitch()
    }

    /** Switch is enabled only with the tick, on this phone, when root's own preflight would pass. */
    private fun updateSwitch() {
        val s = OneiosJob.state
        findViewById<Button>(R.id.oneios_switch).isEnabled =
            !s.busy && ticked && s.offered != false && s.status?.ready == true
    }

    private fun confirmSwitch() {
        if (!ticked || OneiosJob.state.busy) return
        AlertDialog.Builder(this).setTitle(R.string.oneios_switch).setMessage(R.string.oneios_switch_confirm)
            .setNegativeButton(android.R.string.cancel, null)
            .setPositiveButton(R.string.oneios_switch) { _, _ -> OneiosJob.switch(this, ticked) }.show()
    }

    private fun pick(kind: OneiosKind) {
        if (OneiosJob.state.busy) return
        pickKind = kind
        try {
            picker.launch(arrayOf("application/zstd", "application/octet-stream", "*/*"))
        } catch (_: android.content.ActivityNotFoundException) {
            android.widget.Toast.makeText(this, R.string.fix_no_app, android.widget.Toast.LENGTH_LONG).show()
        }
    }

    /** The latest release, or a pinned tag. */
    private fun askTag() {
        if (OneiosJob.state.busy) return
        val input = EditText(this).apply {
            hint = getString(R.string.oneios_tag_hint)
            isSingleLine = true
        }
        val frame = android.widget.FrameLayout(this).apply {
            setPadding(dp(24), dp(8), dp(24), 0)
            addView(input)
        }
        AlertDialog.Builder(this).setTitle(R.string.oneios_tag_title).setView(frame)
            .setNegativeButton(android.R.string.cancel, null)
            .setPositiveButton(R.string.oneios_runtime_download) { _, _ -> OneiosJob.downloadRuntime(this, input.text?.toString()) }
            .show()
    }

    private fun dp(value: Int) = (value * resources.displayMetrics.density + .5f).toInt()

    companion object {
        private const val KEY_TICKED = "ticked"
        private const val KEY_KIND = "kind"

        fun intent(ctx: android.content.Context): Intent = Intent(ctx, OneiosActivity::class.java)
    }
}
