package com.example.macdeck

import android.os.Build
import android.os.Bundle
import android.view.HapticFeedbackConstants
import android.view.WindowManager
import androidx.activity.compose.setContent
import androidx.activity.enableEdgeToEdge
import androidx.activity.viewModels
import androidx.biometric.BiometricManager
import androidx.biometric.BiometricPrompt
import androidx.compose.animation.*
import androidx.compose.animation.core.*
import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.pager.HorizontalPager
import androidx.compose.foundation.pager.rememberPagerState
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.Settings
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.draw.shadow
import androidx.compose.ui.graphics.Brush
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.graphicsLayer
import androidx.compose.ui.platform.LocalView
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import androidx.compose.ui.util.lerp
import androidx.core.content.ContextCompat
import androidx.core.view.WindowCompat
import androidx.core.view.WindowInsetsCompat
import androidx.core.view.WindowInsetsControllerCompat
import androidx.fragment.app.FragmentActivity
import com.example.macdeck.ui.theme.MacDeckTheme
import kotlinx.coroutines.launch
import kotlin.math.absoluteValue

class MainActivity : FragmentActivity() {
    private val installPermission = registerForActivityResult(
        androidx.activity.result.contract.ActivityResultContracts.StartActivityForResult()
    ) {
        if (Build.VERSION.SDK_INT >= 26 && packageManager.canRequestPackageInstalls()) checkForAppUpdate()
    }

    internal fun requestUpdatePermission(intent: android.content.Intent) = installPermission.launch(intent)

    private val viewModel: AppViewModel by viewModels()

    /// Prompts for fingerprint/face (falling back to device PIN/pattern) before
    /// running `onSuccess`. Used only for the "Unlock Mac" tile — every other
    /// locked-page tile (brightness, volume, etc.) triggers immediately.
    private fun authenticateThenUnlock(onSuccess: () -> Unit) {
        val authenticators = BiometricManager.Authenticators.BIOMETRIC_STRONG or
                BiometricManager.Authenticators.DEVICE_CREDENTIAL

        val canAuthenticate = BiometricManager.from(this).canAuthenticate(authenticators)
        if (canAuthenticate != BiometricManager.BIOMETRIC_SUCCESS) {
            // No biometric or device credential is set up on this phone — fail
            // safe rather than unlocking the Mac with no local check at all.
            android.util.Log.w("MainActivity", "Cannot authenticate locally (code=$canAuthenticate); unlock blocked")
            return
        }

        val promptInfo = BiometricPrompt.PromptInfo.Builder()
            .setTitle("Unlock Mac")
            .setSubtitle("Confirm it's you before unlocking your Mac")
            .setAllowedAuthenticators(authenticators)
            .build()

        val prompt = BiometricPrompt(
            this,
            ContextCompat.getMainExecutor(this),
            object : BiometricPrompt.AuthenticationCallback() {
                override fun onAuthenticationSucceeded(result: BiometricPrompt.AuthenticationResult) {
                    onSuccess()
                }

                override fun onAuthenticationError(errorCode: Int, errString: CharSequence) {
                    // Includes user-cancel and lockout — no unlock is sent either way.
                    android.util.Log.d("MainActivity", "Unlock auth error: $errString")
                }

                override fun onAuthenticationFailed() {
                    // A single failed attempt; the prompt stays open for retry.
                }
            }
        )
        prompt.authenticate(promptInfo)
    }

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        if (savedInstanceState == null) checkForAppUpdate()

        enableEdgeToEdge()

        window.addFlags(WindowManager.LayoutParams.FLAG_LAYOUT_NO_LIMITS)

        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.R) {
            window.attributes.layoutInDisplayCutoutMode = WindowManager.LayoutParams.LAYOUT_IN_DISPLAY_CUTOUT_MODE_ALWAYS
        } else if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.P) {
            window.attributes.layoutInDisplayCutoutMode = WindowManager.LayoutParams.LAYOUT_IN_DISPLAY_CUTOUT_MODE_SHORT_EDGES
        }

        window.addFlags(WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON)

        val windowInsetsController = WindowCompat.getInsetsController(window, window.decorView)
        windowInsetsController.hide(WindowInsetsCompat.Type.systemBars())
        windowInsetsController.systemBarsBehavior = WindowInsetsControllerCompat.BEHAVIOR_SHOW_TRANSIENT_BARS_BY_SWIPE

        setContent {
            MacDeckTheme {
                val uiState by viewModel.uiState.collectAsState()
                var showSettings by remember { mutableStateOf(false) }

                Surface(
                    modifier = Modifier.fillMaxSize(),
                    color = Color.Black
                ) {
                    Box {
                        when (val state = uiState) {
                            is AppUiState.Searching -> {
                                InfoScreen("Searching for Mac...", "Ensure MacDeck is running on your Mac.")
                            }
                            is AppUiState.SelectingMac -> {
                                MacPickerScreen(
                                    macs = state.macs,
                                    onSelect = { mac -> viewModel.connectToMac(mac) }
                                )
                            }
                            is AppUiState.Connecting -> {
                                InfoScreen("Connecting to ${state.hostName}...", "")
                            }
                            is AppUiState.PairingPending -> {
                                InfoScreen(
                                    "Waiting for approval on your Mac",
                                    "Check the screen on ${state.hostName}."
                                )
                            }
                            is AppUiState.PairingDenied -> {
                                InfoScreen("Pairing Denied", "The connection was refused on your Mac.")
                            }
                            is AppUiState.VersionMismatch -> {
                                InfoScreen(
                                    "Update Required",
                                    "Version mismatch. Required: ${state.requiredVersion}"
                                )
                            }
                            is AppUiState.Paired -> {
                                val view = LocalView.current
                                LaunchedEffect(Unit) {
                                    viewModel.requestSync()
                                }

                                Box(modifier = Modifier.fillMaxSize()) {
                                    if (state.isLocked) {
                                        // Mac is locked: show only the fixed locked-screen
                                        // layout (brightness, volume, KB brightness,
                                        // play/pause, unlock) — no pager, no swiping to
                                        // other pages, no settings access.
                                        key(LockedPage.ID) {
                                            FullScreenGrid(
                                                page = LockedPage.page,
                                                gridRows = viewModel.gridRows,
                                                onTileClick = { slotIndex ->
                                                    if (slotIndex == LockedPage.UNLOCK_SLOT_INDEX) {
                                                        authenticateThenUnlock {
                                                            view.performHapticFeedback(HapticFeedbackConstants.VIRTUAL_KEY)
                                                            viewModel.triggerSlot(LockedPage.ID, slotIndex)
                                                        }
                                                    } else {
                                                        view.performHapticFeedback(HapticFeedbackConstants.VIRTUAL_KEY)
                                                        viewModel.triggerSlot(LockedPage.ID, slotIndex)
                                                    }
                                                }
                                            )
                                        }
                                    } else if (state.pages.isEmpty()) {
                                        InfoScreen("Loading Pages...", "")
                                    } else {
                                        val pagerState = rememberPagerState(pageCount = { state.pages.size })

                                        var previousPages by remember { mutableStateOf(state.pages) }
                                        var lastViewedPageId by remember { mutableStateOf<String?>(null) }
                                        val coroutineScope = rememberCoroutineScope()

                                        LaunchedEffect(state.pages) {
                                            val oldPages = previousPages
                                            val newPages = state.pages
                                            previousPages = newPages

                                            val oldBrowserPage = oldPages.find { p -> p.tiles.any { t -> t?.tileType is BrowserControlTile } }
                                            val newBrowserPage = newPages.find { p -> p.tiles.any { t -> t?.tileType is BrowserControlTile } }

                                            if (newBrowserPage != null && oldBrowserPage == null) {
                                                if (pagerState.currentPage < oldPages.size) {
                                                    lastViewedPageId = oldPages[pagerState.currentPage].id
                                                }
                                                val targetIndex = newPages.indexOf(newBrowserPage)
                                                // Guard against animating to where we already are — the Mac can
                                                // also send an explicit SWITCH_TO_PAGE around the same moment
                                                // the browser page appears, so without this check both paths
                                                // can fire an animateScrollToPage back-to-back and visibly jank.
                                                if (targetIndex != -1 && targetIndex != pagerState.currentPage) {
                                                    coroutineScope.launch {
                                                        kotlinx.coroutines.delay(100)
                                                        pagerState.animateScrollToPage(targetIndex)
                                                    }
                                                }
                                            } else if (newBrowserPage == null && oldBrowserPage != null) {
                                                val targetIndex = lastViewedPageId
                                                    ?.let { id -> newPages.indexOfFirst { it.id == id } }
                                                    ?.takeIf { it != -1 }
                                                    ?: 0 // fall back to the first page rather than doing nothing
                                                if (targetIndex != pagerState.currentPage) {
                                                    coroutineScope.launch {
                                                        kotlinx.coroutines.delay(100)
                                                        pagerState.animateScrollToPage(targetIndex)
                                                    }
                                                }
                                                lastViewedPageId = null
                                            }
                                        }

                                        LaunchedEffect(Unit) {
                                            viewModel.scrollToPage.collect { pageID ->
                                                val targetIndex = state.pages.indexOfFirst { it.id == pageID }
                                                if (targetIndex != -1 && targetIndex != pagerState.currentPage) {
                                                    coroutineScope.launch {
                                                        pagerState.animateScrollToPage(targetIndex)
                                                    }
                                                }
                                            }
                                        }

                                        HorizontalPager(
                                            state = pagerState,
                                            modifier = Modifier.fillMaxSize(),
                                            contentPadding = PaddingValues(horizontal = 0.dp),
                                            beyondViewportPageCount = 1
                                        ) { pageIndex ->
                                            val page = state.pages[pageIndex]

                                            Box(
                                                modifier = Modifier
                                                    .graphicsLayer {
                                                        // Use a lambda to avoid recomposition during scroll
                                                        val pageOffset = (
                                                                (pagerState.currentPage - pageIndex) + pagerState
                                                                    .currentPageOffsetFraction
                                                                ).absoluteValue

                                                        // Page transition effects
                                                        val scale = lerp(
                                                            start = 0.9f,
                                                            stop = 1f,
                                                            fraction = 1f - pageOffset.coerceIn(0f, 1f)
                                                        )
                                                        scaleX = scale
                                                        scaleY = scale
                                                        alpha = lerp(
                                                            start = 0.5f,
                                                            stop = 1f,
                                                            fraction = 1f - pageOffset.coerceIn(0f, 1f)
                                                        )
                                                    }
                                                    .fillMaxSize()
                                            ) {
                                                key(page.id) {
                                                    FullScreenGrid(
                                                        page = page,
                                                        gridRows = viewModel.gridRows,
                                                        onTileClick = { slotIndex ->
                                                            view.performHapticFeedback(HapticFeedbackConstants.VIRTUAL_KEY)
                                                            viewModel.triggerSlot(page.id, slotIndex)
                                                        }
                                                    )
                                                }
                                            }
                                        }

                                        // Pager Indicators
                                        if (state.pages.size > 1) {
                                            Row(
                                                modifier = Modifier
                                                    .align(Alignment.BottomCenter)
                                                    .padding(bottom = 32.dp)
                                                    .background(Color.Black.copy(alpha = 0.3f), RoundedCornerShape(12.dp))
                                                    .padding(horizontal = 12.dp, vertical = 6.dp),
                                                horizontalArrangement = Arrangement.spacedBy(8.dp),
                                                verticalAlignment = Alignment.CenterVertically
                                            ) {
                                                repeat(state.pages.size) { index ->
                                                    val isSelected by remember {
                                                        derivedStateOf { pagerState.currentPage == index }
                                                    }
                                                    val width by animateDpAsState(
                                                        targetValue = if (isSelected) 24.dp else 6.dp,
                                                        label = "width"
                                                    )
                                                    Box(
                                                        modifier = Modifier
                                                            .width(width)
                                                            .height(6.dp)
                                                            .clip(RoundedCornerShape(3.dp))
                                                            .background(if (isSelected) Color.White else Color.White.copy(alpha = 0.2f))
                                                    )
                                                }
                                            }
                                        }
                                    }

                                    if (state.isDisconnected) {
                                        StatusOverlay(text = "Disconnected")
                                    }
                                }
                            }
                        }

                        // Settings Button (Integrated FAB style)
                        Box(
                            modifier = Modifier
                                .align(Alignment.BottomEnd)
                                .padding(24.dp)
                                .size(48.dp)
                                .clip(CircleShape)
                                .background(Color(0xFF2C2C2E).copy(alpha = 0.6f))
                                .border(1.dp, Color.White.copy(alpha = 0.1f), CircleShape)
                                .clickable { showSettings = true },
                            contentAlignment = Alignment.Center
                        ) {
                            Icon(
                                Icons.Default.Settings,
                                contentDescription = "Settings",
                                tint = Color.White.copy(alpha = 0.7f),
                                modifier = Modifier.size(24.dp)
                            )
                        }

                        if (showSettings) {
                            SettingsDialog(
                                currentName = viewModel.deviceName,
                                currentGridRows = viewModel.gridRows,
                                onDismiss = { showSettings = false },
                                onSave = { newName, newRows ->
                                    if (viewModel.deviceName != newName) {
                                        viewModel.updateDeviceName(newName)
                                    }
                                    if (viewModel.gridRows != newRows) {
                                        viewModel.updateGridRows(newRows)
                                    }
                                    showSettings = false
                                },
                                onReset = {
                                    viewModel.resetPairing()
                                    showSettings = false
                                }
                            )
                        }
                    }
                }
            }
        }
    }
}

@Composable
fun MacPickerScreen(
    macs: List<DiscoveredMac>,
    onSelect: (DiscoveredMac) -> Unit
) {
    Column(
        modifier = Modifier
            .fillMaxSize()
            .padding(horizontal = 32.dp),
        horizontalAlignment = Alignment.CenterHorizontally,
        verticalArrangement = Arrangement.Center
    ) {
        Text(
            text = "Choose a Mac",
            color = Color.White,
            fontSize = 26.sp,
            fontWeight = FontWeight.Bold,
            letterSpacing = 0.5.sp
        )
        Spacer(modifier = Modifier.height(8.dp))
        Text(
            text = "Multiple Macs found on your network",
            color = Color.Gray,
            fontSize = 14.sp
        )
        Spacer(modifier = Modifier.height(36.dp))

        macs.forEach { mac ->
            Box(
                modifier = Modifier
                    .fillMaxWidth()
                    .padding(vertical = 6.dp)
                    .clip(RoundedCornerShape(16.dp))
                    .background(Color(0xFF1C1C1E))
                    .border(1.dp, Color.White.copy(alpha = 0.08f), RoundedCornerShape(16.dp))
                    .clickable { onSelect(mac) }
                    .padding(horizontal = 20.dp, vertical = 18.dp)
            ) {
                Column {
                    Text(
                        text = mac.name,
                        color = Color.White,
                        fontSize = 17.sp,
                        fontWeight = FontWeight.SemiBold
                    )
                    if (mac.host.isNotEmpty()) {
                        Spacer(modifier = Modifier.height(4.dp))
                        Text(
                            text = mac.host,
                            color = Color.Gray,
                            fontSize = 13.sp
                        )
                    }
                }
            }
        }
    }
}

@Composable
fun InfoScreen(title: String, subtitle: String) {
    val infiniteTransition = rememberInfiniteTransition(label = "pulse")
    val alpha by infiniteTransition.animateFloat(
        initialValue = 0.3f,
        targetValue = 1f,
        animationSpec = infiniteRepeatable(
            animation = tween(1200, easing = LinearEasing),
            repeatMode = RepeatMode.Reverse
        ),
        label = "pulse"
    )

    Column(
        modifier = Modifier.fillMaxSize(),
        horizontalAlignment = Alignment.CenterHorizontally,
        verticalArrangement = Arrangement.Center
    ) {
        Box(contentAlignment = Alignment.Center) {
            CircularProgressIndicator(
                color = Color.White,
                strokeWidth = 2.dp,
                modifier = Modifier
                    .size(64.dp)
                    .graphicsLayer { this.alpha = alpha }
            )
            Box(
                modifier = Modifier
                    .size(32.dp)
                    .clip(CircleShape)
                    .background(Color.White.copy(alpha = 0.1f))
            )
        }
        Spacer(modifier = Modifier.height(32.dp))
        Text(
            text = title,
            color = Color.White,
            fontSize = 22.sp,
            fontWeight = FontWeight.Bold,
            letterSpacing = 0.5.sp
        )
        if (subtitle.isNotEmpty()) {
            Spacer(modifier = Modifier.height(12.dp))
            Text(
                text = subtitle,
                color = Color.Gray,
                fontSize = 15.sp,
                fontWeight = FontWeight.Normal
            )
        }
    }
}

@Composable
fun SettingsDialog(
    currentName: String,
    currentGridRows: Int,
    onDismiss: () -> Unit,
    onSave: (String, Int) -> Unit,
    onReset: () -> Unit
) {
    var name by remember { mutableStateOf(currentName) }
    var gridRows by remember { mutableStateOf(currentGridRows) }
    var showConfirmReset by remember { mutableStateOf(false) }

    AlertDialog(
        onDismissRequest = onDismiss,
        shape = RoundedCornerShape(28.dp),
        containerColor = Color(0xFF1C1C1E).copy(alpha = 0.7f),
        title = { Text("Settings", fontWeight = FontWeight.Bold, color = Color.White) },
        text = {
            Column(modifier = Modifier.imePadding()) {
                OutlinedTextField(
                    value = name,
                    onValueChange = { name = it },
                    label = { Text("Device Name") },
                    singleLine = true,
                    colors = OutlinedTextFieldDefaults.colors(
                        focusedTextColor = Color.White,
                        unfocusedTextColor = Color.White,
                        focusedBorderColor = Color.White,
                        unfocusedBorderColor = Color.Gray,
                        focusedLabelColor = Color.White,
                        unfocusedLabelColor = Color.Gray
                    ),
                    modifier = Modifier.fillMaxWidth()
                )
                Spacer(modifier = Modifier.height(16.dp))
                Text("Grid Layout", color = Color.Gray, fontSize = 14.sp)
                Spacer(modifier = Modifier.height(8.dp))
                Row(modifier = Modifier.fillMaxWidth(), horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                    listOf(2, 3, 4).forEach { rows ->
                        FilterChip(
                            selected = gridRows == rows,
                            onClick = { gridRows = rows },
                            label = { Text("${rows}x5") },
                            colors = FilterChipDefaults.filterChipColors(
                                selectedContainerColor = Color.White.copy(alpha = 0.2f),
                                selectedLabelColor = Color.White,
                                labelColor = Color.Gray
                            )
                        )
                    }
                }
                Spacer(modifier = Modifier.height(24.dp))
                Button(
                    onClick = { showConfirmReset = true },
                    modifier = Modifier.fillMaxWidth(),
                    shape = RoundedCornerShape(12.dp),
                    colors = ButtonDefaults.buttonColors(containerColor = Color(0xFFFF3B30).copy(alpha = 0.2f), contentColor = Color(0xFFFF453A))
                ) {
                    Text("Reset Pairing", fontWeight = FontWeight.SemiBold)
                }
            }
        },
        confirmButton = {
            TextButton(onClick = { onSave(name, gridRows) }) {
                Text("Save", fontWeight = FontWeight.Bold, color = Color.White)
            }
        },
        dismissButton = {
            TextButton(onClick = onDismiss) {
                Text("Cancel", color = Color.Gray)
            }
        }
    )

    if (showConfirmReset) {
        AlertDialog(
            onDismissRequest = { showConfirmReset = false },
            title = { Text("Confirm Reset") },
            text = { Text("This will break the current pairing and require re-approval on your Mac. Continue?") },
            confirmButton = {
                TextButton(onClick = {
                    onReset()
                    showConfirmReset = false
                }) {
                    Text("Reset", color = MaterialTheme.colorScheme.error)
                }
            },
            dismissButton = {
                TextButton(onClick = { showConfirmReset = false }) {
                    Text("Cancel")
                }
            }
        )
    }
}