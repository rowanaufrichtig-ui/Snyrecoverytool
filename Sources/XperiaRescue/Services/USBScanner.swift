import Foundation
import IOKit
import XperiaRescueCore

/// Lists USB devices through IOKit. Cheap enough to poll every second.
enum USBScanner {
    static func scan() -> [USBDeviceSnapshot] {
        var devices: [USBDeviceSnapshot] = []
        guard let matching = IOServiceMatching("IOUSBHostDevice") else { return devices }
        var iterator: io_iterator_t = 0
        guard IOServiceGetMatchingServices(kIOMainPortDefault, matching, &iterator) == KERN_SUCCESS else {
            return devices
        }
        defer { IOObjectRelease(iterator) }

        var service = IOIteratorNext(iterator)
        while service != 0 {
            if let vendor = number(service, "idVendor"), let product = number(service, "idProduct") {
                devices.append(USBDeviceSnapshot(
                    vendorID: vendor,
                    productID: product,
                    productName: string(service, "USB Product Name") ?? string(service, "kUSBProductString"),
                    serialNumber: string(service, "USB Serial Number") ?? string(service, "kUSBSerialNumberString")
                ))
            }
            IOObjectRelease(service)
            service = IOIteratorNext(iterator)
        }
        return devices
    }

    private static func property(_ service: io_service_t, _ key: String) -> CFTypeRef? {
        IORegistryEntryCreateCFProperty(service, key as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue()
    }

    private static func number(_ service: io_service_t, _ key: String) -> Int? {
        (property(service, key) as? NSNumber)?.intValue
    }

    private static func string(_ service: io_service_t, _ key: String) -> String? {
        property(service, key) as? String
    }
}
