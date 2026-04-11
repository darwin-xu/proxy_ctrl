//
//  ContentView.swift
//  proxy_ctrl
//
//  Created by Darwin Xu on 2026/4/10.
//

import SwiftUI

// MARK: - Menu

struct ProxyMenuView: View {
    @EnvironmentObject var proxy: ProxyManager

    var body: some View {
        Toggle("http", isOn: Binding(
            get: { proxy.currentMode == .http },
            set: { if $0 { proxy.applyHTTP() } }
        ))
        Toggle("socks", isOn: Binding(
            get: { proxy.currentMode == .socks },
            set: { if $0 { proxy.applySOCKS() } }
        ))
        Toggle("tun", isOn: .constant(false))
            .disabled(true)
        Toggle("direct", isOn: Binding(
            get: { proxy.currentMode == .direct },
            set: { if $0 { proxy.applyDirect() } }
        ))

        if let err = proxy.lastError {
            Divider()
            Text("⚠️ \(err)")
                .foregroundColor(.red)
        }

        Divider()

        Button("Settings…") {
            // Small delay lets the status menu finish dismissing before
            // the panel appears, avoiding a visual overlap.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
                SettingsWindowController.shared.showSettings()
            }
        }
    }
}

// MARK: - Settings

struct SettingsView: View {
    @AppStorage("networkService") private var networkService = "Wi-Fi"
    @AppStorage("httpHost")       private var httpHost       = "192.168.2.223"
    @AppStorage("httpPort")       private var httpPort       = "8899"
    @AppStorage("socksHost")      private var socksHost      = "192.168.2.201"
    @AppStorage("socksPort")      private var socksPort      = "7788"

    var body: some View {
        Form {
            Section("Network") {
                LabeledContent("Service") {
                    TextField("e.g. Wi-Fi", text: $networkService)
                        .textFieldStyle(.roundedBorder)
                        .frame(maxWidth: 200)
                }
            }
            Section("HTTP/HTTPS Proxy") {
                LabeledContent("Host") {
                    TextField("host", text: $httpHost)
                        .textFieldStyle(.roundedBorder)
                        .frame(maxWidth: 200)
                }
                LabeledContent("Port") {
                    TextField("port", text: $httpPort)
                        .textFieldStyle(.roundedBorder)
                        .frame(maxWidth: 80)
                }
            }
            Section("SOCKS Proxy") {
                LabeledContent("Host") {
                    TextField("host", text: $socksHost)
                        .textFieldStyle(.roundedBorder)
                        .frame(maxWidth: 200)
                }
                LabeledContent("Port") {
                    TextField("port", text: $socksPort)
                        .textFieldStyle(.roundedBorder)
                        .frame(maxWidth: 80)
                }
            }
        }
        .formStyle(.grouped)
        .frame(width: 400)
        .padding(.vertical)
    }
}
