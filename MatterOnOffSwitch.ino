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
  // 🏷️ FIRST-BOOT IDENTITY GENERATION
  // Generates a MAC-derived discriminator + device name exactly once,
  // then persists it in NVS so it stays stable across reboots. This is
  // what actually makes each unit show up with a distinct name in
  // Alexa, Google Home, Apple Home, and Home Assistant - the earlier
  // version read a "device_name" NVS key but never handed it to the
  // Matter stack, so it had no effect on what ecosystems displayed.
  // ==========================================
  String runtimeDeviceName = "Open Sesame (Dev Fallback)";
  uint16_t runtimeDiscriminator = 0xF00; // library's own test-default, used only if generation fails

  prefs.begin("matter", false); // read-write, so we can persist on first boot
  if (prefs.isKey("device_name") && prefs.isKey("discriminator")) {
    runtimeDeviceName = prefs.getString("device_name");
    runtimeDiscriminator = prefs.getUShort("discriminator");
  } else {
    uint8_t mac[6];
    WiFi.macAddress(mac);
    runtimeDiscriminator = ((mac[4] << 8) | mac[5]) & 0x0FFF; // 12-bit range per Matter spec
    runtimeDeviceName = "Open Sesame [" + String(runtimeDiscriminator) + "]";
    prefs.putString("device_name", runtimeDeviceName);
    prefs.putUShort("discriminator", runtimeDiscriminator);
    Serial.println("[Identity] First boot detected - generated and saved new device identity");
  }
  prefs.end();

  // Identity setters must be called BEFORE Matter.begin() - after begin()
  // they're logged as a warning and have no effect.
  Matter.setDeviceName(runtimeDeviceName.c_str());
  Matter.setSetupDiscriminator(runtimeDiscriminator);

  // 1. Initialize your endpoint plugins BEFORE calling the main stack begin routine
  openSesameSwitch.begin();
  lastEcosystemState = openSesameSwitch.getOnOff();

  // 2. Core Matter Stack Initialization Protocol
  Matter.begin();

  Serial.println("==================================================");
  Serial.print("MONITOR REGISTERED IDENTITY: "); Serial.println(runtimeDeviceName);
  Serial.print("SETUP DISCRIMINATOR: ");          Serial.println(runtimeDiscriminator);
  Serial.println("PROTOCOLS: Matter over Wi-Fi + Matter over Thread Configured");
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
