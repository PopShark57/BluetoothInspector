#!/usr/bin/env python3
"""Regenerates BluetoothInspectorKit's Bluetooth SIG name tables.

Usage:
    git clone https://bitbucket.org/bluetooth-SIG/public.git /tmp/sig
    python3 Scripts/generate_sig_tables.py /tmp/sig/assigned_numbers

Requires PyYAML. The output is written to
BluetoothInspectorKit/Sources/BluetoothInspectorKit/SIG/AssignedNumbers+Tables.swift.

Only names are extracted (UUID/value -> human readable name). The company
identifier table is intentionally a curated subset of vendors developers
commonly meet; the full list can be loaded at runtime from a JSON file built
with `--full-json` (see README, "Extending the SIG database").
"""
import json
import os
import re
import sys

import yaml

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
OUTPUT = os.path.join(
    ROOT, "BluetoothInspectorKit", "Sources", "BluetoothInspectorKit", "SIG", "AssignedNumbers+Tables.swift"
)

# Friendlier spellings for names whose official short form is cryptic.
SERVICE_OVERRIDES = {
    0x1800: "Generic Access",
    0x1801: "Generic Attribute",
    0x180F: "Battery Service",
}

# Companies whose identifiers show up constantly in manufacturer data.
COMPANY_PATTERN = re.compile(
    r"^(Apple|Microsoft|Google|Samsung Electronics|Nordic Semiconductor|Texas Instruments|Qualcomm|"
    r"Broadcom|Intel Corp|Bose|Sony|Garmin|Fitbit|Polar Electro|Wahoo|Xiaomi|Huawei|Logitech|"
    r"Espressif|Silicon Laboratories|STMicroelectronics|NXP|Infineon|Cypress Semiconductor|"
    r"Dialog Semiconductor|Renesas|Realtek|MediaTek|LG Electronics|Amazon|Meta Platforms|Facebook|"
    r"Tile|Suunto|GN Hearing|GN Audio|Sennheiser|Harman|Bang & Olufsen|Withings|Oura|Whoop|"
    r"Peloton|Zwift|Tacx|Stages Cycling|SRAM|Shimano|Anhui Huami|Zepp|OnePlus|Guangdong Oppo|vivo|"
    r"Nothing Technology|Motorola|Nintendo|Valve|Sonos|Signify|IKEA|Ericsson|Nokia|Lenovo|Dell|HP Inc|"
    r"Tesla|Bayerische Motoren|Ruuvi|Raspberry Pi|Adafruit|Seeed|Particle|Bluetooth SIG|Telink|"
    r"Bestechnic|Actions|Airoha|Ambiq|Microchip|Robert Bosch|Continental|Jabra|Skullcandy|"
    r"Plantronics|Beats|Anker|Tuya|Philips|Oculus|Snap Inc|Peak Design|Chipolo|Trackr|Pebble|"
    r"Misfit|Jawbone|Wacom|Razer|SteelSeries|Corsair|8BitDo|Estimote|Kontakt|Radius Networks|"
    r"Onset|Hewlett|Canon|Nikon|Fujifilm|GoPro|DJI|Insta360|Theragun|Therabody|Eight Sleep|"
    r"Dexcom|Abbott|Medtronic|Omron|iHealth|Masimo|Nonin|A&D|Beurer)",
    re.IGNORECASE,
)


def load(directory, relative):
    with open(os.path.join(directory, relative), encoding="utf-8") as handle:
        return yaml.safe_load(handle)


def swift_string(text):
    text = " ".join(str(text).split())
    return '"' + text.replace("\\", "\\\\").replace('"', '\\"') + '"'


def uuid_table(directory, relative, overrides=None, transform=None):
    table = {}
    for item in load(directory, relative)["uuids"]:
        name = item["name"]
        if transform:
            name = transform(name)
        table[item["uuid"]] = name
    table.update(overrides or {})
    return table


def service_class_name(name):
    name = name.replace("ServiceClassID", "")
    if "_" not in name and " " not in name:
        name = re.sub(r"(?<=[a-z])(?=[A-Z])", " ", name)
    return name.replace("_", " ")


def render(name, table, key_format="0x%04X"):
    lines = [f"    static let {name}: [UInt16: String] = ["]
    for key in sorted(table):
        lines.append(f"        {key_format % key}: {swift_string(table[key])},")
    lines.append("    ]")
    return "\n".join(lines)


def main():
    if len(sys.argv) < 2:
        print(__doc__)
        sys.exit(1)
    directory = sys.argv[1]
    full_json = "--full-json" in sys.argv

    services = uuid_table(directory, "uuids/service_uuids.yaml", SERVICE_OVERRIDES)
    characteristics = uuid_table(directory, "uuids/characteristic_uuids.yaml")
    descriptors = uuid_table(directory, "uuids/descriptors.yaml")
    members = uuid_table(directory, "uuids/member_uuids.yaml")
    service_classes = uuid_table(directory, "uuids/service_class.yaml", transform=service_class_name)
    protocols = uuid_table(directory, "uuids/protocol_identifiers.yaml")
    units = uuid_table(directory, "uuids/units.yaml")

    all_companies = {
        item["value"]: item["name"]
        for item in load(directory, "company_identifiers/company_identifiers.yaml")["company_identifiers"]
    }
    companies = {key: value for key, value in all_companies.items() if COMPANY_PATTERN.search(value)}

    appearance = {}
    for category in load(directory, "core/appearance_values.yaml")["appearance_values"]:
        base = category["category"] << 6
        appearance[base] = category["name"]
        for sub in category.get("subcategory", []) or []:
            appearance[base | sub["value"]] = f"{category['name']}: {sub['name']}"

    if full_json:
        path = os.path.join(os.getcwd(), "sig-database.json")
        with open(path, "w", encoding="utf-8") as handle:
            json.dump(
                {
                    "companies": {f"{k:04X}": v for k, v in all_companies.items()},
                    "uuids": {f"{k:04X}": v for k, v in {**members, **units, **protocols, **service_classes,
                                                           **descriptors, **characteristics, **services}.items()},
                },
                handle,
                indent=1,
                sort_keys=True,
            )
        print(f"Wrote {path}")

    body = "\n\n".join(
        [
            render("serviceNames", services),
            render("characteristicNames", characteristics),
            render("descriptorNames", descriptors),
            render("memberUUIDNames", members),
            render("serviceClassNames", service_classes),
            render("protocolNames", protocols),
            render("unitNames", units),
            render("companyNames", companies),
            render("appearanceNames", appearance),
        ]
    )
    header = (
        "// GENERATED by Scripts/generate_sig_tables.py from the Bluetooth SIG assigned numbers\n"
        "// repository (https://bitbucket.org/bluetooth-SIG/public). Do not edit by hand.\n"
        "// Names are Bluetooth SIG assigned numbers; see README \"Bluetooth SIG data\".\n\n"
        "extension AssignedNumbers {\n"
    )
    with open(OUTPUT, "w", encoding="utf-8") as handle:
        handle.write(header + body + "\n}\n")
    print(f"Wrote {OUTPUT}: {len(services)} services, {len(characteristics)} characteristics, "
          f"{len(descriptors)} descriptors, {len(members)} member UUIDs, {len(companies)} companies")


if __name__ == "__main__":
    main()
