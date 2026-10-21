#!/usr/bin/env python3
"""Report what a newly connected accessory tells macOS it is.

An accessory introduces itself. Over USB it lists its functions as interfaces; a HID interface, or
a Bluetooth HID device, adds a report descriptor naming each kind of input it can send. macOS acts
on what it is told: a game controller whose descriptor also names keyboard keys can type, and
headphones that also present a network adapter or a drive get one. `watch` records this Mac's
devices, waits for the next accessory, and reports every function the accessory declared, flagging
the ones that can type, move the pointer, carry network traffic, or hold files. It then keeps
watching, because a device can drop off the bus and return as something else.

It cannot inspect firmware. Names, IDs, and descriptors are the device's own claims, and a device
can behave normally while watched and change later. A clean report means the accessory declared
nothing beyond its stated purpose during the check. The script only reads state; it never changes a
setting or answers macOS's accessory prompt.

Standard library only. It runs `ioreg`, `hidutil`, `system_profiler`, `ifconfig`, `networksetup`,
`diskutil`, `pgrep`, `systemextensionsctl`, and `kmutil`.
"""

from __future__ import annotations

import argparse
import json
import os
import plistlib
import subprocess
import sys
import time
from datetime import datetime
from pathlib import Path
from typing import Callable, Optional

RED, NOTE = "RED", "NOTE"
VPN_PREFIXES = ("utun", "ipsec", "ppp", "gif", "stf")
QUIET_PORT_STATES = (None, "", "No Action", "Not Required")
SPEEDS = {0: "low speed", 1: "full speed", 2: "high speed", 3: "SuperSpeed", 4: "SuperSpeed+"}

PAGES = {
    0x01: "Generic Desktop", 0x02: "Simulation", 0x06: "Generic Device", 0x07: "Keyboard",
    0x08: "LED", 0x09: "Button", 0x0B: "Telephony", 0x0C: "Consumer", 0x0D: "Digitizer",
    0x0F: "Force Feedback", 0x20: "Sensor", 0x84: "Power", 0x85: "Battery",
}
DESKTOP_COLLECTIONS = {
    0x01: "Pointer", 0x02: "Mouse", 0x04: "Joystick", 0x05: "Game Pad", 0x06: "Keyboard",
    0x07: "Keypad", 0x08: "Multi-axis Controller", 0x80: "System Control",
}
DIGITIZER_COLLECTIONS = {0x01: "Digitizer", 0x02: "Pen", 0x04: "Touch Screen", 0x05: "Touch Pad"}
CONSUMER_NAMES = {
    0x30: "Power", 0x32: "Sleep", 0x40: "Menu", 0xB0: "Play", 0xB1: "Pause", 0xB3: "Fast Forward",
    0xB4: "Rewind", 0xB5: "Next Track", 0xB6: "Previous Track", 0xB7: "Stop", 0xCD: "Play/Pause",
    0xCF: "Voice Command", 0xE2: "Mute", 0xE9: "Volume Up", 0xEA: "Volume Down",
    0x18A: "Mail", 0x192: "Calculator", 0x194: "File Browser", 0x196: "Web Browser",
    0x221: "Search", 0x223: "Home", 0x224: "Back", 0x225: "Forward", 0x227: "Refresh",
}
APP_LAUNCH_FIRST = 0x180  # Consumer AL/AC usages: launch apps, browser actions
KEYBOARD_COLLECTIONS = {(0x01, 0x06), (0x01, 0x07)}
POINTER_COLLECTIONS = {(0x01, 0x01), (0x01, 0x02)} | {(0x0D, u) for u in DIGITIZER_COLLECTIONS}
SERVICE_KINDS = {(0x01, 0x06): "keyboard", (0x01, 0x07): "keypad", (0x01, 0x02): "mouse",
                 (0x01, 0x01): "pointer"}


# ---------- reading this Mac ----------

def run_command(command: list[str], timeout: int = 90) -> bytes:
    try:
        return subprocess.run(command, capture_output=True, timeout=timeout).stdout
    except (OSError, subprocess.SubprocessError):
        return b""


def clean(value: object, limit: int = 80) -> str:
    """Printable form of a device-supplied string, so a name cannot drive the terminal."""
    text = "" if value is None else str(value)
    text = "".join(c if c.isprintable() else f"\\x{ord(c):02x}" for c in text)
    return text if len(text) <= limit else text[:limit - 1] + "…"


def plist_roots(data: bytes) -> list:
    if not data.strip():
        return []
    try:
        value = plistlib.loads(data)
    except Exception:
        return []
    return value if isinstance(value, list) else [value]


def children(node: dict) -> list:
    return node.get("IORegistryEntryChildren") or []


def descendant_classes(node: dict, depth: int = 3) -> list[str]:
    found = []
    for child in children(node):
        found.append(child.get("IOObjectClass", "?"))
        if depth > 1:
            found.extend(descendant_classes(child, depth - 1))
    return found


def parse_usb_devices(data: bytes) -> list[dict]:
    """Devices from `ioreg -a -r -l -c IOUSBHostDevice`.

    Interface objects repeat the device's vendor and product IDs, so only IOUSBHostDevice objects
    count as devices; a hub's downstream devices are found by walking its subtree.
    """
    devices, seen = [], set()

    def visit(node: dict) -> None:
        rid = node.get("IORegistryEntryID")
        if node.get("IOObjectClass") == "IOUSBHostDevice" and rid not in seen:
            seen.add(rid)
            devices.append({
                "id": rid,
                "vid": node.get("idVendor"),
                "pid": node.get("idProduct"),
                "product": node.get("USB Product Name") or node.get("kUSBProductString"),
                "vendor": node.get("USB Vendor Name") or node.get("kUSBVendorString"),
                "serial": node.get("USB Serial Number") or node.get("kUSBSerialNumberString"),
                "location": node.get("locationID"),
                "speed": node.get("USBSpeed", node.get("Device Speed")),
                "version": node.get("bcdDevice"),
                "interfaces": [{
                    "number": child.get("bInterfaceNumber"),
                    "class": child.get("bInterfaceClass"),
                    "subclass": child.get("bInterfaceSubClass"),
                    "protocol": child.get("bInterfaceProtocol"),
                    "name": child.get("kUSBString") or child.get("USB Interface Name"),
                    "drivers": sorted(set(descendant_classes(child))),
                } for child in children(node) if "bInterfaceClass" in child],
                "opened_by": sorted({child.get("IORegistryEntryName", "?") for child in children(node)
                                     if child.get("IOObjectClass") == "AppleUSBHostDeviceUserClient"}),
            })
        for child in children(node):
            visit(child)

    for root in plist_roots(data):
        visit(root)
    return devices


def parse_hid_devices(data: bytes) -> list[dict]:
    """Devices from `ioreg -a -r -l -c IOHIDDevice`, with their report descriptors."""
    devices = []
    for node in plist_roots(data):
        descriptor = node.get("ReportDescriptor")
        devices.append({
            "id": node.get("IORegistryEntryID"),
            "class": node.get("IOObjectClass"),
            "transport": node.get("Transport"),
            "vid": node.get("VendorID"),
            "pid": node.get("ProductID"),
            "product": node.get("Product"),
            "manufacturer": node.get("Manufacturer"),
            "location": node.get("LocationID"),
            "built_in": bool(node.get("Built-In")),
            "descriptor": descriptor.hex() if isinstance(descriptor, (bytes, bytearray)) else None,
        })
    return devices


def parse_hid_services(text: str) -> list[dict]:
    """Rows of the Services table printed by `hidutil list`."""
    rows, in_table = [], False
    for line in text.splitlines():
        if line.startswith("Devices:"):
            break
        if line.startswith("VendorID"):
            in_table = True
            continue
        fields = line.split()
        if not in_table or len(fields) < 9:
            continue
        try:
            page, usage = int(fields[3], 0), int(fields[4], 0)
        except ValueError:
            continue
        rows.append({"id": fields[5], "vid": fields[0], "pid": fields[1], "page": page, "usage": usage,
                     "transport": fields[6], "product": " ".join(fields[8:-2]) or None,
                     "built_in": fields[-1] == "1"})
    return rows


def parse_ports(data: bytes) -> list[dict]:
    """Accessory approval state of each USB-C port, from `ioreg -a -r -l -c IOPort`.

    These properties are undocumented; when they are missing the check simply reports less.
    """
    ports = []
    for node in plist_roots(data):
        if "UserAuthorizationStatusDescription" not in node:
            continue
        location = node.get("IORegistryEntryLocation")
        name = node.get("IORegistryEntryName") or "port"
        ports.append({"port": f"{name}@{location}" if location else name,
                      "pending": bool(node.get("UserAuthorizationPending")),
                      "status": node.get("UserAuthorizationStatusDescription")})
    return ports


def parse_audio(data: bytes) -> list[dict]:
    try:
        groups = json.loads(data).get("SPAudioDataType", [])
    except (ValueError, AttributeError):
        return []
    return [{"name": item.get("_name"),
             "inputs": item.get("coreaudio_device_input"),
             "outputs": item.get("coreaudio_device_output"),
             "transport": item.get("coreaudio_device_transport"),
             "default_input": item.get("coreaudio_default_audio_input_device") == "spaudio_yes",
             "default_output": item.get("coreaudio_default_audio_output_device") == "spaudio_yes"}
            for group in groups for item in group.get("_items", [])]


def parse_bluetooth(data: bytes) -> dict:
    found = {"state": None, "connected": [], "not_connected": []}
    try:
        groups = json.loads(data).get("SPBluetoothDataType", [])
    except (ValueError, AttributeError):
        return found
    for group in groups:
        state = (group.get("controller_properties") or {}).get("controller_state") or ""
        if state:
            found["state"] = state.replace("attrib_", "")
        for key, target in (("device_connected", "connected"), ("device_not_connected", "not_connected")):
            for entry in group.get(key) or []:
                for name, props in entry.items():
                    found[target].append({"name": name, "address": props.get("device_address"),
                                          "kind": props.get("device_minorType"),
                                          "vid": props.get("device_vendorID"),
                                          "pid": props.get("device_productID")})
    return found


def parse_external_disks(data: bytes) -> list[str]:
    roots = plist_roots(data)
    return list(roots[0].get("WholeDisks", [])) if roots and isinstance(roots[0], dict) else []


def parse_hardware_ports(text: str) -> list[str]:
    ports, current = [], None
    for line in text.splitlines():
        if line.startswith("Hardware Port:"):
            current = line.split(":", 1)[1].strip()
        elif line.startswith("Device:") and current:
            ports.append(f"{current} ({line.split(':', 1)[1].strip()})")
    return ports


def without_vpn(interfaces: list[str]) -> list[str]:
    return [name for name in interfaces if not name.startswith(VPN_PREFIXES)]


class MacProbe:
    """Reads this Mac's device state. Tests substitute a scripted probe."""

    def __init__(self, run: Callable[[list[str]], bytes] = run_command):
        self.run = run

    def text(self, *command: str) -> str:
        return self.run(list(command)).decode("utf-8", "replace")

    def volumes(self) -> list[str]:
        try:
            return sorted(os.listdir("/Volumes"))
        except OSError:
            return []

    def keyboard_setup_open(self) -> bool:
        return bool(self.run(["pgrep", "-x", "KeyboardSetupAssistant"]).strip())

    def quick(self) -> dict:
        """The cheap state polled every second while waiting and watching."""
        usb = {f"{device['product']}@{device['location']}": [device["id"], len(device["interfaces"])]
               for device in parse_usb_devices(self.run(["ioreg", "-a", "-r", "-l", "-c", "IOUSBHostDevice"]))}
        services = {row["id"]: row for row in parse_hid_services(self.text("hidutil", "list"))
                    if not row["built_in"]}
        return {"usb": usb, "hid": services, "volumes": self.volumes(),
                "network": without_vpn(self.text("ifconfig", "-l").split()),
                "keyboard_setup": self.keyboard_setup_open(),
                "ports": parse_ports(self.run(["ioreg", "-a", "-r", "-l", "-c", "IOPort"]))}

    def snapshot(self) -> dict:
        extensions = self.text("systemextensionsctl", "list").splitlines()
        kexts = [line.strip() for line in self.text("kmutil", "showloaded", "--list-only").splitlines()
                 if line.strip() and "com.apple" not in line and "falling back" not in line]
        return {
            "taken_at": datetime.now().isoformat(timespec="seconds"),
            "usb": parse_usb_devices(self.run(["ioreg", "-a", "-r", "-l", "-c", "IOUSBHostDevice"])),
            "hid": parse_hid_devices(self.run(["ioreg", "-a", "-r", "-l", "-c", "IOHIDDevice"])),
            "network": {"interfaces": without_vpn(self.text("ifconfig", "-l").split()),
                        "hardware_ports": parse_hardware_ports(self.text("networksetup", "-listallhardwareports"))},
            "storage": {"volumes": self.volumes(),
                        "external_disks": parse_external_disks(self.run(["diskutil", "list", "-plist", "external"]))},
            "audio": parse_audio(self.run(["system_profiler", "-json", "SPAudioDataType"])),
            "bluetooth": parse_bluetooth(self.run(["system_profiler", "-json", "SPBluetoothDataType"])),
            "ports": parse_ports(self.run(["ioreg", "-a", "-r", "-l", "-c", "IOPort"])),
            "keyboard_setup": self.keyboard_setup_open(),
            "system_extensions": extensions[0] if extensions else "",
            "kexts": kexts,
        }


# ---------- HID report descriptors ----------

def new_collection(page: Optional[int], usage: Optional[int]) -> dict:
    return {"page": page, "usage": usage, "in": set(), "out": set(), "keys": False, "pointer": False,
            "system": False, "consumer": set(), "ranges": [], "data_in": 0, "data_out": 0}


def decode_report_descriptor(descriptor: bytes) -> tuple[list[dict], list[str]]:
    """Top-level collections of a HID report descriptor and what their fields can send.

    A short Usage takes the Usage Page in force when it is declared; the page in force at the
    Main item is added too, because parsers differ there and a check should take the wider reading.
    Fields outside any collection get a collection of their own rather than being skipped.
    """
    collections, errors = [], []
    state = {"page": 0, "size": 0, "count": 0}
    stack: list[dict] = []
    usages: list[tuple[int, int]] = []
    low = high = None
    short_form = False
    depth, i = 0, 0
    while i < len(descriptor):
        prefix = descriptor[i]
        if prefix == 0xFE:  # long item: prefix, data size, tag, data
            if i + 2 >= len(descriptor):
                errors.append("truncated long item")
                break
            i += 3 + descriptor[i + 1]
            continue
        size = (0, 1, 2, 4)[prefix & 3]
        kind, tag = (prefix >> 2) & 3, prefix >> 4
        if i + 1 + size > len(descriptor):
            errors.append("truncated item")
            break
        value = int.from_bytes(descriptor[i + 1:i + 1 + size], "little")
        i += 1 + size
        if kind == 1:  # Global
            if tag == 0x0:
                state["page"] = value
            elif tag == 0x7:
                state["size"] = value
            elif tag == 0x9:
                state["count"] = value
            elif tag == 0xA:
                stack.append(dict(state))
            elif tag == 0xB and stack:
                state = stack.pop()
        elif kind == 2:  # Local
            usage = (value >> 16, value & 0xFFFF) if size == 4 else (state["page"], value)
            short_form = short_form or size < 4
            if tag == 0x0:
                usages.append(usage)
            elif tag == 0x1:
                low = usage
            elif tag == 0x2:
                high = usage
        elif kind == 0:  # Main
            if tag == 0xA:
                if depth == 0:
                    first = usages[0] if usages else (state["page"], 0)
                    collections.append(new_collection(*first))
                depth += 1
            elif tag == 0xC:
                depth = max(0, depth - 1)
            elif tag in (0x8, 0x9, 0xB) and not value & 1:  # Input, Output, Feature; not padding
                if depth == 0:
                    collections.append(new_collection(None, None))
                record_field(collections[-1], tag, value, usages, low, high, short_form, state)
            usages, low, high, short_form = [], None, None, False
    return collections, errors


def record_field(collection: dict, tag: int, flags: int, usages: list, low, high,
                 short_form: bool, state: dict) -> None:
    pages = {page for page, _ in usages}
    if low:
        pages.add(low[0])
    if short_form or not pages:
        pages.add(state["page"])
    direction = "in" if tag == 0x8 else "out"
    collection[direction] |= pages
    if tag == 0x8:
        if 0x07 in pages:
            collection["keys"] = True
        if flags & 0x04 and any(page == 0x01 and usage in (0x30, 0x31, 0x38) for page, usage in usages):
            collection["pointer"] = True  # relative X, Y, or wheel
        for page, usage in usages:
            if page == 0x0C:
                collection["consumer"].add(usage)
            if page == 0x01 and 0x81 <= usage <= 0x83:
                collection["system"] = True
        if low and high and low[0] == 0x0C:
            collection["ranges"].append((low[1], high[1]))
        if low and high and low[0] == 0x01 and low[1] <= 0x83 and high[1] >= 0x81:
            collection["system"] = True
    data_bytes = state["size"] * state["count"] // 8
    if data_bytes >= 8 and (any(page >= 0xFF00 for page in pages) or any(u == 0 for _, u in usages)):
        key = "data_in" if tag == 0x8 else "data_out"
        collection[key] = max(collection[key], data_bytes)


def page_name(page: int) -> str:
    return f"Vendor 0x{page:04X}" if page >= 0xFF00 else PAGES.get(page, f"page 0x{page:02X}")


def collection_label(page: Optional[int], usage: Optional[int]) -> str:
    if page is None:
        return "Fields outside any collection"
    if page == 0x01:
        return DESKTOP_COLLECTIONS.get(usage, f"Generic Desktop 0x{usage:02X}")
    if page == 0x0C and usage == 0x01:
        return "Consumer Control"
    if page == 0x0D:
        return DIGITIZER_COLLECTIONS.get(usage, f"Digitizer 0x{usage:02X}")
    return f"{page_name(page)} 0x{usage:02X}"


def describe_collection(collection: dict) -> tuple[str, list[tuple[str, str]]]:
    label = collection_label(collection["page"], collection["usage"])
    parts = []
    if collection["in"]:
        parts.append("sends " + ", ".join(sorted(page_name(p) for p in collection["in"])))
    named = [CONSUMER_NAMES[u] for u in sorted(collection["consumer"]) if u in CONSUMER_NAMES]
    if named:
        parts.append("buttons " + ", ".join(named))
    if collection["data_in"] or collection["data_out"]:
        parts.append(f"data channel {collection['data_in']} B in, {collection['data_out']} B out")
    findings = []
    key = (collection["page"], collection["usage"])
    if collection["keys"] or key in KEYBOARD_COLLECTIONS:
        findings.append((RED, f"{label} can type keys like a keyboard"))
    if collection["pointer"] or key in POINTER_COLLECTIONS:
        findings.append((RED, f"{label} can move the pointer and click"))
    if collection["system"] or key == (0x01, 0x80):
        findings.append((NOTE, f"{label} can send power and sleep keys"))
    if (any(u >= APP_LAUNCH_FIRST for u in collection["consumer"])
            or any(top >= APP_LAUNCH_FIRST for _, top in collection["ranges"])):
        findings.append((NOTE, f"{label} can send app-launch and browser keys"))
    if collection["page"] is None:
        findings.append((NOTE, "the report descriptor has fields outside any collection"))
    return f"{label}: " + ("; ".join(parts) if parts else "no input fields"), findings


# ---------- comparing snapshots ----------

def hex_id(value: object) -> str:
    return f"{value:04x}" if isinstance(value, int) else "?"


def ids(device: dict) -> str:
    if device.get("vid") is None and device.get("pid") is None:
        return ""
    return f"{hex_id(device.get('vid'))}:{hex_id(device.get('pid'))}"


def describe_interface(cls: object, subclass: object, protocol: object) -> tuple[str, Optional[str]]:
    """Label and flag level for a USB interface's class triple."""
    if cls == 0x01:
        return {1: "audio control", 2: "audio streaming", 3: "MIDI"}.get(subclass, "audio"), None
    if cls == 0x03:
        if subclass == 1 and protocol == 1:
            return "HID boot keyboard", RED
        if subclass == 1 and protocol == 2:
            return "HID boot mouse", RED
        return "HID", None
    if cls == 0x02:
        return {0x02: "serial port or modem (CDC ACM)", 0x06: "Ethernet adapter (CDC ECM)",
                0x0D: "Ethernet adapter (CDC NCM)", 0x0E: "mobile broadband (CDC MBIM)"}.get(
            subclass, "communications (CDC)"), RED
    if cls == 0x0A:
        return "communications data (CDC)", RED
    if cls == 0x08:
        return "mass storage (a drive)", RED
    if (cls, subclass, protocol) in ((0xE0, 1, 3), (0xEF, 4, 1)):
        return "network adapter (RNDIS)", RED
    if (cls, subclass, protocol) == (0xE0, 1, 1):
        return "Bluetooth radio", NOTE
    notes = {0x06: "still-image camera", 0x07: "printer", 0x09: "USB hub inside the device",
             0x0B: "smart card reader", 0x0E: "video camera", 0x10: "audio/video",
             0xE0: "wireless controller", 0xFE: "firmware update or test interface",
             0xFF: "vendor-specific"}
    if cls in notes:
        return notes[cls], NOTE
    if cls == 0xEF:
        return "miscellaneous", None
    return (f"class 0x{cls:02X}" if isinstance(cls, int) else "unknown class"), NOTE


def usb_title(device: dict) -> str:
    return f"\"{clean(device.get('product'))}\" by \"{clean(device.get('vendor'))}\""


def describe_usb(device: dict, findings: list) -> list[str]:
    first = f"USB  {usb_title(device)}  {ids(device)}  {SPEEDS.get(device.get('speed'), 'unknown speed')}"
    if device.get("serial"):
        first += f"  serial {clean(device['serial'])}"
    lines = [first]
    if not device.get("interfaces"):
        lines.append("     no interfaces yet: still waiting for approval, or not allowed to exchange data")
    for interface in sorted(device.get("interfaces", []),
                            key=lambda i: (i.get("number") is None, i.get("number") or 0)):
        label, level = describe_interface(interface["class"], interface["subclass"], interface["protocol"])
        name = f" (\"{clean(interface['name'])}\")" if interface.get("name") else ""
        lines.append(f"     interface {interface.get('number')}: {label}{name}")
        if level:
            findings.append((level, f"{clean(device.get('product'))}: interface {interface.get('number')} is {label}"))
    if device.get("opened_by"):
        lines.append("     opened over USB by: " + ", ".join(clean(app) for app in device["opened_by"]))
    return lines


def explain_descriptor(descriptor: bytes, owner: str = "") -> tuple[list[str], list[tuple[str, str]]]:
    """One line per top-level collection, and findings prefixed with the owner's name."""
    prefix = f"{owner}: " if owner else ""
    lines, findings = [], []
    collections, errors = decode_report_descriptor(descriptor)
    for collection in collections:
        summary, found = describe_collection(collection)
        lines.append(summary)
        findings.extend((level, prefix + text) for level, text in found)
    if errors:
        findings.append((NOTE, f"{prefix}malformed report descriptor ({'; '.join(errors)}), "
                               "so this check may have missed fields"))
    return lines, findings


def describe_hid(device: dict) -> tuple[list[str], list[tuple[str, str]]]:
    product = clean(device.get("product"))
    if device.get("class") == "AppleGCSyntheticDevice":
        lines = [f"HID  \"{product}\": the virtual controller macOS adds for a supported game controller"]
    else:
        lines = [f"HID  \"{product}\" by \"{clean(device.get('manufacturer'))}\" over "
                 f"{clean(device.get('transport') or 'no transport')}  {ids(device)}".rstrip()]
    if not device.get("descriptor"):
        return lines + ["     no report descriptor visible"], []
    summaries, findings = explain_descriptor(bytes.fromhex(device["descriptor"]), product)
    return lines + ["     " + summary for summary in summaries], findings


def usb_identity(device: dict) -> tuple:
    return device.get("vid"), device.get("pid"), device.get("location")


def usb_shape(device: dict) -> tuple:
    return (device.get("product"), device.get("vendor"), device.get("version"),
            tuple((i.get("number"), i.get("class"), i.get("subclass"), i.get("protocol"))
                  for i in device.get("interfaces", [])))


def hid_identity(device: dict) -> tuple:
    return (device.get("class"), device.get("transport"), device.get("vid"), device.get("pid"),
            device.get("product"), device.get("location"))


def address_registered(address: object) -> Optional[bool]:
    """Whether a Bluetooth address can start with an IEEE-assigned company prefix.

    Assigned prefixes leave the two lowest bits of the first byte clear. None when unreadable.
    """
    try:
        first = int(str(address).split(":")[0].split("-")[0], 16)
    except ValueError:
        return None
    return first & 0x03 == 0


def changed_items(label: str, before: list, after: list, level: Optional[str],
                  lines: list, findings: list) -> None:
    for item in sorted(set(after) - set(before)):
        lines.append(f"{label} added: {clean(item)}")
        if level:
            findings.append((level, f"{label} added: {clean(item)}"))
    for item in sorted(set(before) - set(after)):
        lines.append(f"{label} removed: {clean(item)}")


def compare(before: dict, after: dict) -> tuple[list[str], list[tuple[str, str]]]:
    """Describe what changed between two snapshots, with RED and NOTE findings."""
    lines: list[str] = []
    findings: list[tuple[str, str]] = []

    old = {d["id"]: d for d in before.get("usb", [])}
    new = {d["id"]: d for d in after.get("usb", [])}
    gone = [old[i] for i in old if i not in new]
    for device in (new[i] for i in new if i not in old):
        twin = next((g for g in gone if usb_identity(g) == usb_identity(device)), None)
        if twin is not None:
            gone.remove(twin)
            if usb_shape(twin) == usb_shape(device):
                lines.append(f"USB  {usb_title(device)} reconnected as the same device")
                continue
            findings.append((NOTE, f"{clean(device.get('product'))} reconnected with different interfaces"))
        lines.extend(describe_usb(device, findings))
    lines.extend(f"USB  {usb_title(device)} disconnected" for device in gone)

    old_hid = {d["id"]: d for d in before.get("hid", [])}
    new_hid = {d["id"]: d for d in after.get("hid", [])}
    gone_hid = [old_hid[i] for i in old_hid if i not in new_hid]
    for device in (new_hid[i] for i in new_hid if i not in old_hid):
        twin = next((g for g in gone_hid if hid_identity(g) == hid_identity(device)), None)
        if twin is not None:
            gone_hid.remove(twin)
            if twin.get("descriptor") == device.get("descriptor"):
                lines.append(f"HID  \"{clean(device.get('product'))}\" reconnected with the same descriptor")
                continue
            findings.append((NOTE, f"{clean(device.get('product'))} reconnected with a different HID descriptor"))
        hid_lines, hid_findings = describe_hid(device)
        lines.extend(hid_lines)
        findings.extend(hid_findings)
    lines.extend(f"HID  \"{clean(device.get('product'))}\" disconnected" for device in gone_hid)

    old_ports = {p["port"]: p for p in before.get("ports", [])}
    for port in after.get("ports", []):
        earlier = old_ports.get(port["port"], {})
        if port.get("pending"):
            lines.append(f"macOS is still asking whether to allow the accessory on {clean(port['port'])}")
        elif port.get("status") != earlier.get("status") and port.get("status") not in QUIET_PORT_STATES:
            lines.append(f"macOS accessory approval on {clean(port['port'])}: {clean(port['status'])}")

    network_before, network_after = before.get("network", {}), after.get("network", {})
    changed_items("network interface", network_before.get("interfaces", []),
                  network_after.get("interfaces", []), RED, lines, findings)
    changed_items("network adapter", network_before.get("hardware_ports", []),
                  network_after.get("hardware_ports", []), RED, lines, findings)
    storage_before, storage_after = before.get("storage", {}), after.get("storage", {})
    changed_items("volume", storage_before.get("volumes", []), storage_after.get("volumes", []),
                  RED, lines, findings)
    changed_items("external disk", storage_before.get("external_disks", []),
                  storage_after.get("external_disks", []), RED, lines, findings)

    if after.get("keyboard_setup") and not before.get("keyboard_setup"):
        lines.append("Keyboard Setup Assistant opened")
        findings.append((RED, "Keyboard Setup Assistant opened: macOS saw a keyboard it doesn't recognise"))
    if after.get("system_extensions") != before.get("system_extensions"):
        lines.append(f"system extensions now: {clean(after.get('system_extensions'))}")
        findings.append((RED, "system extensions changed during the check"))
    changed_items("non-Apple kernel extension", before.get("kexts", []), after.get("kexts", []),
                  RED, lines, findings)

    def audio_key(device: dict) -> tuple:
        return device.get("name"), device.get("inputs"), device.get("outputs"), device.get("transport")

    old_audio = {audio_key(d) for d in before.get("audio", [])}
    for device in after.get("audio", []):
        if audio_key(device) not in old_audio:
            channels = []
            if device.get("outputs"):
                channels.append(f"output {device['outputs']} ch")
            if device.get("inputs"):
                channels.append(f"input {device['inputs']} ch (microphone)")
            lines.append(f"Audio  \"{clean(device.get('name'))}\": {', '.join(channels) or 'no channels'}")
    for kind in ("output", "input"):
        was = next((d.get("name") for d in before.get("audio", []) if d.get(f"default_{kind}")), None)
        now = next((d.get("name") for d in after.get("audio", []) if d.get(f"default_{kind}")), None)
        if now and now != was:
            lines.append(f"macOS switched the default {kind} to \"{clean(now)}\"")

    bluetooth_before, bluetooth_after = before.get("bluetooth", {}), after.get("bluetooth", {})
    if bluetooth_after.get("state") and bluetooth_after.get("state") != bluetooth_before.get("state"):
        lines.append(f"Bluetooth switched {clean(bluetooth_after['state'])}")
    known = {d.get("address") for d in bluetooth_before.get("connected", [])}
    for device in bluetooth_after.get("connected", []):
        if device.get("address") in known:
            continue
        lines.append(f"Bluetooth  \"{clean(device.get('name'))}\" connected  {clean(device.get('address'))}"
                     f"  {clean(device.get('kind') or '')}".rstrip())
        if address_registered(device.get("address")) is False:
            findings.append((NOTE, f"{clean(device.get('name'))}: Bluetooth address isn't from a "
                                   "registered manufacturer prefix"))
    if bluetooth_before.get("state") == "on" and bluetooth_after.get("state") == "on":
        def paired(snapshot: dict) -> list:
            return [f"{d.get('name')} [{d.get('address')}]"
                    for d in snapshot.get("connected", []) + snapshot.get("not_connected", [])]
        changed_items("Bluetooth pairing", paired(bluetooth_before), paired(bluetooth_after),
                      None, lines, findings)
    return lines, findings


def render(title: str, lines: list[str], findings: list[tuple[str, str]]) -> str:
    findings = list(dict.fromkeys(findings))
    reds = [text for level, text in findings if level == RED]
    notes = [text for level, text in findings if level == NOTE]
    out = [f"== {title} ==", *(lines or ["no changes"])]
    if reds or notes:
        out.append("")
    out += [f"RED   {text}" for text in reds] + [f"NOTE  {text}" for text in notes]
    out.append(f"{len(reds)} red flag(s), {len(notes)} note(s).")
    return "\n".join(out)


# ---------- watching ----------

def quick_signature(state: dict) -> tuple:
    return (tuple(sorted((k, tuple(v)) for k, v in state["usb"].items())), tuple(sorted(state["hid"])),
            tuple(state["volumes"]), tuple(state["network"]), state["keyboard_setup"])


def arrivals(baseline: dict, state: dict) -> list[str]:
    found = [f"USB device \"{clean(key.rsplit('@', 1)[0])}\"" for key in state["usb"] if key not in baseline["usb"]]
    found += [f"HID \"{clean(row.get('product'))}\" over {clean(row.get('transport'))}"
              for rid, row in state["hid"].items() if rid not in baseline["hid"]]
    found += [f"volume \"{clean(name)}\"" for name in state["volumes"] if name not in baseline["volumes"]]
    return found


def risky_services(baseline: dict, state: dict, seen: set) -> list[tuple[str, str]]:
    """Keyboard and pointer services as soon as they register, including short-lived ones."""
    events = []
    for rid, row in state["hid"].items():
        if rid in baseline["hid"] or rid in seen:
            continue
        seen.add(rid)
        kind = SERVICE_KINDS.get((row["page"], row["usage"]))
        if kind is None and row["page"] == 0x0D:
            kind = "touch or pen input"
        if kind:
            events.append((RED, f"{clean(row.get('product'))} registered a {kind} with macOS"))
    return events


class Session:
    """Prints the session and, with --out, keeps its snapshots and report."""

    def __init__(self, out: Optional[Path], emit: Callable[[str], None], clock: Callable[[], str]):
        self.out, self.emit, self.clock = out, emit, clock
        if out:
            out.mkdir(parents=True, exist_ok=True)

    def write(self, text: str) -> None:
        self.emit(text)
        if self.out:
            with open(self.out / "report.txt", "a", encoding="utf-8") as report:
                report.write(text + "\n")

    def say(self, text: str) -> None:
        self.write(f"{self.clock()}  {text}")

    def save(self, name: str, snapshot: dict) -> None:
        if self.out:
            (self.out / f"{name}.json").write_text(json.dumps(snapshot, indent=1, default=str), encoding="utf-8")


def watch(probe, wait_s: float = 1500, observe_s: float = 300, out: Optional[Path] = None,
          emit: Callable[[str], None] = print, settle_s: float = 5, settle_limit_s: float = 120,
          poll_s: float = 1.0, sleep: Callable[[float], None] = time.sleep,
          now: Callable[[], float] = time.monotonic,
          clock: Callable[[], str] = lambda: datetime.now().strftime("%H:%M:%S")) -> int:
    """Baseline, wait for one accessory, report it, watch it. 0 clean, 1 red flags, 3 nothing came."""
    session = Session(out, emit, clock)
    baseline_state = probe.quick()
    baseline = probe.snapshot()
    session.save("before", baseline)
    session.say("Baseline taken. Connect one accessory now. If macOS asks, Allow lets it exchange data; "
                "Don't Allow leaves it charging only.")
    live: list[tuple[str, str]] = []
    seen: set = set()

    def poll() -> dict:
        state = probe.quick()
        for event in risky_services(baseline_state, state, seen):
            live.append(event)
            session.say(f"RED   {event[1]}. Unplug it if you didn't expect that.")
        return state

    asked = False

    def note_prompt(state: dict) -> bool:
        nonlocal asked
        pending = any(port.get("pending") for port in state.get("ports", []))
        if pending and not asked:
            session.say("macOS is asking whether to allow the accessory.")
            asked = True
        return pending

    started = now()
    while True:
        state = poll()
        note_prompt(state)
        found = arrivals(baseline_state, state)
        if found:
            break
        if now() - started >= wait_s:
            session.say(f"No new accessory appeared within {wait_s:g} s.")
            return 3
        sleep(poll_s)
    session.say("Detected " + "; ".join(found) + ". Waiting for it to settle.")

    # A USB device is listed before it is approved; it gains interfaces once it may exchange data.
    quiet, waited, last, hinted = 0.0, 0.0, quick_signature(state), False
    while waited < settle_limit_s:
        sleep(poll_s)
        waited += poll_s
        state = poll()
        signature = quick_signature(state)
        bare = [key for key, (_, count) in state["usb"].items()
                if key not in baseline_state["usb"] and count == 0]
        if bare and waited >= 10 and not hinted:
            session.say("The USB device has no interfaces yet. If macOS is asking, Allow lets the check continue.")
            hinted = True
        if note_prompt(state) or bare or signature != last:
            quiet = 0.0
        else:
            quiet += poll_s
            if quiet >= settle_s:
                break
        last = signature
    else:
        session.say(f"Still changing or waiting for approval after {settle_limit_s:g} s; reporting what is visible.")

    after = probe.snapshot()
    session.save("after", after)
    lines, findings = compare(baseline, after)
    session.write(render("Connected", lines, findings))
    session_findings = list(findings)

    session.say(f"Watching for {observe_s:g} s.")
    previous, last, changes = after, quick_signature(state), 0
    ends = now() + observe_s
    while now() < ends:
        sleep(2 * poll_s)
        state = poll()
        if quick_signature(state) == last:
            continue
        changes += 1
        sleep(3 * poll_s)
        current = probe.snapshot()
        session.save(f"change-{changes}", current)
        lines, findings = compare(previous, current)
        session.write(render(f"Change {changes} at {clock()}", lines, findings))
        session_findings += findings
        previous, last = current, quick_signature(poll())

    final = probe.snapshot()
    session.save("final", final)
    lines, findings = compare(baseline, final)
    session_findings += findings
    flagged = " ".join(text for level, text in session_findings if level == RED)
    session_findings += [event for event in live if event[1].split(" registered")[0] not in flagged]
    plural = "" if changes == 1 else "s"
    session.write(render(f"Whole session, baseline to {clock()}, {changes} change{plural} while watching",
                         lines, session_findings))
    return 1 if any(level == RED for level, _ in session_findings) else 0


# ---------- commands ----------

def paired_report(probe: MacProbe, emit: Callable[[str], None]) -> int:
    bluetooth = parse_bluetooth(probe.run(["system_profiler", "-json", "SPBluetoothDataType"]))
    if bluetooth["state"] == "off":
        emit("Bluetooth is off, so macOS doesn't list paired devices. Turn it on and run this again.")
        return 0
    devices = [(d, "connected") for d in bluetooth["connected"]] + \
              [(d, "not connected") for d in bluetooth["not_connected"]]
    if not devices:
        emit("No paired Bluetooth devices.")
        return 0
    flagged = False
    for device, status in sorted(devices, key=lambda pair: str(pair[0].get("name")).lower()):
        registered = address_registered(device.get("address"))
        flagged = flagged or registered is False
        mark = {True: "", False: "  <- not a registered manufacturer prefix",
                None: "  (address unreadable)"}[registered]
        details = "  ".join(clean(v) for v in (device.get("kind"), device.get("vid"), device.get("pid")) if v)
        emit(f"{clean(device.get('name'))}  {clean(device.get('address'))}  {details}  {status}{mark}")
    if flagged:
        emit("\nA classic Bluetooth device's address starts with its maker's IEEE-assigned prefix, and an "
             "assigned prefix keeps the two lowest bits of the first byte clear. Bluetooth LE devices may use "
             "random addresses instead; for a classic controller or headset that names a known brand, an "
             "unassigned prefix usually means a copy from another maker.")
    return 0


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(
        description="Report what a newly connected accessory tells macOS it is. Without a command, runs watch.")
    commands = parser.add_subparsers(dest="command")
    watch_parser = commands.add_parser("watch", help="baseline, wait for one accessory, report it, and watch it")
    watch_parser.add_argument("--wait", type=float, default=1500, help="seconds to wait for an accessory (1500)")
    watch_parser.add_argument("--observe", type=float, default=300, help="seconds to watch it afterwards (300)")
    watch_parser.add_argument("--out", type=Path, help="folder for the snapshots and report")
    snapshot_parser = commands.add_parser("snapshot", help="write the current device state as JSON")
    snapshot_parser.add_argument("file", type=Path)
    diff_parser = commands.add_parser("diff", help="report the changes between two snapshots")
    diff_parser.add_argument("before", type=Path)
    diff_parser.add_argument("after", type=Path)
    decode_parser = commands.add_parser("decode", help="explain a HID report descriptor given in hex")
    decode_parser.add_argument("hex")
    commands.add_parser("paired", help="list paired Bluetooth devices and check their addresses")
    return parser


def main(argv: Optional[list[str]] = None, probe=None, emit: Optional[Callable[[str], None]] = None) -> int:
    args = build_parser().parse_args(argv)
    emit = emit or (lambda text: print(text, flush=True))
    probe = probe or MacProbe()
    command = args.command or "watch"
    if command == "decode":
        text = "".join(args.hex.split()).lower().replace("0x", "").replace(",", "")
        try:
            descriptor = bytes.fromhex(text)
        except ValueError:
            emit("decode needs the descriptor as hexadecimal bytes, for example 05010906a101…")
            return 2
        lines, findings = explain_descriptor(descriptor)
        emit(render("Report descriptor", lines, findings))
        return 1 if any(level == RED for level, _ in findings) else 0
    if sys.platform != "darwin":
        emit("This check reads macOS device state and runs only on a Mac.")
        return 2
    try:
        if command == "watch":
            return watch(probe, wait_s=getattr(args, "wait", 1500), observe_s=getattr(args, "observe", 300),
                         out=getattr(args, "out", None), emit=emit)
        if command == "snapshot":
            args.file.write_text(json.dumps(probe.snapshot(), indent=1, default=str), encoding="utf-8")
            return 0
        if command == "diff":
            before = json.loads(args.before.read_text(encoding="utf-8"))
            after = json.loads(args.after.read_text(encoding="utf-8"))
            lines, findings = compare(before, after)
            emit(render(f"{args.before.name} to {args.after.name}", lines, findings))
            return 1 if any(level == RED for level, _ in findings) else 0
        return paired_report(probe, emit)
    except KeyboardInterrupt:
        emit("Stopped.")
        return 130


if __name__ == "__main__":
    sys.exit(main())
