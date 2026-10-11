import XCTest
@testable import ThreadingAndroidKit

final class AndroidRecordTests: XCTestCase {
    func testParsesRunningEmulatorDiscovery() throws {
        let record = try XCTUnwrap(RunningEmulatorRecord.parse("""
        emulator.build=15917651
        avd.id=Pixel_8_API_36
        port.serial=5556
        port.adb=5557
        avd.name=Pixel 8 API 36
        grpc.jwks=/tmp/avd/running/9/jwks/abc
        grpc.jwk_active=/tmp/avd/running/9/jwks/abc/active.jwk
        grpc.port=8556
        cmdline="/sdk/emulator/qemu/darwin-aarch64/qemu-system-aarch64-headless" "-avd" "Pixel_8_API_36"
        """, processID: 9))
        XCTAssertEqual(record.avdName, "Pixel_8_API_36", "avd.id is the identifier; avd.name is for display")
        XCTAssertEqual(record.displayName, "Pixel 8 API 36")
        XCTAssertEqual(record.adbSerial, "emulator-5556")
        XCTAssertEqual(record.grpcPort, 8556)
        XCTAssertEqual(record.jwksDirectory?.path, "/tmp/avd/running/9/jwks/abc")
        XCTAssertNil(record.grpcToken)
        XCTAssertNil(RunningEmulatorRecord.parse("avd.name=x", processID: 1), "a record without a console port is not usable")
    }

    func testScanSkipsDeadProcessesAndForeignFiles() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        try "avd.name=A\nport.serial=5554\n".write(to: directory.appendingPathComponent("pid_10.ini"), atomically: true, encoding: .utf8)
        try "avd.name=B\nport.serial=5556\n".write(to: directory.appendingPathComponent("pid_11.ini"), atomically: true, encoding: .utf8)
        try "noise".write(to: directory.appendingPathComponent("README"), atomically: true, encoding: .utf8)
        let records = RunningEmulatorRecord.scan(directory: directory, isAlive: { $0 == 11 })
        XCTAssertEqual(records.map(\.avdName), ["B"])
    }

    func testParsesADBDevicesIncludingUnauthorizedAndOffline() throws {
        let records = try ADBDeviceRecord.parse("""
        * daemon not running; starting now at tcp:5037
        * daemon started successfully
        List of devices attached
        emulator-5554          device product:sdk_phone64_arm64 model:Android_SDK_built_for_arm64 device:emu64a transport_id:11
        R5CT1234ABC            unauthorized usb:1-1 transport_id:12
        0A141FDD4003NN         device usb:2-1 product:husky model:Pixel_8_Pro device:husky transport_id:13
        192.168.1.20:5555      offline transport_id:14

        """)
        XCTAssertEqual(records.map(\.serial), ["emulator-5554", "R5CT1234ABC", "0A141FDD4003NN", "192.168.1.20:5555"])
        XCTAssertEqual(records.map(\.state), [.device, .unauthorized, .device, .offline])
        XCTAssertTrue(records[0].isEmulator)
        XCTAssertTrue(records[2].isUSB)
        XCTAssertEqual(records[2].displayName, "Pixel 8 Pro")
        XCTAssertThrowsError(try ADBDeviceRecord.parse(records.map { "\($0.serial) device" }.joined(separator: "\n"), maximumDevices: 3))
    }

    func testAVDConfigurationReadsAPILevelAndFormFactor() {
        let phone = AVDConfiguration.parse(name: "Pixel_8_API_36", config: """
        avd.ini.displayname=Pixel 8 API 36
        image.sysdir.1=system-images/android-36/google_apis/arm64-v8a/
        hw.lcd.width=1080
        hw.lcd.height=2400
        hw.lcd.density=420
        """)
        XCTAssertEqual(phone.displayName, "Pixel 8 API 36")
        XCTAssertEqual(phone.apiLevel, 36)
        XCTAssertFalse(phone.isTablet)
        let tablet = AVDConfiguration.parse(name: "Tab", config: "image.sysdir.1=system-images/android-35-ext14/google_apis/x86/\nhw.lcd.width=2560\nhw.lcd.height=1600\nhw.lcd.density=320")
        XCTAssertEqual(tablet.apiLevel, 35)
        XCTAssertTrue(tablet.isTablet)
        XCTAssertEqual(tablet.displayName, "Tab")
        XCTAssertEqual(AVDConfiguration.releaseName(apiLevel: 36), "Android 16 · API 36")
        XCTAssertEqual(AVDConfiguration.releaseName(apiLevel: 99), "API 99")
    }

    func testParsesAUIAutomatorDumpAndItsTrailer() throws {
        let xml = """
        <?xml version='1.0' encoding='UTF-8' standalone='yes' ?><hierarchy rotation="0">\
        <node index="0" text="" resource-id="" class="android.widget.FrameLayout" package="com.example" content-desc="" \
        checkable="false" checked="false" clickable="false" enabled="true" focusable="false" focused="false" scrollable="false" \
        long-clickable="false" password="false" selected="false" bounds="[0,0][1080,2400]">\
        <node index="0" text="Sign in" resource-id="com.example:id/sign_in" class="android.widget.Button" package="com.example" \
        content-desc="" checkable="false" checked="false" clickable="true" enabled="true" focusable="true" focused="false" \
        scrollable="false" long-clickable="false" password="false" selected="false" bounds="[100,200][980,344]" />\
        <node index="1" text="" resource-id="com.example:id/email" class="android.widget.EditText" package="com.example" \
        content-desc="Email" checkable="false" checked="false" clickable="true" enabled="false" focusable="true" focused="false" \
        scrollable="false" long-clickable="false" password="false" selected="false" bounds="[100,400][980,544]" />\
        </node></hierarchy>UI hierchary dumped to: /dev/stdout
        """
        let root = try UIAutomatorHierarchy.parse(Data(xml.utf8))
        XCTAssertEqual(root.bounds, .init(x: 0, y: 0, width: 1080, height: 2400))
        let frame = try XCTUnwrap(root.children.first)
        XCTAssertEqual(frame.children.map(\.resourceID), ["com.example:id/sign_in", "com.example:id/email"])
        XCTAssertEqual(frame.children[0].text, "Sign in")
        XCTAssertEqual(frame.children[0].bounds, .init(x: 100, y: 200, width: 880, height: 144))
        XCTAssertTrue(frame.children[0].isInteractive)
        XCTAssertFalse(frame.children[1].isEnabled)
        XCTAssertEqual(frame.children[1].contentDescription, "Email")
    }

    func testBoundsTheHierarchyBeforeBuildingIt() {
        let nodes = String(repeating: #"<node class="v" bounds="[0,0][1,1]" />"#, count: 11)
        XCTAssertThrowsError(try UIAutomatorHierarchy.parse(Data("<hierarchy>\(nodes)</hierarchy>".utf8), maximumNodes: 10)) { error in
            XCTAssertEqual(error as? AndroidRecordError, .hierarchyTooLarge)
        }
        XCTAssertThrowsError(try UIAutomatorHierarchy.parse(Data("ERROR: could not get idle state.".utf8)))
    }
}
