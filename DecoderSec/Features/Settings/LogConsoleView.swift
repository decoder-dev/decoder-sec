//
//  LogConsoleView.swift
//  DecoderSec
//
//  In-app console for Packet Tunnel lifecycle logs (IPC).
//  EverywhereCore does not expose full core stdout — these are provider events.
//

import SwiftUI
import UIKit

struct LogConsoleView: View {
    @EnvironmentObject private var tunnel: TunnelManager
    @State private var autoRefresh = true
    @State private var timer: Timer?

    var body: some View {
        VStack(spacing: 0) {
            if tunnel.tunnelLogs.isEmpty {
                ContentUnavailableCompat(
                    title: String(localized: "No logs yet"),
                    subtitle: String(localized: "Tap Connect — app logs appear even if Packet Tunnel fails to launch.")
                )
            } else {
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 4) {
                            ForEach(Array(tunnel.tunnelLogs.enumerated()), id: \.offset) { index, line in
                                Text(line)
                                    .font(.system(.caption2, design: .monospaced))
                                    .foregroundStyle(.primary)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .id(index)
                            }
                        }
                        .padding(12)
                    }
                    .onChange(of: tunnel.tunnelLogs.count) { _ in
                        if let last = tunnel.tunnelLogs.indices.last {
                            withAnimation { proxy.scrollTo(last, anchor: .bottom) }
                        }
                    }
                }
            }
        }
        .background(Color(uiColor: .systemBackground))
        .navigationTitle(String(localized: "Log console"))
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .navigationBarTrailing) {
                Menu {
                    Toggle(String(localized: "Auto-refresh"), isOn: $autoRefresh)
                    Button(String(localized: "Refresh")) { tunnel.refreshLogs() }
                    Button(String(localized: "Clear"), role: .destructive) { tunnel.clearLogs() }
                    if !tunnel.tunnelLogs.isEmpty {
                        Button(String(localized: "Copy all")) {
                            UIPasteboard.general.string = tunnel.tunnelLogs.joined(separator: "\n")
                        }
                    }
                } label: {
                    Image(systemName: "ellipsis.circle")
                }
            }
        }
        .onAppear {
            tunnel.refreshLogs()
            restartTimer()
        }
        .onDisappear {
            timer?.invalidate()
            timer = nil
        }
        .onChange(of: autoRefresh) { _ in
            restartTimer()
        }
    }

    private func restartTimer() {
        timer?.invalidate()
        timer = nil
        guard autoRefresh else { return }
        timer = Timer.scheduledTimer(withTimeInterval: 1.5, repeats: true) { _ in
            tunnel.refreshLogs()
        }
    }
}

/// Lightweight empty state that works on iOS 15 (no ContentUnavailableView).
private struct ContentUnavailableCompat: View {
    let title: String
    let subtitle: String

    var body: some View {
        VStack(spacing: 8) {
            Image(systemName: "text.alignleft")
                .font(.largeTitle)
                .foregroundStyle(.secondary)
            Text(title).font(.headline)
            Text(subtitle)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 24)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
