import SwiftUI
import AppKit
import CoreImage.CIFilterBuiltins

/// Finds phones with Wireless debugging on, pairs new ones by QR code (or pairing code),
/// and connects. Polls adb every couple of seconds while the sheet is open.
@MainActor
@Observable
final class WiFiFinder {
    struct Phone: Identifiable, Hashable {
        let id: String
        let name: String
        let detail: String
        let serial: String?     // connected in adb already
        let address: String?    // advertised on the network, not connected yet
    }

    var phones: [Phone] = []
    /// The phone advertises this while its "Pair device with pairing code" screen is open.
    var pairingAddress: String?
    var status = "Looking for phones on this Wi-Fi…"
    var isBusy = false
    let code = ADBPairingCode()
    @ObservationIgnored private var justPaired = false
    @ObservationIgnored private var task: Task<Void, Never>?

    func start(connect: @escaping (String) async -> Void) {
        task?.cancel()
        task = Task {
            while !Task.isCancelled {
                await scan(connect: connect)
                try? await Task.sleep(for: .seconds(2))
            }
        }
    }

    func stop() { task?.cancel() }

    func pair(address: String, code: String, connect: @escaping (String) async -> Void) async {
        isBusy = true
        defer { isBusy = false }
        status = "Pairing…"
        do {
            try await ADB.pair(address.trimmingCharacters(in: .whitespaces), code: code.trimmingCharacters(in: .whitespaces))
            justPaired = true
            status = "Paired. Connecting…"
            await scan(connect: connect)
        } catch {
            status = error.localizedDescription
        }
    }

    func connect(_ phone: Phone, connect: @escaping (String) async -> Void) async {
        isBusy = true
        defer { isBusy = false }
        if let serial = phone.serial { return await connect(serial) }
        guard let address = phone.address else { return }
        status = "Connecting to \(phone.name)…"
        do {
            try await ADB.connect(address)
            await connect(address)
        } catch {
            status = error.localizedDescription
        }
    }

    private func scan(connect: @escaping (String) async -> Void) async {
        let services = await ADB.services()

        // The phone scanned our QR code: it now advertises a pairing service under our name.
        if !isBusy, let pairing = services.first(where: { $0.type.hasPrefix("_adb-tls-pairing") && $0.instance == code.name }) {
            await pair(address: pairing.address, code: code.password, connect: connect)
            return
        }

        pairingAddress = services.first {
            $0.type.hasPrefix("_adb-tls-pairing") && $0.instance != code.name
        }?.address

        let devices = await ADB.devices().filter(\.isWiFi)
        var found = devices.map { device in
            Phone(id: device.serial, name: device.model,
                  detail: device.isReady ? "Paired · ready" : "Waiting for the phone (\(device.state))",
                  serial: device.isReady ? device.serial : nil, address: nil)
        }
        for service in services where service.type.hasPrefix("_adb-tls-connect") {
            let known = devices.contains { $0.serial.hasPrefix(service.instance) || $0.serial == service.address }
            if !known {
                found.append(Phone(id: service.instance, name: service.instance.replacingOccurrences(of: "adb-", with: ""),
                                   detail: service.address, serial: nil, address: service.address))
            }
        }
        phones = found
        if status.hasPrefix("Looking") || status.hasPrefix("No phones") {
            status = found.isEmpty ? "No paired phones on this Wi-Fi yet." : "Choose a phone to connect."
        }

        // Right after pairing, adb connects on its own; take the first phone that's ready.
        if justPaired, let ready = devices.first(where: \.isReady) {
            justPaired = false
            await connect(ready.serial)
        }
    }
}

struct WiFiConnectView: View {
    @Environment(BrowserModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var finder = WiFiFinder()
    @State private var manualAddress = ""
    @State private var manualCode = ""
    @State private var method = PairMethod.code

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack {
                Label("Connect over Wi-Fi", systemImage: "wifi").font(.title2.bold())
                Spacer()
                Button("Done") { dismiss() }.keyboardShortcut(.cancelAction)
            }

            if !ADB.isAvailable {
                ContentUnavailableView {
                    Label("adb isn't installed", systemImage: "wrench.and.screwdriver")
                } description: {
                    Text("Wi-Fi uses Android's adb tool. Install Android Studio, or run\n`brew install --cask android-platform-tools`, then reopen this.")
                }
            } else {
                phonesSection
                Divider()
                pairSection
            }
        }
        .padding(24)
        .frame(width: 560)
        .onAppear { finder.start(connect: connectAndClose) }
        .onDisappear { finder.stop() }
    }

    private var phonesSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Phones on this Wi-Fi").font(.headline)
            if finder.phones.isEmpty {
                Text(finder.status).foregroundStyle(.secondary)
            } else {
                ForEach(finder.phones) { phone in
                    HStack {
                        Image(systemName: "smartphone").foregroundStyle(.tint)
                        VStack(alignment: .leading) {
                            Text(phone.name)
                            Text(phone.detail).font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        Button("Connect") { Task { await finder.connect(phone, connect: connectAndClose) } }
                            .disabled(finder.isBusy || (phone.serial == nil && phone.address == nil))
                    }
                    .padding(10)
                    .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 8))
                }
            }
        }
    }

    private enum PairMethod: String, CaseIterable { case code = "Pairing code", qr = "QR code" }

    private var pairSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Pair a new phone").font(.headline)
                Spacer()
                Picker("Method", selection: $method) {
                    ForEach(PairMethod.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .frame(width: 220)
            }
            step(1, "Put the phone on the same Wi-Fi as this Mac.")
            step(2, "On the phone: Settings › Developer options › Wireless debugging, and turn it on.")
            switch method {
            case .code: codePairing
            case .qr: qrPairing
            }
            HStack(spacing: 6) {
                if finder.isBusy { ProgressView().controlSize(.small) }
                Text(finder.status).font(.callout).foregroundStyle(.secondary)
            }
        }
    }

    private var codePairing: some View {
        VStack(alignment: .leading, spacing: 10) {
            step(3, "Tap “Pair device with pairing code”, then type the 6-digit code here.")
            HStack {
                TextField(finder.pairingAddress ?? "IP address & port shown on the phone", text: $manualAddress)
                    .frame(minWidth: 230)
                TextField("6-digit code", text: $manualCode).frame(width: 120)
                Button("Pair") {
                    let address = manualAddress.isEmpty ? (finder.pairingAddress ?? "") : manualAddress
                    Task { await finder.pair(address: address, code: manualCode, connect: connectAndClose) }
                }
                .keyboardShortcut(.defaultAction)
                .disabled(manualCode.count < 6 || (manualAddress.isEmpty && finder.pairingAddress == nil) || finder.isBusy)
            }
            .textFieldStyle(.roundedBorder)
            if let address = finder.pairingAddress, manualAddress.isEmpty {
                Label("Found the phone at \(address)", systemImage: "checkmark.circle.fill")
                    .font(.callout).foregroundStyle(.green)
            }
        }
    }

    private var qrPairing: some View {
        HStack(alignment: .top, spacing: 18) {
            QRCodeView(text: finder.code.qrPayload)
                .frame(width: 150, height: 150)
            VStack(alignment: .leading, spacing: 8) {
                step(3, "Tap “Pair device with QR code” and scan this with the scanner that opens.")
                Label("Only scan it from Wireless debugging. The Camera app reads it as a Wi-Fi network and drops your Wi-Fi.",
                      systemImage: "exclamationmark.triangle.fill")
                    .font(.callout)
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func step(_ number: Int, _ text: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text("\(number)").font(.callout.bold()).foregroundStyle(.tint)
            Text(text).fixedSize(horizontal: false, vertical: true)
        }
    }

    private func connectAndClose(_ serial: String) async {
        await model.connectWiFi(serial: serial)
        if model.isConnected { dismiss() } else if case .failed(let message) = model.connection {
            finder.status = message
        }
    }
}

struct QRCodeView: View {
    let text: String

    var body: some View {
        if let image = Self.render(text) {
            Image(nsImage: image)
                .interpolation(.none)
                .resizable()
                .padding(8)
                .background(.white, in: RoundedRectangle(cornerRadius: 8))
        }
    }

    private static func render(_ text: String) -> NSImage? {
        let filter = CIFilter.qrCodeGenerator()
        filter.message = Data(text.utf8)
        filter.correctionLevel = "M"
        guard let output = filter.outputImage?.transformed(by: CGAffineTransform(scaleX: 8, y: 8)),
              let cgImage = CIContext().createCGImage(output, from: output.extent) else { return nil }
        return NSImage(cgImage: cgImage, size: NSSize(width: output.extent.width, height: output.extent.height))
    }
}
