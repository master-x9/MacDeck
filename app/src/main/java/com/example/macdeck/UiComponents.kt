package com.example.macdeck

import androidx.compose.animation.core.*
import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.clickable
import androidx.compose.foundation.interaction.MutableInteractionSource
import androidx.compose.foundation.interaction.collectIsPressedAsState
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.filled.*
import androidx.compose.material.icons.filled.*
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Brush
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.graphicsLayer
import androidx.compose.ui.layout.ContentScale
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import coil.ImageLoader
import coil.compose.AsyncImage
import coil.decode.GifDecoder
import coil.decode.ImageDecoderDecoder
import kotlinx.coroutines.delay

@Composable
fun GridTile(
    tile: DeckTile?,
    onClick: () -> Unit,
    modifier: Modifier = Modifier,
    index: Int = 0
) {
    var visible by remember { mutableStateOf(false) }
    val interactionSource = remember { MutableInteractionSource() }
    val isPressed by interactionSource.collectIsPressedAsState()

    val pressScale by animateFloatAsState(
        targetValue = if (isPressed) 0.92f else 1f,
        animationSpec = spring(dampingRatio = Spring.DampingRatioMediumBouncy, stiffness = Spring.StiffnessLow),
        label = "pressScale"
    )

    val entryAlpha by animateFloatAsState(
        targetValue = if (visible) 1f else 0f,
        animationSpec = tween(durationMillis = 300, easing = LinearOutSlowInEasing),
        label = "entryAlpha"
    )

    val entryScale by animateFloatAsState(
        targetValue = if (visible) 1f else 0.8f,
        animationSpec = spring(dampingRatio = Spring.DampingRatioLowBouncy, stiffness = Spring.StiffnessLow),
        label = "entryScale"
    )

    LaunchedEffect(Unit) {
        delay(index * 30L)
        visible = true
    }

    val gradientBrush = remember {
        Brush.linearGradient(
            colors = listOf(
                Color.White.copy(alpha = 0.2f),
                Color.White.copy(alpha = 0.05f)
            )
        )
    }

    val borderBrush = remember {
        Brush.linearGradient(
            colors = listOf(
                Color.White.copy(alpha = 0.5f),
                Color.White.copy(alpha = 0.1f)
            )
        )
    }

    Box(
        modifier = modifier.fillMaxSize(),
        contentAlignment = Alignment.Center
    ) {
        Box(
            modifier = Modifier
                .fillMaxSize()
                .aspectRatio(1f)
                .graphicsLayer {
                    alpha = entryAlpha
                    scaleX = entryScale * pressScale
                    scaleY = entryScale * pressScale
                    shadowElevation = 16.dp.toPx()
                    shape = RoundedCornerShape(28.dp)
                    clip = true
                }
                .background(gradientBrush)
                .border(
                    width = 1.dp,
                    brush = borderBrush,
                    shape = RoundedCornerShape(28.dp)
                )
                .clickable(
                    enabled = tile != null,
                    onClick = onClick,
                    interactionSource = interactionSource,
                    indication = null
                ),
            contentAlignment = Alignment.Center
        ) {
        if (tile != null) {
            val context = LocalContext.current
            val imageLoader = remember {
                ImageLoader.Builder(context)
                    .components {
                        if (android.os.Build.VERSION.SDK_INT >= 28) {
                            add(ImageDecoderDecoder.Factory())
                        } else {
                            add(GifDecoder.Factory())
                        }
                    }
                    .build()
            }

            if (tile.iconData != null) {
                AsyncImage(
                    model = remember(tile.iconData) {
                        val data = tile.iconData
                        val cleanData = if (data.contains(",")) data.substringAfter(",") else data
                        android.util.Base64.decode(cleanData, android.util.Base64.DEFAULT)
                    },
                    imageLoader = imageLoader,
                    contentDescription = tile.customLabel ?: tile.tileType.defaultLabel(),
                    modifier = Modifier
                        .padding(12.dp)
                        .fillMaxSize()
                        .clip(RoundedCornerShape(12.dp)),
                    contentScale = ContentScale.Fit
                )
            } else {
                Icon(
                    imageVector = when (tile.tileType) {
                        is WebsiteTile -> Icons.Default.Language
                        is AppTile -> Icons.Default.Apps
                        is ShortcutTile -> Icons.Default.Bolt
                        is SystemControlTile -> {
                            val action = (tile.tileType as SystemControlTile).action
                            when (action) {
                                "brightnessDown" -> Icons.Default.BrightnessLow
                                "brightnessUp" -> Icons.Default.BrightnessHigh
                                "volumeDown" -> Icons.AutoMirrored.Filled.VolumeDown
                                "volumeUp" -> Icons.AutoMirrored.Filled.VolumeUp
                                "kbBrightnessDown" -> Icons.Default.Keyboard
                                "kbBrightnessUp" -> Icons.Default.Keyboard
                                "playPause" -> Icons.Default.PlayArrow
                                "unlockMac" -> Icons.Default.Lock
                                else -> Icons.Default.Settings
                            }
                        }
                        is BrowserControlTile -> {
                            val action = (tile.tileType as BrowserControlTile).action
                            when (action) {
                                "back" -> Icons.AutoMirrored.Filled.ArrowBack
                                "forward" -> Icons.AutoMirrored.Filled.ArrowForward
                                "refresh" -> Icons.Default.Refresh
                                "home" -> Icons.Default.Home
                                "newTab" -> Icons.Default.Add
                                "closeTab" -> Icons.Default.Close
                                else -> Icons.Default.Language
                            }
                        }
                    },
                    contentDescription = null,
                    modifier = Modifier
                        .padding(16.dp)
                        .padding(bottom = 14.dp) // Leave room for label
                        .fillMaxSize(),
                    tint = Color.White.copy(alpha = 0.9f)
                )

                // Added label at the bottom of the tile
                Text(
                    text = tile.customLabel ?: tile.tileType.defaultLabel(),
                    color = Color.White.copy(alpha = 0.6f),
                    fontSize = 10.sp,
                    fontWeight = FontWeight.Medium,
                    maxLines = 1,
                    modifier = Modifier
                        .align(Alignment.BottomCenter)
                        .padding(bottom = 10.dp)
                )
            }
        } else {
            Icon(
                imageVector = Icons.Default.Add,
                contentDescription = "Empty Tile",
                tint = Color.White.copy(alpha = 0.15f),
                modifier = Modifier.size(32.dp)
            )
        }
    }
}
}

@Composable
fun FullScreenGrid(
    page: DeckPage,
    onTileClick: (Int) -> Unit,
    modifier: Modifier = Modifier,
    gridRows: Int = 2
) {
    Box(
        modifier = modifier.fillMaxSize()
    ) {
        Column(
            modifier = Modifier
                .align(Alignment.Center)
                .padding(horizontal = 16.dp, vertical = 12.dp),
            verticalArrangement = Arrangement.spacedBy(16.dp)
        ) {
            repeat(gridRows) { row ->
                Row(
                    modifier = Modifier.weight(1f),
                    horizontalArrangement = Arrangement.spacedBy(16.dp)
                ) {
                    repeat(5) { col ->
                        val index = row * 5 + col
                        val tile = page.tiles.getOrNull(index)
                        key(index) {
                            GridTile(
                                tile = tile,
                                onClick = { onTileClick(index) },
                                modifier = Modifier.weight(1f),
                                index = index
                            )
                        }
                    }
                }
            }
        }
    }
}


@Composable
fun StatusOverlay(
    text: String,
    modifier: Modifier = Modifier
) {
    Box(
        modifier = modifier
            .fillMaxSize()
            .padding(bottom = 80.dp),
        contentAlignment = Alignment.BottomCenter
    ) {
        Surface(
            color = Color(0xFFFFCC00),
            shape = RoundedCornerShape(20.dp),
            shadowElevation = 4.dp
        ) {
            Text(
                text = text,
                color = Color.Black,
                fontSize = 13.sp,
                fontWeight = FontWeight.Bold,
                modifier = Modifier.padding(horizontal = 16.dp, vertical = 8.dp)
            )
        }
    }
}