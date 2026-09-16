#include <Matter.h>
#include <WiFi.h>
#include <Preferences.h> // Handles communication with local Non-Volatile Storage (NVS)

// ==========================================
// 🔌 HARDWARE PROFILE DEFINITIONS
// ==========================================
const int MOSFET_GATE_PIN = 4;       // Logic-level MOSFET Gate signal output
const int PHYSICAL_BUTTON_PIN = 5;   // Manual mechanical button interface input
const int STATUS_LED_PIN = 2;        // System state status visual indicator LED

// ==========================================
// ⏱️ ASYNCHRONOUS TIMER CONFIGURATIONS
// ==========================================
const unsigned long PULSE_DURATION = 600;   // Momentary output pulse length in milliseconds
const unsigned long DEBOUNCE_DELAY = 50;    // Mechanical switch debounce input validation window

bool pulseIsActive = false;
unsigned long pulseStartTimestamp = 0;

int lastButtonState = HIGH;        // Raw reading from the previous loop() pass - used only to reset the debounce timer
int debouncedButtonState = HIGH;   // The stable, de-glitched button state - this is what we actually act on
unsigned long lastDebounceTime = 0;

// ==========================================
// 🏛️ SMART HOME INSTANTIATIONS
// ==========================================
MatterOnOffPlugin openSesameSwitch;
Preferences prefs;

// State Tracking Flag for Ecosystem Transactions
bool lastEcosystemState = false;

void setup() {
  Serial.begin(115200);
  delay(500); // Small stability buffer for the serial terminal on cold boot

  // Initialize Pin States instantly to prevent high-impedance floating logic triggers
  pinMode(MOSFET_GATE_PIN, OUTPUT);
  digitalWrite(MOSFET_GATE_PIN, LOW);
  pinMode(STATUS_LED_PIN, OUTPUT);
  digitalWrite(STATUS_LED_PIN, LOW);
  pinMode(PHYSICAL_BUTTON_PIN, INPUT_PULLUP);

  // ==========================================
  // 🏷️ DEVICE IDENTITY RESOLUTION  [UPDATED Rev 1.8]
  // Two possible sources, tried in this order:
  //   1. FACTORY-PROVISIONED identity, written into the "fctry" NVS
  //      partition by mfg_tool.py / flash_device.bat during manufacturing
  //      (see Product Requirement.txt Section 4.3). This is what carries
  //      the customer/brand name (mfg_tool.py's --brand) and the per-unit
  //      discriminator + passcode. Reading from here is what lets ONE
  //      compiled firmware image serve multiple customers/brands - only
  //      the small factory_data.bin blob differs per unit, not the
  //      firmware itself. See Section 3.1/4.1 for the full explanation.
  //   2. SELF-GENERATED fallback, computed from the chip's own MAC address
  //      and persisted in the DEFAULT NVS partition. This only kicks in
  //      when no factory data is present - e.g. a bench unit flashed with
  //      just the main firmware .bin, no factory_data.bin, for quick dev
  //      testing without running the full manufacturing flow.
  //
  // BUG FIX (Rev 1.8): earlier revisions opened the "matter" namespace on
  // the DEFAULT "nvs" partition only - never the "fctry" partition
  // mfg_tool.py actually writes into. Those are two separate NVS
  // partitions at different flash offsets, so factory-injected identity
  // was never actually read back here in any prior revision; every unit
  // was silently using the self-generated fallback instead, regardless of
  // what factory_data.bin contained. UNTESTED on real hardware as of this
  // revision - confirm the Serial output below says "factory", not
  // "dev fallback", on a unit flashed via flash_device.bat.
  //
  // NOTE: as of esp32 Arduino core 3.3.11 (currently pinned - see build
  // notes), whichever identity is resolved below is computed and
  // persisted but NOT yet handed to the Matter stack - see the TODO block
  // after this one. Every unit currently commissions with the Matter
  // library's shared default name/discriminator/passcode, NOT the values
  // resolved here. Do not rely on printed labels/QR codes matching these
  // values until that TODO is resolved.
  // ==========================================
  String runtimeDeviceName = "Open Sesame (Dev Fallback)";
  uint16_t runtimeDiscriminator = 0xF00;   // library's own test-default, used only if resolution fails
  uint32_t runtimePasscode = 20202021;     // library's own test-default, used only if resolution fails
  bool haveFactoryIdentity = false;

  Preferences factoryPrefs;
  // partition_label = "fctry" -> the factory-data NVS partition mfg_tool.py
  // writes into, NOT the default "nvs" partition used below. Opened
  // read-only: factory data is written once, at flash time, never by the
  // firmware itself.
  if (factoryPrefs.begin("matter", true, "fctry")) {
    if (factoryPrefs.isKey("device_name") && factoryPrefs.isKey("discriminator")) {
      runtimeDeviceName    = factoryPrefs.getString("device_name");
      runtimeDiscriminator = factoryPrefs.getUShort("discriminator");
      if (factoryPrefs.isKey("passcode")) {
        runtimePasscode = factoryPrefs.getUInt("passcode");
      }
      haveFactoryIdentity = true;
    }
    factoryPrefs.end();
  }

  if (!haveFactoryIdentity) {
    // No factory data found (or it's missing the expected keys) - most
    // likely a bench/dev unit flashed without running flash_device.bat's
    // mfg_tool.py step. Fall back to the original MAC-derived,
    // self-persisting identity so bench testing still works without a
    // full manufacturing pass.
    prefs.begin("matter", false); // read-write, so we can persist on first boot
    if (prefs.isKey("device_name") && prefs.isKey("discriminator")) {
      runtimeDeviceName = prefs.getString("device_name");
      runtimeDiscriminator = prefs.getUShort("discriminator");
    } else {
      uint8_t mac[6];
      WiFi.macAddress(mac);
      runtimeDiscriminator = ((mac[4] << 8) | mac[5]) & 0x0FFF; // 12-bit range per Matter spec
      runtimeDeviceName = "Open Sesame (Dev Fallback) [" + String(runtimeDiscriminator) + "]";
      prefs.putString("device_name", runtimeDeviceName);
      prefs.putUShort("discriminator", runtimeDiscriminator);
      Serial.println("[Identity] First boot, no factory data found - generated and saved a dev-fallback identity");
    }
    prefs.end();
  }

  // ------------------------------------------------------------------
  // TODO(upstream): Matter.setDeviceName() / Matter.setSetupDiscriminator()
  // / Matter.setSetupPasscode() are NOT available in the stable esp32
  // Arduino core we're pinned to (3.3.11). They only exist on the
  // arduino-esp32 dev/master branch, added by the still-unmerged
  // MatterIdentity feature (tracks upstream PR #12857, closing issue
  // #12293 "Change Matter Discriminator value").
  //
  // Re-enable the calls below once that API ships in a release we
  // upgrade to. Until then:
  //   - Every unit advertises the Matter library's shared default device
  //     name/discriminator/passcode, not the values resolved above.
  //   - factory_data.bin / mfg_tool.py / printed QR labels that assume
  //     these values are actually applied will NOT match what the device
  //     advertises. Do not rely on this for production commissioning yet.
  //
  // Identity setters must be called BEFORE Matter.begin() - after begin()
  // they're logged as a warning and have no effect.
  // Matter.setDeviceName(runtimeDeviceName.c_str());
  // Matter.setSetupDiscriminator(runtimeDiscriminator);
  // Matter.setSetupPasscode(runtimePasscode);
  // ------------------------------------------------------------------

  // 1. Initialize your endpoint plugins BEFORE calling the main stack begin routine
  openSesameSwitch.begin();
  lastEcosystemState = openSesameSwitch.getOnOff();

  // 2. Core Matter Stack Initialization Protocol
  Matter.begin();

  Serial.println("==================================================");
  Serial.print("RESOLVED IDENTITY (NOT YET APPLIED - see TODO above): "); Serial.println(runtimeDeviceName);
  Serial.print("RESOLVED DISCRIMINATOR (NOT YET APPLIED): ");             Serial.println(runtimeDiscriminator);
  Serial.print("IDENTITY SOURCE: ");                                     Serial.println(haveFactoryIdentity ? "factory (\"fctry\" NVS partition)" : "dev fallback (self-generated)");
  // NOTE: ESP32-C5's Arduino Matter library is currently precompiled Thread-only -
  // Wi-Fi is not yet an available Matter transport on this chip/core. Tracked
  // upstream at esp32-arduino-lib-builder PR #394 ("Matter and OpenThread
  // configurations"). Update this line once Wi-Fi transport is confirmed working.
  Serial.println("PROTOCOLS: Matter over Thread only (ESP32-C5 Wi-Fi Matter transport not yet available in Arduino core)");
  Serial.println("==================================================");
}

void loop() {
  // --- PART 1: Physical Mechanical Button Input (Debounced Validation) ---
  int reading = digitalRead(PHYSICAL_BUTTON_PIN);

  if (reading != lastButtonState) {
    lastDebounceTime = millis();
  }

  if ((millis() - lastDebounceTime) > DEBOUNCE_DELAY) {
    // Only act when the DEBOUNCED state actually changes. The original
    // version compared against the raw reading every loop, which meant
    // holding the button down past the end of a pulse caused it to
    // immediately re-trigger, over and over, for as long as it was held.
    if (reading != debouncedButtonState) {
      debouncedButtonState = reading;

      if (debouncedButtonState == LOW && !pulseIsActive) {
        triggerPulse();
        openSesameSwitch.setOnOff(true); // Broadcast active pulse state out to Matter fabrics
        lastEcosystemState = true;
        Serial.println("[Hardware Event] Manual Button State Change Acknowledged");
      }
    }
  }

  lastButtonState = reading;

  // --- PART 2: Inbound Ecosystem Transactions (Alexa, Google, Apple Home) ---
  bool currentEcosystemState = openSesameSwitch.getOnOff();
  if (currentEcosystemState != lastEcosystemState) {
    lastEcosystemState = currentEcosystemState;

    if (currentEcosystemState && !pulseIsActive) {
      triggerPulse();
      Serial.println("[Network Event] Ecosystem App ON Command Executed");
    }
    else if (!currentEcosystemState && pulseIsActive) {
      cancelPulse();
      Serial.println("[Network Event] Ecosystem App Force-Canceled Active Loop");
    }
  }

  // --- PART 3: Asynchronous Non-Blocking Pulse Reset Loop ---
  if (pulseIsActive) {
    if (millis() - pulseStartTimestamp >= PULSE_DURATION) {
      cancelPulse();
      openSesameSwitch.setOnOff(false); // Synchronize dashboard state graphics back to OFF state
      lastEcosystemState = false;
      Serial.println("[Timer Event] 600ms pulse complete -> Returning Output Channel to LOW");
    }
  }
}

// ==========================================
// ⚙️ CORE PULSE OPERATION ROUTINES
// ==========================================
void triggerPulse() {
  digitalWrite(MOSFET_GATE_PIN, HIGH); // Output 3.3V bias to logic-level MOSFET Gate
  digitalWrite(STATUS_LED_PIN, HIGH);  // Ignite diagnostic visual validation indicator LED
  pulseIsActive = true;
  pulseStartTimestamp = millis();
}

void cancelPulse() {
  digitalWrite(MOSFET_GATE_PIN, LOW); // Safely clamp output gate back to Ground level
  digitalWrite(STATUS_LED_PIN, LOW);  // Extinguish diagnostic LED
  pulseIsActive = false;
}
