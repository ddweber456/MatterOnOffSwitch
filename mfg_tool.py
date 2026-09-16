import os
import sys
import argparse
import subprocess
import csv
from datetime import datetime


def discriminator_from_mac(mac_str):
    """
    Derives the same 12-bit Matter setup discriminator the firmware computes
    on its own at first boot: the last two MAC octets, masked to 12 bits.
    Keeping this identical to MatterOnOffSwitch.ino's formula is what makes
    the discriminator printed on the label/QR code match what the device
    actually advertises - if these two ever drift apart, the printed
    pairing code stops working.
    """
    octets = mac_str.strip().split(":")
    if len(octets) != 6:
        raise ValueError(f"MAC address '{mac_str}' is not in AA:BB:CC:DD:EE:FF format.")
    last_two = (int(octets[4], 16) << 8) | int(octets[5], 16)
    return last_two & 0x0FFF


def main():
    # 1. Parse Arguments passed out of the Windows .bat file pipeline
    parser = argparse.ArgumentParser(description="Open Sesame Low-Volume NVS Binary Generator & QA Logger")
    parser.add_argument("--passcode", type=int, required=True, help="8-digit Matter setup passcode (10000000 - 99999999)")
    parser.add_argument("--mac", type=str, required=True, help="The target hardware MAC Address extracted via esptool")
    parser.add_argument("--out", type=str, default="factory_data.bin", help="Output file name target string")
    # --discriminator is accepted for backward compatibility with existing call sites, but is
    # ignored in favor of the MAC-derived value so this tool can never disagree with the firmware.
    parser.add_argument("--discriminator", type=int, default=None, help="Deprecated - discriminator is now derived from --mac")
    # [ADDED Rev 1.8] Customer/brand name, injected into factory_data.bin at flash time instead
    # of being hardcoded into the firmware. See Product Requirement.txt Section 3.1/4.1 - this is
    # what lets one compiled firmware image serve multiple customer brands. flash_device_core.bat
    # passes this through from the calling brand wrapper's BRAND_NAME variable.
    parser.add_argument("--brand", type=str, default="Open Sesame",
                         help="Customer/brand name baked into this unit's factory-provisioned "
                              "device name (combined with the MAC-derived discriminator). "
                              "Does not require recompiling firmware.")
    args = parser.parse_args()

    discriminator = discriminator_from_mac(args.mac)
    if args.discriminator is not None and args.discriminator != discriminator:
        print(f"[Python] NOTE: --discriminator {args.discriminator} was supplied but ignored; "
              f"using MAC-derived value {discriminator} to stay in sync with the firmware.")

    brand = args.brand.strip() if args.brand and args.brand.strip() else "Open Sesame"
    if brand != args.brand:
        print(f"[Python] NOTE: --brand was blank/whitespace; falling back to \"{brand}\".")

    # Data Validation Constraints Check
    # Matter's setup discriminator is a plain 12-bit value (0-4095) - there is no protocol
    # requirement that it be >= 1000. The MAC-derived formula can legitimately land anywhere
    # in that full range, so the check only needs to guard against a malformed/out-of-range value.
    if not (0 <= discriminator <= 4095):
        print("❌ ERROR: Discriminator must be a valid 12-bit value between 0 and 4095.")
        sys.exit(1)

    if not (10000000 <= args.passcode <= 99999999):
        print("❌ ERROR: Passcode must be exactly 8 digits.")
        sys.exit(1)

    csv_filename = "temp_factory_layout.csv"
    log_filename = "production_log.csv"
    custom_device_name = f"{brand} [{discriminator}]"

    # 2. Construct the Key-Value CSV structural map demanded by the Espressif NVS compiler
    #
    # NOTE: this "matter" namespace is compiled into factory_data.bin, which flash_device.bat
    # writes to the dedicated "fctry" NVS partition (see Product Requirement.txt Section 4.3).
    # As of firmware Rev 1.8, MatterOnOffSwitch.ino reads this exact partition/namespace back
    # at boot as its FIRST-CHOICE identity source - this is now the primary source of truth for
    # device_name/discriminator/passcode, not a backup (earlier revisions had a bug where the
    # firmware never actually read this partition - see Rev 1.8 changelog). PASSCODE is still the
    # one value the firmware doesn't yet hand to the Matter stack (Matter.setSetupPasscode() is
    # blocked upstream - see Section 3.1) - getting it applied is what actually needs to be
    # verified end-to-end on real hardware.
    csv_content = f"""key,type,encoding,value
matter,namespace,,
discriminator,data,u16,{discriminator}
passcode,data,u32,{args.passcode}
device_name,data,string,{custom_device_name}
"""

    try:
        # Write structural schema definitions out to disk space temporarily
        with open(csv_filename, "w", newline="") as f:
            f.write(csv_content)

        print(f"[Python] Structuring payload profile for values: Disc=0x{discriminator:03X} ({discriminator}), PIN={args.passcode}")
        print(f"[Python] Appended Custom NV Device Identity: \"{custom_device_name}\" (brand: \"{brand}\")")

        # 3. Locate Espressif NVS Generator tool inside local machine architecture
        user_profile = os.environ.get("USERPROFILE", "C:\\Users\\Admin")
        nvs_gen_path = os.path.join(user_profile, "AppData", "Local", "Arduino15", "packages", "esp32", "tools", "esptool_py", "4.6", "nvs_partition_gen.py")
        if not os.path.exists(nvs_gen_path):
            nvs_gen_path = "nvs_partition_gen.py"

        # 4. Invoke the compiler script using standard subprocess calls to compile binary payloads
        cmd = [
            sys.executable, nvs_gen_path,
            "generate", csv_filename, args.out, "0x4000"
        ]
        print(f"[Python] Compiling target key arrays to binary structure: {args.out}...")
        result = subprocess.run(cmd, stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)

        if result.returncode != 0:
            print("❌ PACKAGING COMPILER COMPILATION ERROR DETAILS:")
            print(result.stderr)
            sys.exit(1)

        print(f"🎉 SUCCESS: Captured configurations compiled successfully to target binary object: {args.out}")

        # 5. Quality Tracking Master CSV Logger Mechanism
        print(f"[QA Logger] Appending unit information to master file: {log_filename}")
        file_exists = os.path.exists(log_filename)
        with open(log_filename, mode="a", newline="", encoding="utf-8") as qa_file:
            writer = csv.writer(qa_file)
            if not file_exists:
                writer.writerow(["Timestamp", "MAC Address", "Brand", "Device Name", "Discriminator", "Passcode", "Status"])
            current_time = datetime.now().strftime("%Y-%m-%d %H:%M:%S")
            writer.writerow([current_time, args.mac.upper(), brand, custom_device_name, discriminator, args.passcode, "SUCCESS"])

    except Exception as e:
        print(f"❌ LOG MECHANISM SYSTEM ERROR: {e}")
        sys.exit(1)
    finally:
        if os.path.exists(csv_filename):
            os.remove(csv_filename)


if __name__ == "__main__":
    main()
