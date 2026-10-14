package my.getgroup.getride_gateway

import android.content.Context
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine

/**
 * The gateway's screen. It shows the process's engine ([GatewayRuntime])
 * and leaves it running when closed, so the gateway keeps going without it.
 */
class MainActivity : FlutterActivity() {
    override fun provideFlutterEngine(context: Context): FlutterEngine = GatewayRuntime.engine(context)

    override fun shouldDestroyEngineWithHost(): Boolean = false
}
