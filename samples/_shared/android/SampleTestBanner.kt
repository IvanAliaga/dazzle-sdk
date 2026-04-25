// Copyright 2026 Ivan Aliaga <ivan.aliaga@urp.edu.pe>
//
// Licensed under the Apache License, Version 2.0 (the "License");
// you may not use this file except in compliance with the License.
//
// Top-of-screen banner for the visible sample-test mode. Mirrors
// `SampleTestBanner` in the Flutter + RN samples so the cross-platform
// run looks consistent on device.

package dev.dazzle.samples.shared

import androidx.compose.foundation.background
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.CheckCircle
import androidx.compose.material.icons.filled.Error
import androidx.compose.material.icons.filled.HourglassTop
import androidx.compose.material.icons.filled.PlayArrow
import androidx.compose.material3.Icon
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.vector.ImageVector
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp

@Composable
fun SampleTestBanner(phase: String, detail: String?) {
    val (bg, label, icon) = when (phase) {
        "preparing" -> Triple(
            Color(0xFF1E3A8A),
            "DEV SMOKE · scripted (no real LLM) · preparing",
            Icons.Filled.HourglassTop,
        )
        "running" -> Triple(
            Color(0xFF1E3A8A),
            "DEV SMOKE · scripted (no real LLM) · tap icon for Qwen",
            Icons.Filled.PlayArrow,
        )
        "completed" -> Triple(
            Color(0xFF166534),
            "DEV SMOKE · complete · app icon = real Qwen",
            Icons.Filled.CheckCircle,
        )
        "failed" -> Triple(
            Color(0xFF7F1D1D),
            "DEV SMOKE · failed",
            Icons.Filled.Error,
        )
        else -> Triple(
            Color(0xFF1E3A8A),
            phase,
            Icons.Filled.PlayArrow,
        )
    }

    Row(
        Modifier
            .fillMaxWidth()
            .background(bg)
            .padding(horizontal = 12.dp, vertical = 10.dp),
        horizontalArrangement = Arrangement.Center,
        verticalAlignment = Alignment.CenterVertically,
    ) {
        Icon(icon, contentDescription = null, tint = Color.White)
        Text(
            text = if (detail == null) label else "$label  —  $detail",
            color = Color.White,
            fontWeight = FontWeight.SemiBold,
            modifier = Modifier.padding(start = 8.dp),
        )
    }
}
