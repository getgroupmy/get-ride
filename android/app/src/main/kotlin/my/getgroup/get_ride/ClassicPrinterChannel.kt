package my.getgroup.get_ride

import android.Manifest
import android.bluetooth.BluetoothAdapter
import android.bluetooth.BluetoothDevice
import android.bluetooth.BluetoothManager
import android.bluetooth.BluetoothSocket
import android.content.Context
import android.content.Intent
import android.content.pm.PackageManager
import android.os.Build
import android.os.Handler
import android.os.Looper
import android.provider.Settings
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import java.io.IOException
import java.util.UUID
import java.util.concurrent.Executors
import java.util.concurrent.atomic.AtomicBoolean

/**
 * Classic Bluetooth (SPP / RFCOMM) receipt printers, for
 * lib/src/data/printer/classic_bluetooth.dart.
 *
 * One link at a time, written to and closed per print job: `bonded` lists
 * the paired devices, `connect` opens the serial port of one, `write` sends
 * bytes, `close` tears it down. Every blocking call runs on one background
 * thread, so jobs never overlap and the UI thread never waits on the radio.
 *
 * Error codes (read by `describeClassicPrinterError`): no_bluetooth,
 * bluetooth_off, permission, not_bonded, connect_failed, timeout,
 * write_failed, not_connected, bad_args.
 */
class ClassicPrinterChannel(private val context: Context, messenger: BinaryMessenger) :
    MethodChannel.MethodCallHandler {

    private val channel = MethodChannel(messenger, "get_ride/bt_classic")
    private val worker = Executors.newSingleThreadExecutor()
    private val main = Handler(Looper.getMainLooper())

    @Volatile
    private var socket: BluetoothSocket? = null

    init {
        channel.setMethodCallHandler(this)
    }

    fun dispose() {
        channel.setMethodCallHandler(null)
        worker.execute { closeSocket() }
        worker.shutdown()
    }

    override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
        when (call.method) {
            "bonded" -> run(result) { bonded() }
            "connect" -> {
                val address = call.argument<String>("address")
                val uuid = call.argument<String>("uuid") ?: SPP_UUID
                val timeoutMs = (call.argument<Number>("timeoutMs") ?: 12000).toLong()
                if (address == null || !BluetoothAdapter.checkBluetoothAddress(address)) {
                    result.error("bad_args", "Not a Bluetooth address", null)
                    return
                }
                run(result) { connect(address, UUID.fromString(uuid), timeoutMs); null }
            }
            "write" -> {
                val bytes = call.argument<ByteArray>("bytes")
                if (bytes == null) {
                    result.error("bad_args", "Nothing to write", null)
                    return
                }
                run(result) { write(bytes); null }
            }
            "close" -> run(result) { closeSocket(); null }
            "openSettings" -> result.success(openSettings())
            else -> result.notImplemented()
        }
    }

    private class Failure(val code: String, message: String) : Exception(message)

    /** Runs [block] off the UI thread and answers on it. */
    private fun run(result: MethodChannel.Result, block: () -> Any?) {
        worker.execute {
            try {
                val value = block()
                main.post { result.success(value) }
            } catch (e: Failure) {
                main.post { result.error(e.code, e.message, null) }
            } catch (e: SecurityException) {
                main.post { result.error("permission", e.message, null) }
            } catch (e: Exception) {
                main.post { result.error("failed", e.message ?: e.toString(), null) }
            }
        }
    }

    private fun adapter(): BluetoothAdapter {
        val manager = context.getSystemService(Context.BLUETOOTH_SERVICE) as? BluetoothManager
        val adapter = manager?.adapter ?: throw Failure("no_bluetooth", "This phone has no Bluetooth")
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S &&
            context.checkSelfPermission(Manifest.permission.BLUETOOTH_CONNECT) != PackageManager.PERMISSION_GRANTED
        ) {
            throw Failure("permission", "Nearby devices permission not granted")
        }
        if (!adapter.isEnabled) throw Failure("bluetooth_off", "Bluetooth is off")
        return adapter
    }

    private fun bonded(): List<Map<String, Any?>> =
        adapter().bondedDevices.orEmpty()
            .filter { it.type != BluetoothDevice.DEVICE_TYPE_LE }
            .map {
                mapOf(
                    "address" to it.address,
                    "name" to it.name,
                    "majorClass" to it.bluetoothClass?.majorDeviceClass,
                )
            }

    private fun connect(address: String, uuid: UUID, timeoutMs: Long) {
        closeSocket()
        val adapter = adapter()
        val device = adapter.getRemoteDevice(address)
        if (device.bondState != BluetoothDevice.BOND_BONDED) {
            throw Failure("not_bonded", "The printer is not paired with this phone")
        }
        // Discovery slows an RFCOMM connect to a crawl. Cancelling it needs the
        // scan permission on Android 12+, which this path does not depend on.
        try {
            adapter.cancelDiscovery()
        } catch (ignored: SecurityException) {
        }

        // The standard secure socket first, then the insecure one many cheap
        // printers need; each bounded by the timeout, since connect() itself
        // can block for half a minute on a printer that is off.
        val attempts = listOf<() -> BluetoothSocket>(
            { device.createRfcommSocketToServiceRecord(uuid) },
            { device.createInsecureRfcommSocketToServiceRecord(uuid) },
        )
        var last: Exception? = null
        val timedOut = AtomicBoolean(false)
        for (open in attempts) {
            val candidate = try {
                open()
            } catch (e: IOException) {
                last = e
                continue
            }
            val watchdog = Runnable {
                timedOut.set(true)
                try {
                    candidate.close()
                } catch (ignored: IOException) {
                }
            }
            main.postDelayed(watchdog, timeoutMs)
            try {
                candidate.connect()
                main.removeCallbacks(watchdog)
                socket = candidate
                return
            } catch (e: IOException) {
                main.removeCallbacks(watchdog)
                last = e
                try {
                    candidate.close()
                } catch (ignored: IOException) {
                }
                if (timedOut.get()) break
            }
        }
        if (timedOut.get()) throw Failure("timeout", "The printer did not answer")
        throw Failure("connect_failed", last?.message ?: "Could not connect to the printer")
    }

    private fun write(bytes: ByteArray) {
        val s = socket ?: throw Failure("not_connected", "The printer is not connected")
        try {
            s.outputStream.write(bytes)
            s.outputStream.flush()
        } catch (e: IOException) {
            closeSocket()
            throw Failure("write_failed", e.message ?: "The connection dropped")
        }
    }

    private fun closeSocket() {
        val s = socket
        socket = null
        try {
            s?.close()
        } catch (ignored: IOException) {
        }
    }

    private fun openSettings(): Boolean = try {
        context.startActivity(
            Intent(Settings.ACTION_BLUETOOTH_SETTINGS).addFlags(Intent.FLAG_ACTIVITY_NEW_TASK),
        )
        true
    } catch (ignored: Exception) {
        false
    }

    companion object {
        const val SPP_UUID = "00001101-0000-1000-8000-00805F9B34FB"
    }
}
