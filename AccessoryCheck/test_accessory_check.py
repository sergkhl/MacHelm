"""Accessory check behavior using fixture descriptors and a scripted Mac. No macOS command runs."""

import importlib.util
import json
import plistlib
import sys
import tempfile
import unittest
from pathlib import Path


SPEC = importlib.util.spec_from_file_location(
    "accessory_check", Path(__file__).with_name("accessory-check.py")
)
check = importlib.util.module_from_spec(SPEC)
sys.modules[SPEC.name] = check
SPEC.loader.exec_module(check)

# Report descriptors read on 2026-10-14 from a third-party DUALSHOCK 4 copy and QCY H3S headphones,
# both connected by cable.
DS4_COPY = bytes.fromhex(
    "05010905a10185010930093109320935150026ff007508950481020939150025073500463b0165147504950181426500"
    "05091901290e150025017501950e81020600ff0920750695011500257f8102050109330934150026ff00750895028102"
    "0600ff09219536810285050922951f9102850409239524b102850209249524b102850809259503b102851009269504b1"
    "02851109279502b10285120602ff0921950fb102851309229516b10285140605ff09209510b10285150921952cb10206"
    "80ff858009209506b102858109219506b102858209229505b102858309239501b102858409249504b102858509259506"
    "b102858609269506b102858709279523b102858809289522b102858909299502b102859009309505b102859109319503"
    "b102859209329503b10285930933950cb10285a009409506b10285a109419501b10285a209429501b10285a309439530"
    "b10285a40944950db10285a509459515b10285a609469515b10285f00947953fb10285f10948953fb10285f20949950f"
    "b10285a7094a9501b10285a8094b9501b10285a9094c9508b10285aa094e9501b10285ab094f9539b10285ac09509539"
    "b10285ad0951950bb10285ae09529501b10285af09539502b10285b00954953fb10285b109559502b10285b209569502"
    "b10285e009579502b10285b30955953fb10285b40955953fb102c0"
)
QCY_H3S = bytes.fromhex(
    "050c0901a1018501150025017501950209e909ea810209cf09cd8102950c8101850409007508952691028505090095228102c0"
)
BOOT_KEYBOARD = bytes.fromhex(
    "05010906a101050719e029e71500250175019508810295017508810195057501050819012905910295017503910195067508"
    "150025650507190029658100c0"
)
BOOT_MOUSE = bytes.fromhex(
    "05010902a1010901a100050919012903150025019503750181029501750581010501093009311581257f750895028106c0c0"
)
GAMEPAD_WITH_KEYS = bytes.fromhex(
    "05010905a10109300931150026ff007508950281020507190029651500256575089501810005090901150025017501950181"
    "02750795018101c0"
)
PAGE_AFTER_USAGE = bytes.fromhex("05010905a1010904050715002565750895018100c0")
KEYS_OUTSIDE_COLLECTION = bytes.fromhex("05071900296515002565750895018100")
TOUCH_SCREEN = bytes.fromhex("050d0904a101094215002501750195018102750795018101c0")
APP_LAUNCH = bytes.fromhex("050c0901a1010a960115002501750195018102750795018101c0")


def levels(findings, level):
    return [text for found, text in findings if found == level]


def usb_device(rid=1, interfaces=((1, 1, 0), (1, 2, 0), (1, 2, 0), (3, 0, 0)), product="Wireless Controller",
               vid=0x054C, pid=0x09CC, location=0x01100000):
    return {"id": rid, "vid": vid, "pid": pid, "product": product, "vendor": "Sony Interactive Entertainment",
            "serial": None, "location": location, "speed": 1, "version": 0x100,
            "interfaces": [{"number": n, "class": c, "subclass": s, "protocol": p, "name": None, "drivers": []}
                           for n, (c, s, p) in enumerate(interfaces)],
            "opened_by": []}


def hid_device(rid=11, descriptor=DS4_COPY, product="Wireless Controller", transport="USB",
               vid=0x054C, pid=0x09CC, location=0x01100000):
    return {"id": rid, "class": "AppleUserHIDDevice", "transport": transport, "vid": vid, "pid": pid,
            "product": product, "manufacturer": "Sony Interactive Entertainment", "location": location,
            "built_in": False, "descriptor": descriptor.hex()}


def snapshot(usb=(), hid=(), volumes=(), interfaces=("lo0", "en0"), keyboard_setup=False, audio=(),
             bluetooth=None, ports=()):
    return {"usb": list(usb), "hid": list(hid),
            "network": {"interfaces": list(interfaces), "hardware_ports": []},
            "storage": {"volumes": list(volumes), "external_disks": []}, "audio": list(audio),
            "bluetooth": bluetooth or {"state": "on", "connected": [], "not_connected": []},
            "ports": list(ports), "keyboard_setup": keyboard_setup,
            "system_extensions": "0 extension(s)", "kexts": []}


def state(usb=None, hid=None, volumes=(), pending=False):
    return {"usb": dict(usb or {}), "hid": dict(hid or {}), "volumes": list(volumes),
            "network": ["lo0", "en0"], "keyboard_setup": False,
            "ports": [{"port": "Port-USB-C@2", "pending": pending, "status": "No Action"}]}


def service(product="Wireless Controller", page=1, usage=5, transport="USB"):
    return {"product": product, "page": page, "usage": usage, "transport": transport, "built_in": False}


PAD = "Wireless Controller@17825792"


class FakeMac:
    """Hands out scripted states and snapshots, repeating the last of each."""

    def __init__(self, states, snapshots, run_output=b""):
        self.states, self.snapshots, self.run_output = list(states), list(snapshots), run_output
        self.calls = []

    def quick(self):
        self.calls.append("quick")
        return self.states.pop(0) if len(self.states) > 1 else self.states[0]

    def snapshot(self):
        self.calls.append("snapshot")
        return self.snapshots.pop(0) if len(self.snapshots) > 1 else self.snapshots[0]

    def run(self, command):
        return self.run_output


class FakeClock:
    def __init__(self):
        self.seconds = 0.0

    def now(self):
        return self.seconds

    def sleep(self, seconds):
        self.seconds += seconds


def run_watch(mac, **options):
    output, clock = [], FakeClock()
    settings = {"wait_s": 30, "observe_s": 20, "emit": output.append, "sleep": clock.sleep,
                "now": clock.now, "clock": lambda: "12:00:00"}
    settings.update(options)
    code = check.watch(mac, **settings)
    return code, "\n".join(output)


class DescriptorTests(unittest.TestCase):
    def test_ds4_copy_declares_only_a_gamepad(self):
        lines, findings = check.explain_descriptor(DS4_COPY)
        self.assertEqual(findings, [])
        self.assertEqual(lines, ["Game Pad: sends Button, Generic Desktop, Vendor 0xFF00; "
                                 "data channel 54 B in, 63 B out"])

    def test_qcy_headphones_declare_buttons_and_a_data_channel(self):
        lines, findings = check.explain_descriptor(QCY_H3S)
        self.assertEqual(findings, [])
        self.assertEqual(lines, ["Consumer Control: sends Consumer; buttons Play/Pause, Voice Command, "
                                 "Volume Up, Volume Down; data channel 34 B in, 38 B out"])

    def test_keyboards_are_flagged_wherever_their_keys_are_declared(self):
        for name, descriptor in (("boot keyboard", BOOT_KEYBOARD), ("gamepad", GAMEPAD_WITH_KEYS),
                                 ("late usage page", PAGE_AFTER_USAGE),
                                 ("no collection", KEYS_OUTSIDE_COLLECTION)):
            with self.subTest(name):
                _, findings = check.explain_descriptor(descriptor)
                self.assertTrue(any("can type keys" in text for text in levels(findings, check.RED)))

    def test_fields_outside_a_collection_are_noted(self):
        _, findings = check.explain_descriptor(KEYS_OUTSIDE_COLLECTION)
        self.assertIn("the report descriptor has fields outside any collection", levels(findings, check.NOTE))

    def test_mice_and_touch_screens_can_move_the_pointer(self):
        for descriptor in (BOOT_MOUSE, TOUCH_SCREEN):
            _, findings = check.explain_descriptor(descriptor)
            self.assertTrue(any("move the pointer" in text for text in levels(findings, check.RED)))

    def test_app_launch_keys_are_a_note(self):
        _, findings = check.explain_descriptor(APP_LAUNCH)
        self.assertEqual(levels(findings, check.RED), [])
        self.assertIn("Consumer Control can send app-launch and browser keys", levels(findings, check.NOTE))

    def test_truncated_descriptor_is_reported_instead_of_raising(self):
        _, findings = check.explain_descriptor(DS4_COPY[:9])
        self.assertTrue(any("malformed report descriptor" in text for text in levels(findings, check.NOTE)))


class ParsingTests(unittest.TestCase):
    def test_interfaces_are_not_counted_as_devices(self):
        interfaces = [{"IOObjectClass": "IOUSBHostInterface", "IORegistryEntryID": 10 + n, "idVendor": 0x054C,
                       "idProduct": 0x09CC, "bInterfaceNumber": n, "bInterfaceClass": c, "bInterfaceSubClass": s,
                       "bInterfaceProtocol": 0,
                       "IORegistryEntryChildren": [{"IOObjectClass": "AppleUserHIDDevice"}] if c == 3 else []}
                      for n, (c, s) in enumerate(((1, 1), (1, 2), (1, 2), (3, 0)))]
        device = {"IOObjectClass": "IOUSBHostDevice", "IORegistryEntryID": 1, "idVendor": 0x054C,
                  "idProduct": 0x09CC, "USB Product Name": "Wireless Controller", "locationID": 0x01100000,
                  "IORegistryEntryChildren": [{"IOObjectClass": "AppleUSBHostCompositeDevice", "bDeviceClass": 0},
                                              *interfaces,
                                              {"IOObjectClass": "AppleUSBHostDeviceUserClient",
                                               "IORegistryEntryName": "Google Chrome"}]}
        devices = check.parse_usb_devices(plistlib.dumps([device]))
        self.assertEqual(len(devices), 1)
        self.assertEqual([i["class"] for i in devices[0]["interfaces"]], [1, 1, 1, 3])
        self.assertEqual(devices[0]["interfaces"][3]["drivers"], ["AppleUserHIDDevice"])
        self.assertEqual(devices[0]["opened_by"], ["Google Chrome"])

    def test_devices_behind_a_hub_are_found(self):
        inner = {"IOObjectClass": "IOUSBHostDevice", "IORegistryEntryID": 2, "USB Product Name": "Pad"}
        hub = {"IOObjectClass": "IOUSBHostDevice", "IORegistryEntryID": 1, "USB Product Name": "Hub",
               "IORegistryEntryChildren": [{"IOObjectClass": "AppleUSB20Hub", "IORegistryEntryChildren": [inner]}]}
        self.assertEqual([d["product"] for d in check.parse_usb_devices(plistlib.dumps([hub]))], ["Hub", "Pad"])

    def test_hidutil_services(self):
        text = (
            "Services:\n"
            "VendorID ProductID LocationID UsagePage Usage RegistryID  Transport Class    Product    UserClass Built-In \n"
            "0x0      0x0       0x2d       1         6     0x100000b01 FIFO      AppleHIDKeyboardEventDriverV2 "
            "Apple Internal Keyboard / Trackpad (null) 1\n"
            "0x3654   0x4a55    0x100000   12        1     0x100021edf USB       AppleUserHIDEventService "
            "QCY H3S AppleUserHIDEventDriver 0\n"
            "Devices:\n"
            "VendorID ProductID LocationID UsagePage Usage RegistryID  Transport Class Product UserClass Built-In\n"
            "0x0      0x0       0x2d       1         2     0x100000b0c FIFO      AppleHIDTransportHIDDevice X (null) 1\n"
        )
        rows = check.parse_hid_services(text)
        self.assertEqual([(r["product"], r["page"], r["usage"], r["built_in"]) for r in rows],
                         [("Apple Internal Keyboard / Trackpad", 1, 6, True), ("QCY H3S", 12, 1, False)])

    def test_ports_report_a_pending_approval(self):
        data = plistlib.dumps([{"IORegistryEntryName": "Port-USB-C", "IORegistryEntryLocation": "2",
                                "UserAuthorizationPending": True, "UserAuthorizationStatusDescription": "No Action"},
                               {"IORegistryEntryName": "CC", "AuthorizationStatusDescription": "Not Required"}])
        self.assertEqual(check.parse_ports(data), [{"port": "Port-USB-C@2", "pending": True, "status": "No Action"}])

    def test_bluetooth_off_and_paired_devices(self):
        off = json.dumps({"SPBluetoothDataType": [{"controller_properties": {"controller_state": "attrib_off"}}]})
        self.assertEqual(check.parse_bluetooth(off.encode())["state"], "off")
        on = json.dumps({"SPBluetoothDataType": [{
            "controller_properties": {"controller_state": "attrib_on"},
            "device_not_connected": [{"DUALSHOCK 4 Wireless Controller": {
                "device_address": "49:96:80:A0:9C:BE", "device_minorType": "Gamepad"}}]}]})
        found = check.parse_bluetooth(on.encode())
        self.assertEqual(found["not_connected"][0]["kind"], "Gamepad")

    def test_registered_bluetooth_prefixes(self):
        self.assertFalse(check.address_registered("49:96:80:A0:9C:BE"))
        self.assertTrue(check.address_registered("04:A8:5A:DB:48:57"))
        self.assertIsNone(check.address_registered("NULL"))

    def test_device_names_cannot_send_terminal_escapes(self):
        self.assertEqual(check.clean("Pad\x1b[2J"), "Pad\\x1b[2J")
        self.assertEqual(len(check.clean("x" * 200)), 80)

    def test_vpn_interfaces_are_left_out(self):
        self.assertEqual(check.without_vpn(["lo0", "en0", "utun4", "ipsec0", "en7"]), ["lo0", "en0", "en7"])


class CompareTests(unittest.TestCase):
    def test_gamepad_with_a_sound_card_has_no_flags(self):
        lines, findings = check.compare(snapshot(), snapshot(usb=[usb_device()], hid=[hid_device()]))
        self.assertEqual(findings, [])
        self.assertIn("     interface 3: HID", lines)
        self.assertIn("     interface 0: audio control", lines)

    def test_drives_and_network_adapters_are_red(self):
        storage = usb_device(interfaces=((8, 6, 0x50), (2, 6, 0)), product="Stick")
        _, findings = check.compare(snapshot(), snapshot(usb=[storage], volumes=["STICK"],
                                                         interfaces=("lo0", "en0", "en9")))
        reds = levels(findings, check.RED)
        self.assertIn("Stick: interface 0 is mass storage (a drive)", reds)
        self.assertIn("Stick: interface 1 is Ethernet adapter (CDC ECM)", reds)
        self.assertIn("volume added: STICK", reds)
        self.assertIn("network interface added: en9", reds)

    def test_a_device_reconnecting_unchanged_is_not_new(self):
        before = snapshot(usb=[usb_device(rid=1)], hid=[hid_device(rid=11)])
        after = snapshot(usb=[usb_device(rid=2)], hid=[hid_device(rid=12)])
        lines, findings = check.compare(before, after)
        self.assertEqual(findings, [])
        self.assertIn('USB  "Wireless Controller" by "Sony Interactive Entertainment" reconnected as the same device',
                      lines)
        self.assertIn('HID  "Wireless Controller" reconnected with the same descriptor', lines)

    def test_a_device_returning_as_a_keyboard_is_flagged(self):
        before = snapshot(usb=[usb_device(rid=1)], hid=[hid_device(rid=11)])
        after = snapshot(usb=[usb_device(rid=2, interfaces=((3, 0, 0), (3, 1, 1)))],
                         hid=[hid_device(rid=12, descriptor=BOOT_KEYBOARD)])
        _, findings = check.compare(before, after)
        self.assertIn("Wireless Controller reconnected with different interfaces", levels(findings, check.NOTE))
        self.assertIn("Wireless Controller: interface 1 is HID boot keyboard", levels(findings, check.RED))
        self.assertIn("Wireless Controller: Keyboard can type keys like a keyboard", levels(findings, check.RED))

    def test_keyboard_setup_assistant_is_red(self):
        _, findings = check.compare(snapshot(), snapshot(keyboard_setup=True))
        self.assertTrue(levels(findings, check.RED))

    def test_bluetooth_address_outside_registered_prefixes_is_noted(self):
        copy = {"name": "DUALSHOCK 4", "address": "49:96:80:A0:9C:BE", "kind": "Gamepad"}
        genuine = {"name": "Mic", "address": "04:A8:5A:DB:48:57", "kind": "Headset"}
        _, findings = check.compare(snapshot(), snapshot(bluetooth={"state": "on", "connected": [copy, genuine],
                                                                    "not_connected": []}))
        self.assertEqual(levels(findings, check.NOTE),
                         ["DUALSHOCK 4: Bluetooth address isn't from a registered manufacturer prefix"])

    def test_audio_device_and_default_switch(self):
        speakers = {"name": "MacBook Pro Speakers", "outputs": 2, "default_output": True}
        headset = {"name": "QCY H3S", "inputs": 1, "default_output": False}
        lines, _ = check.compare(snapshot(audio=[speakers]),
                                 snapshot(audio=[dict(speakers, default_output=False),
                                                 dict(headset, default_output=True)]))
        self.assertIn('Audio  "QCY H3S": input 1 ch (microphone)', lines)
        self.assertIn('macOS switched the default output to "QCY H3S"', lines)


class WatchTests(unittest.TestCase):
    def test_times_out_when_nothing_arrives(self):
        code, output = run_watch(FakeMac([state()], [snapshot()]))
        self.assertEqual(code, 3)
        self.assertIn("No new accessory appeared within 30 s.", output)

    def test_unplugging_a_device_does_not_count_as_an_arrival(self):
        code, _ = run_watch(FakeMac([state(usb={PAD: [1, 4]}), state()], [snapshot()]))
        self.assertEqual(code, 3)

    def test_clean_accessory(self):
        arrived = state(usb={PAD: [1, 4]}, hid={"0x11": service()})
        device = snapshot(usb=[usb_device()], hid=[hid_device()])
        code, output = run_watch(FakeMac([state(), state(), arrived], [snapshot(), device]))
        self.assertEqual(code, 0)
        self.assertIn('Detected USB device "Wireless Controller"', output)
        self.assertIn("== Connected ==", output)
        self.assertTrue(output.endswith("0 red flag(s), 0 note(s)."))

    def test_keyboard_accessory_returns_one(self):
        arrived = state(usb={PAD: [1, 1]}, hid={"0x11": service(page=1, usage=6)})
        device = snapshot(usb=[usb_device(interfaces=((3, 1, 1),))], hid=[hid_device(descriptor=BOOT_KEYBOARD)])
        code, output = run_watch(FakeMac([state(), arrived], [snapshot(), device]))
        self.assertEqual(code, 1)
        self.assertIn("RED   Wireless Controller registered a keyboard with macOS.", output)

    def test_short_lived_keyboard_service_is_caught(self):
        arrived = state(usb={PAD: [1, 4]}, hid={"0x11": service()})
        flash = state(usb={PAD: [1, 4]}, hid={"0x11": service(), "0x99": service("Pad", page=1, usage=6)})
        device = snapshot(usb=[usb_device()], hid=[hid_device()])
        states = [state(), arrived] + [arrived] * 8 + [flash] + [arrived] * 3
        code, output = run_watch(FakeMac(states, [snapshot(), device]))
        self.assertEqual(code, 1)
        self.assertIn("RED   Pad registered a keyboard with macOS", output)

    def test_report_waits_for_approval_and_interfaces(self):
        listed = state(usb={PAD: [1, 0]}, pending=True)
        approved = state(usb={PAD: [1, 4]}, hid={"0x11": service()})
        mac = FakeMac([state(), listed, listed, listed, approved],
                      [snapshot(), snapshot(usb=[usb_device()], hid=[hid_device()])])
        code, output = run_watch(mac)
        self.assertEqual(code, 0)
        self.assertIn("macOS is asking whether to allow the accessory.", output)
        connected = mac.calls.index("snapshot", mac.calls.index("snapshot") + 1)
        self.assertGreater(connected, mac.calls.index("snapshot") + 4)

    def test_out_folder_keeps_snapshots_and_report(self):
        arrived = state(usb={PAD: [1, 4]})
        with tempfile.TemporaryDirectory() as folder:
            run_watch(FakeMac([state(), arrived], [snapshot(), snapshot(usb=[usb_device()])]), out=Path(folder))
            names = sorted(p.name for p in Path(folder).iterdir())
        self.assertEqual(names, ["after.json", "before.json", "final.json", "report.txt"])


class CommandTests(unittest.TestCase):
    def run_main(self, argv, mac=None):
        output = []
        code = check.main(argv, probe=mac or FakeMac([state()], [snapshot()]), emit=output.append)
        return code, "\n".join(output)

    def test_decode(self):
        code, output = self.run_main(["decode", BOOT_KEYBOARD.hex()])
        self.assertEqual(code, 1)
        self.assertIn("RED   Keyboard can type keys like a keyboard", output)
        self.assertEqual(self.run_main(["decode", "not hex"])[0], 2)

    def test_paired_marks_unregistered_addresses(self):
        bluetooth = json.dumps({"SPBluetoothDataType": [{
            "controller_properties": {"controller_state": "attrib_on"},
            "device_not_connected": [
                {"DUALSHOCK 4 Wireless Controller": {"device_address": "49:96:80:A0:9C:BE"}},
                {"DJI Mic": {"device_address": "04:A8:5A:DB:48:57"}}]}]}).encode()
        _, output = self.run_main(["paired"], FakeMac([state()], [snapshot()], run_output=bluetooth))
        self.assertIn("49:96:80:A0:9C:BE    not connected  <- not a registered manufacturer prefix", output)
        self.assertIn("04:A8:5A:DB:48:57    not connected\n", output)

    def test_snapshot_and_diff(self):
        with tempfile.TemporaryDirectory() as folder:
            first, second = Path(folder, "a.json"), Path(folder, "b.json")
            self.run_main(["snapshot", str(first)])
            self.run_main(["snapshot", str(second)], FakeMac([state()], [snapshot(volumes=["STICK"])]))
            code, output = self.run_main(["diff", str(first), str(second)])
        self.assertEqual(code, 1)
        self.assertIn("RED   volume added: STICK", output)


if __name__ == "__main__":
    unittest.main()
