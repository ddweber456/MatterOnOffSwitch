#include <Matter.h>
#include <WiFi.h>
#include <Preferences.h> // Handles communication with local Non-Volatile Storage (NVS)

// ==========================================
// 🔌 HARDWARE PROFILE DEFINITIONS
// ==========================================
const int MOSFET_GATE_PIN = 4;        // Logic-level MOSFET Gate signal output
const int PHYSICAL_BUTTON_PIN = 5;    // Manual mechanical button interface input
const int STATUS_LED_PIN = 2;          // System state status visual indicator LED

// ==========================================
// ⏱️ ASYNCHRONOUS TIMER CONFIGURATIONS
// ==========================================
const unsigned long PULSE_DURATION = 600; // Momentary output pulse length in milliseconds
const unsigned long DEBOUNCE_DELAY = 50;   // Mechanical switch debounce input validation window

bool pulseIsActive = false;
unsigned long pulseStartTimestamp = 0;

int lastButtonState = HIGH;      // Assumes hardware INPUT_PULLUP state
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

  // Read local variables simply to print configuration traces to the factory Serial log console
  String runtimeDeviceName = "Open Sesame (Dev Fallback)"; 
  prefs.begin("matter", true);
  if (prefs.isKey("device_name")) {
    runtimeDeviceName = prefs.getString("device_name");
  }
  prefs.end();

  // 1. Initialize your endpoint plugins BEFORE calling the main stack begin routine
  openSesameSwitch.begin();
  lastEcosystemState = openSesameSwitch.getOnOff();

  // 2. Core Matter Stack Initialization Protocol
  // The underlying engine automatically reads properties from your flashed factory partitions
  Matter.begin();

  Serial.println("==================================================");
  Serial.print("MONITOR REGISTERED IDENTITY: "); Serial.println(runtimeDeviceName);
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
    if (reading == LOW && !pulseIsActive) {
      triggerPulse();
      openSesameSwitch.setOnOff(true); // Broadcast active pulse state out to Matter fabrics
      lastEcosystemState = true;
      Serial.println("[Hardware Event] Manual Button State Change Acknowledged");
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
      Serial.println("[Timer Event] 600ms固定 -> Returning Output Channel to LOW");
    }
  }
}

// ==========================================
// ⚙️ CORE PULSE OPERATION ROUTINES
// ==========================================
void triggerPulse() {
  digitalWrite(MOSFET_GATE_PIN, HIGH); // Output 3.3V bias to logic-level MOSFET Gate
  digitalWrite(STATUS_LED_PIN, HIGH);   // Ignite diagnostic visual validation indicator LED
  pulseIsActive = true;
  pulseStartTimestamp = millis();
}

void cancelPulse() {
  digitalWrite(MOSFET_GATE_PIN, LOW);  // Safely clamp output gate back to Ground level
  digitalWrite(STATUS_LED_PIN, LOW);   // Extinguish diagnostic LED
  pulseIsActive = false;
}
