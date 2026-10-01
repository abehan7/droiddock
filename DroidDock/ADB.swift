import Foundation

/// Runs Android's `adb` tool (from Android Studio or `brew install --cask android-platform-tools`)
/// and handles finding, pairing and connecting phones.
enum ADB {
    static let path: String? = {
        var candidates: [String] = []
        if let bundled = Bundle.main.url(forAuxiliaryExecutable: "adb")?.path { candidates.append(bundled) }
        candidates += [
            NSHomeDirectory() + "/Library/Android/sdk/platform-tools/adb",
            "/opt/homebrew/bin/adb",
            "/usr/local/bin/adb",
        ]
        return candidates.first { FileManager.default.isExecutableFile(atPath: $0) }
    }()

    static var isAvailable: Bool { path != nil }

    struct Output {
        let data: Data
        let error: String
        let status: Int32
        var text: String { String(decoding: data, as: UTF8.self) }
    }

    /// Runs adb off the main thread. Doesn't throw on a non-zero exit; callers decide.
    static func run(_ arguments: [String]) async throws -> Output {
        guard let path else {
            throw MTPError.failed("adb isn't installed. Install Android Studio, or run: brew install --cask android-platform-tools")
        }
        return try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                let process = Process()
                process.executableURL = URL(fileURLWithPath: path)
                process.arguments = arguments
                let out = Pipe(), err = Pipe()
                process.standardOutput = out
                process.standardError = err
                process.standardInput = FileHandle.nullDevice
                do { try process.run() } catch { return continuation.resume(throwing: error) }
                // Drain both pipes at once, or a chatty stderr can stall the process.
                var errorData = Data()
                let group = DispatchGroup()
                group.enter()
                DispatchQueue.global().async {
                    errorData = err.fileHandleForReading.readDataToEndOfFile()
                    group.leave()
                }
                let data = out.fileHandleForReading.readDataToEndOfFile()
                group.wait()
                process.waitUntilExit()
                continuation.resume(returning: Output(
                    data: data,
                    error: String(decoding: errorData, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines),
                    status: process.terminationStatus))
            }
        }
    }

    // MARK: Devices

    struct Device: Hashable, Identifiable {
        let serial: String
        let state: String     // "device", "unauthorized", "offline"
        let model: String
        var id: String { serial }
        /// Wi-Fi serials are "ip:port" or an mDNS name; USB serials are the phone's serial number.
        var isWiFi: Bool { serial.contains(":") || serial.contains("._adb-tls-connect.") }
        var isReady: Bool { state == "device" }
    }

    static func devices() async -> [Device] {
        guard let output = try? await run(["devices", "-l"]) else { return [] }
        return output.text.split(separator: "\n").dropFirst().compactMap { line in
            let parts = line.split(separator: " ", omittingEmptySubsequences: true)
            guard parts.count >= 2 else { return nil }
            let model = parts.first { $0.hasPrefix("model:") }.map { String($0.dropFirst(6)).replacingOccurrences(of: "_", with: " ") }
            return Device(serial: String(parts[0]), state: String(parts[1]), model: model ?? "Android phone")
        }
    }

    // MARK: Wi-Fi discovery (mDNS)

    struct Service: Hashable {
        let instance: String   // "adb-R3CW502QKHK-8d5yNz", or the name from our pairing QR code
        let type: String       // "_adb-tls-connect._tcp" or "_adb-tls-pairing._tcp"
        let address: String    // "192.168.0.17:41365"
    }

    /// Phones on this network with Wireless debugging on (paired ones advertise "connect").
    static func services() async -> [Service] {
        guard let output = try? await run(["mdns", "services"]) else { return [] }
        return output.text.split(separator: "\n").compactMap { line in
            let parts = line.split(separator: "\t").map { $0.trimmingCharacters(in: .whitespaces) }
            guard parts.count >= 3 else { return nil }
            return Service(instance: parts[0], type: parts[1], address: parts[2])
        }
    }

    static func connect(_ address: String) async throws {
        let output = try await run(["connect", address])
        if output.text.contains("failed") || output.text.contains("cannot") || output.status != 0 {
            throw MTPError.failed(output.text.isEmpty ? output.error : output.text)
        }
    }

    static func pair(_ address: String, code: String) async throws {
        let output = try await run(["pair", address, code])
        guard output.text.contains("Successfully paired") else {
            let reason = [output.text, output.error].joined(separator: " ").trimmingCharacters(in: .whitespacesAndNewlines)
            throw MTPError.failed(reason.isEmpty ? "Pairing failed." : reason)
        }
    }
}

/// QR pairing, like Android Studio: the phone scans `WIFI:T:ADB;S:<name>;P:<password>;;`,
/// starts advertising a pairing service under <name>, and we pair with <password>.
struct ADBPairingCode {
    let name = "DroidDock-" + String(UUID().uuidString.prefix(6))
    let password = String(format: "%06d", Int.random(in: 0...999_999))
    var qrPayload: String { "WIFI:T:ADB;S:\(name);P:\(password);;" }
}
