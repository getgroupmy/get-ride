package my.getgroup.get_ride

import android.app.job.JobInfo
import android.app.job.JobParameters
import android.app.job.JobScheduler
import android.app.job.JobService
import android.content.BroadcastReceiver
import android.content.ComponentName
import android.content.Context
import android.content.Intent
import android.os.Build

/**
 * "Still there?" (migration 0276): a `location_ping` data push (FCM, high
 * priority) asks an "Always on" phone for one location fix, sent through
 * push_background_location with the install's key (BackgroundLocation.kt)
 * whatever the 15-minute rule says; the server still takes one background
 * report a minute, and the open app's check-in first. Nothing without
 * location allowed all the time and the reporter armed, as before.
 *
 * Firebase hands every push to each receiver of this action; this one reads
 * only its own type (TripCardPushReceiver reads trip_card). A broadcast has
 * seconds; a fix and a post can take longer, so the receiver only starts
 * [LocationPingJob] (expedited on Android 12+, which a high-priority push
 * allows, so it runs at once also in Doze). The job also sends the phone's
 * details (0282). A `location_live` push (God View's "Live now", 0282)
 * starts LiveLocation's foreground service instead, on screen or not; if
 * Android refuses it, one fix as for a ping.
 */
class LocationPingReceiver : BroadcastReceiver() {
    override fun onReceive(context: Context, intent: Intent) {
        val extras = intent.extras ?: return
        val type = extras.getString("type")
        if (type != "location_ping" && type != "location_live") return
        val app = context.applicationContext
        if (!BackgroundLocation.ready(app)) return
        if (type == "location_live") {
            if (!LiveLocation.start(app, 0L) && !TripCardNotifier.appVisible) LocationPingJob.start(app)
            return
        }
        // On screen, the app checks in itself.
        if (TripCardNotifier.appVisible) return
        LocationPingJob.start(app)
    }
}

/** One fix and its report, for [LocationPingReceiver]. */
class LocationPingJob : JobService() {
    companion object {
        private const val JOB_ID = 7313

        /** How long the fix may take; the job has minutes, a ping is worth little later. */
        private const val FIX_WAIT_MS = 20_000L

        fun start(context: Context) {
            val scheduler = context.getSystemService(Context.JOB_SCHEDULER_SERVICE) as? JobScheduler ?: return
            val service = ComponentName(context, LocationPingJob::class.java)
            fun build(expedited: Boolean): JobInfo {
                val b = JobInfo.Builder(JOB_ID, service).setRequiredNetworkType(JobInfo.NETWORK_TYPE_ANY)
                if (expedited && Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) {
                    b.setExpedited(true)
                } else {
                    b.setOverrideDeadline(0)
                }
                return b.build()
            }
            try {
                // A ping already waiting is replaced: one fix answers both.
                if (scheduler.schedule(build(true)) != JobScheduler.RESULT_SUCCESS) scheduler.schedule(build(false))
            } catch (e: Exception) {
                try {
                    scheduler.schedule(build(false))
                } catch (e2: Exception) {
                    // Best effort: the next report or ping tries again.
                }
            }
        }
    }

    override fun onStartJob(params: JobParameters): Boolean {
        val app = applicationContext
        if (!BackgroundLocation.ready(app)) return false
        val finish = { PhoneDetailsReport.send(app) { jobFinished(params, false) } }
        BackgroundLocation.fixNow(app, FIX_WAIT_MS) { fix ->
            if (fix == null) {
                finish()
            } else {
                BackgroundLocation.onFix(app, fix, true) { finish() }
            }
        }
        return true
    }

    // Stopped by the system (quota, network gone): the next ping tries again.
    override fun onStopJob(params: JobParameters): Boolean = false
}
