package com.harnessapp.app

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
import com.harnessapp.app.ui.HarnessApp
import com.harnessapp.app.ui.theme.HarnessTheme
import com.harnessapp.shared.ui.AppViewModel
import com.harnessapp.shared.ui.WindowSize

class MainActivity : ComponentActivity() {

    private val viewModel by lazy { AppViewModel() }

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
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
