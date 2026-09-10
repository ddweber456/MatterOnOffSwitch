#include <Matter.h>
#include <WiFi.h>
#include <Preferences.h> // Required for accessing ESP32 local Non-Volatile Storage (NVS)

// ==========================================
// 🔌 HARDWARE PROFILE DEFINITIONS
// ==========================================
const int MOSFET_GATE_PIN = 4;        // Logic-level MOSFET Gate signal output
const int PHYSICAL_BUTTON_PIN = 5;    // Manual mechanical button interface input
const int STATUS_LED_PIN = 2;          // System state status visual indicator LED

// ==========================================
// ⏱️ ASYNCHRONOUS TIMER CONFIGURATIONS
// ==========================================
const unsigned long PULSE_DURATION = 600; // Exact momentary pulse window in milliseconds
const unsigned long DEBOUNCE_DELAY = 50;   // Mechanical switch debounce threshold

bool pulseIsActive = false;
unsigned long pulseStartTimestamp = 0;

int lastButtonState = HIGH;      // Assumes INPUT_PULLUP (HIGH = idle)
unsigned long lastDebounceTime = 0;

// ==========================================
// 🏛️ SMART HOME INSTANTIATIONS
// ==========================================
MatterOnOffPluginUnit openSesameSwitch; 
Preferences prefs;                     

void setup() {
  Serial.begin(115200);

  pinMode(MOSFET_GATE_PIN, OUTPUT);
  digitalWrite(MOSFET_GATE_PIN, LOW); 
  
  pinMode(STATUS_LED_PIN, OUTPUT);
  digitalWrite(STATUS_LED_PIN, LOW);

  pinMode(PHYSICAL_BUTTON_PIN, INPUT_PULLUP); 

  // Default fallback name string array if flash entry reading fails
  String runtimeDeviceName = "Open Sesame"; 

  // Open the NVS space named "matter" in read-only mode to fetch the identity entry
  prefs.begin("matter", true);
  if (prefs.isKey("device_name")) {
    runtimeDeviceName = prefs.getString("device_name");
  }
  prefs.end();

  // 1. Initialize Dual-Radio Matter Core
  Matter.begin();
  
  // 2. Name the device dynamically using values parsed out of local NV flash memory spaces
  openSesameSwitch.begin();
  openSesameSwitch.setProductName(runtimeDeviceName.c_str());
  openSesameSwitch.setManufacturerName("Custom Hardware Solutions");

  Serial.println("==================================================");
  Serial.print("DYNAMIC DEVICE IDENTITY: "); Serial.println(runtimeDeviceName);
  Serial.println("PROTOCOLS: Matter over Wi-Fi + Matter over Thread Enabled"); 
  Serial.println("==================================================");
}

void loop() {
  // --- PART 1: Physical Mechanical Button Input (Debounced) ---
  int reading = digitalRead(PHYSICAL_BUTTON_PIN);

  if (reading != lastButtonState) {
    lastDebounceTime = millis();
  }

  if ((millis() - lastDebounceTime) > DEBOUNCE_DELAY) {
    if (reading == LOW && !pulseIsActive) {
      triggerPulse();
      openSesameSwitch.setOnOff(true); 
      Serial.println("[Hardware Event] Manual Button Triggered!");
    }
  }
  lastButtonState = reading;

  // --- PART 2: Local Matter Ecosystem Inputs ---
  if (openSesameSwitch.hasChanged()) {
    bool targetState = openSesameSwitch.getOnOff();
    
    if (targetState && !pulseIsActive) {
      triggerPulse();
      Serial.println("[Local Network Event] Ecosystem App ON Command Acknowledged");
    } 
    else if (!targetState && pulseIsActive) {
      cancelPulse();
      Serial.println("[Local Network Event] Overriding Loop: App Force-Canceled Pulse");
    }
  }

  // --- PART 3: Non-Blocking Pulse Execution Loop & Notification Reset ---
  if (pulseIsActive) {
    if (millis() - pulseStartTimestamp >= PULSE_DURATION) {
      cancelPulse();
      openSesameSwitch.setOnOff(false); 
      Serial.println("[Timer Event] 600ms Exhausted -> Resetting System Output to LOW");
    }
  }
}

void triggerPulse() {
  digitalWrite(MOSFET_GATE_PIN, HIGH); 
  digitalWrite(STATUS_LED_PIN, HIGH);   
  pulseIsActive = true;
  pulseStartTimestamp = millis();
}

void cancelPulse() {
  digitalWrite(MOSFET_GATE_PIN, LOW);  
  digitalWrite(STATUS_LED_PIN, LOW);   
  pulseIsActive = false;
}
