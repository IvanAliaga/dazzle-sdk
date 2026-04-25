package dev.dazzle.samples.dazzlechatmemoryrn

import android.os.Bundle
import com.facebook.react.ReactActivity
import com.facebook.react.ReactActivityDelegate
import com.facebook.react.defaults.DefaultNewArchitectureEntryPoint.fabricEnabled
import com.facebook.react.defaults.DefaultReactActivityDelegate

class MainActivity : ReactActivity() {

  override fun getMainComponentName(): String = "chat_memory_rn"

  override fun createReactActivityDelegate(): ReactActivityDelegate =
      DefaultReactActivityDelegate(this, mainComponentName, fabricEnabled)

  override fun onCreate(savedInstanceState: Bundle?) {
    // Clear any lingering test flags from a prior launch of the same
    // process (Android reuses processes across activity restarts, so a
    // `System.setProperty("DAZZLE_SAMPLE_TEST", "1")` from the harness
    // would otherwise stick around and trick the JS-side mode check
    // into thinking this is still a test run).
    System.clearProperty("DAZZLE_SAMPLE_TEST")

    // Forward intent extras that the sample-test harness sets via
    // `adb shell am start --es DAZZLE_SAMPLE_TEST 1` into system
    // properties BEFORE the JS bundle loads, so our JS-side
    // `isSampleTestMode()` picks them up via the sync bridge.
    intent?.extras?.keySet()?.forEach { k ->
      val v = intent.extras?.getString(k) ?: return@forEach
      System.setProperty(k, v)
    }
    super.onCreate(savedInstanceState)
  }
}
