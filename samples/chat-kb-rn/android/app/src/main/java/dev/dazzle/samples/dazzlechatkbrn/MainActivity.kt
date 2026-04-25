package dev.dazzle.samples.dazzlechatkbrn

import android.os.Bundle
import com.facebook.react.ReactActivity
import com.facebook.react.ReactActivityDelegate
import com.facebook.react.defaults.DefaultNewArchitectureEntryPoint.fabricEnabled
import com.facebook.react.defaults.DefaultReactActivityDelegate

class MainActivity : ReactActivity() {
  override fun getMainComponentName(): String = "chat_kb_rn"

  override fun createReactActivityDelegate(): ReactActivityDelegate =
      DefaultReactActivityDelegate(this, mainComponentName, fabricEnabled)

  override fun onCreate(savedInstanceState: Bundle?) {
    // Clear any lingering test flags from a prior launch of the same
    // process — Android reuses processes across activity restarts, so
    // a System.setProperty from a previous SAMPLE_TEST run would
    // otherwise stick and trick isSampleTestMode() into re-triggering.
    System.clearProperty("DAZZLE_SAMPLE_TEST")

    // Forward intent extras (e.g. --es DAZZLE_SAMPLE_TEST 1) into
    // system properties BEFORE the JS bundle loads so our JS-side
    // sync `isSampleTestMode()` reads them.
    intent?.extras?.keySet()?.forEach { k ->
      val v = intent.extras?.getString(k) ?: return@forEach
      System.setProperty(k, v)
    }
    super.onCreate(savedInstanceState)
  }
}
