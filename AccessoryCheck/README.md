# Accessory check

`accessory-check.py` reports what a USB or Bluetooth accessory tells macOS it is, so you can see whether a controller, headset, or adapter declared anything beyond its stated purpose. It only reads state: it never changes a setting or answers macOS's accessory prompt. It uses Python 3's standard library and macOS's own tools; no installation is needed.

## Check an accessory

Run it, then connect the accessory when it asks:

```sh
AccessoryCheck/accessory-check.py
```

It takes a snapshot of the Mac, waits up to 25 minutes for one new USB device, HID device, or volume, and reports what the accessory declared once it settles. On a Mac laptop with Apple silicon, macOS asks before a new USB accessory may exchange data, and the check waits for that answer: **Allow** lets it continue, and **Don't Allow** leaves the accessory charging only, which the report shows as a device without interfaces. The check then watches for five minutes and reports any change, such as the device disconnecting and returning with different functions. A final report compares the whole session with the first snapshot.

`watch --wait SECONDS --observe SECONDS` changes both periods, and `watch --out FOLDER` keeps every snapshot and the report there. Connect only the accessory under test; anything else that appears in the meantime is reported with it. The exit status is 0 without red flags, 1 with any, and 3 when nothing appeared.

## Reading the report

**RED** marks a function that lets a device act on the Mac by itself:

- a HID collection that can type keys or move the pointer: a keyboard, keypad, mouse, pointer, touch surface, or pen, including keyboard keys declared inside a gamepad's collection or outside any collection;
- a keyboard or pointer service registering with macOS during the session, even briefly;
- a USB drive, network adapter (CDC Ethernet, RNDIS), or serial-port interface, or a new volume, external disk, or network interface;
- Keyboard Setup Assistant opening, or a system extension or non-Apple kernel extension appearing.

**NOTE** marks something worth a look that cannot act by itself: a vendor-specific or firmware-update interface; a hub, camera, or card reader inside the device; power or app-launch keys; a malformed descriptor; a device reconnecting with different functions; or a Bluetooth address outside the IEEE-assigned company prefixes.

The remaining lines are information. A sound card adds a microphone that apps still need Microphone permission to use. A data channel is a HID report that the device exchanges with software, usually for settings or firmware updates; macOS does not turn it into key presses. "Opened over USB by" names apps on this Mac that opened the device, not something the device did. `GamePad-1` is the virtual controller macOS adds for a supported game controller.

A keyboard or mouse under test produces RED as expected: the flags describe abilities, not intent. Device-supplied names are printed with control characters escaped, so a name cannot rewrite the terminal.

## Limits

The report shows what the accessory declared while it was watched. Its names, IDs, and descriptors are its own claims, so a copy can carry another maker's IDs, and firmware can wait and change its behavior later. A clean report means the device asked for nothing beyond its purpose during the check; it does not prove the device safe. The approval messages come from undocumented port properties in the I/O Registry, and the check reports less when they are missing.

## Other commands

```sh
AccessoryCheck/accessory-check.py paired
AccessoryCheck/accessory-check.py decode 05010906a101…
AccessoryCheck/accessory-check.py snapshot before.json
AccessoryCheck/accessory-check.py diff before.json after.json
```

`paired` lists paired Bluetooth devices and needs Bluetooth turned on. A classic Bluetooth device's address begins with its maker's IEEE-assigned prefix, and an assigned prefix leaves the two lowest bits of the first byte clear. Bluetooth LE devices may use random addresses instead; for a classic controller or headset that names a known brand, an unassigned prefix usually means a copy from another maker.

`decode` explains one HID report descriptor given in hexadecimal. `snapshot` writes the current device state as JSON, and `diff` reports the changes between two snapshots with the same flags as `watch`.

## Tests

Keep `test_accessory_check.py` beside the script and run it from any directory:

```sh
python3 -B -m unittest discover -s AccessoryCheck -p 'test_accessory_check.py'
```

The tests use recorded report descriptors and a scripted Mac. They do not run macOS commands.
