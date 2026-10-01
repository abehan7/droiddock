import Foundation
import IOKit
import IOKit.usb

/// Calls back when a Samsung USB device is plugged in or removed.
final class USBWatcher {
    static let samsungVendorID = 0x04E8   // other brands: Google 0x18D1, Xiaomi 0x2717

    private let onAdd: () -> Void
    private let onRemove: () -> Void
    private var port: IONotificationPortRef?
    private var addIterator: io_iterator_t = 0
    private var removeIterator: io_iterator_t = 0

    init(onAdd: @escaping () -> Void, onRemove: @escaping () -> Void) {
        self.onAdd = onAdd
        self.onRemove = onRemove
        port = IONotificationPortCreate(kIOMainPortDefault)
        IONotificationPortSetDispatchQueue(port, .main)
        let context = Unmanaged.passUnretained(self).toOpaque()

        IOServiceAddMatchingNotification(port, kIOFirstMatchNotification, Self.matching(), { context, iterator in
            USBWatcher.drain(iterator)
            guard let context else { return }
            Unmanaged<USBWatcher>.fromOpaque(context).takeUnretainedValue().onAdd()
        }, context, &addIterator)
        Self.drain(addIterator)      // arms the notification; a phone already plugged in is handled at launch

        IOServiceAddMatchingNotification(port, kIOTerminatedNotification, Self.matching(), { context, iterator in
            USBWatcher.drain(iterator)
            guard let context else { return }
            Unmanaged<USBWatcher>.fromOpaque(context).takeUnretainedValue().onRemove()
        }, context, &removeIterator)
        Self.drain(removeIterator)
    }

    deinit {
        IOObjectRelease(addIterator)
        IOObjectRelease(removeIterator)
        if let port { IONotificationPortDestroy(port) }
    }

    private static func matching() -> CFDictionary {
        let dict = IOServiceMatching("IOUSBHostDevice") as NSMutableDictionary
        dict["idVendor"] = samsungVendorID
        return dict as CFDictionary
    }

    /// IOKit only fires again once the iterator has been emptied.
    private static func drain(_ iterator: io_iterator_t) {
        var object = IOIteratorNext(iterator)
        while object != 0 {
            IOObjectRelease(object)
            object = IOIteratorNext(iterator)
        }
    }
}
