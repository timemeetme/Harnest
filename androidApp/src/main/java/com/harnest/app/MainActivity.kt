package com.harnest.app.app

import android.os.Bundle
import androidx.activity.ComponentActivity
import androidx.activity.compose.setContent
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Surface
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.LocalConfiguration
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import com.harnest.app.app.ui.HarnessApp
import com.harnest.app.app.ui.theme.HarnessTheme
import com.harnest.app.platform.initAppDir
import com.harnest.app.shared.ui.AppViewModel
import com.harnest.app.shared.ui.WindowSize

class MainActivity : ComponentActivity() {

    private val viewModel by lazy { AppViewModel() }

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        initAppDir(this)
        setContent {
            HarnessTheme {
                Surface(
                    modifier = Modifier.fillMaxSize(),
                    color = MaterialTheme.colorScheme.background,
                ) {
                    val config = LocalConfiguration.current
                    val windowSize = WindowSize(
                        widthDp = config.screenWidthDp.toFloat(),
                        heightDp = config.screenHeightDp.toFloat(),
                    )
                    val state by viewModel.state.collectAsStateWithLifecycle()

                    LaunchedEffect(windowSize) {
                        viewModel.onWindowSizeChanged(windowSize)
                    }

                    LaunchedEffect(Unit) {
                        kotlinx.coroutines.delay(1500)
                        viewModel.connectKernel(
                            com.harnest.app.platform.defaultKernelHost(),
                            3080, false, "deepseek", "deepseek-chat"
                        )
                    }

                    HarnessApp(
                        viewModel = viewModel,
                        state = state,
                        windowSize = windowSize,
                    )
                }
            }
        }
    }
}
