import os
import sys
import argparse
import subprocess
import qrcode
from reportlab.lib.pagesizes import inch
from reportlab.platypus import SimpleDocTemplate, Table, TableStyle, Image, Paragraph
from reportlab.lib.styles import getSampleStyleSheet, ParagraphStyle

def generate_matter_qr_payload(discriminator, passcode, vid=0xFFF1, pid=0x8000):
    """
    Encodes standard Matter onboard parameters into a compliant Base38 MT: string format.
    Bit allocation template sequence dictated by CSA specs:
    - Version: 3 bits (value 0)
    - Vendor ID (VID): 16 bits
    - Product ID (PID): 16 bits
    - Commissioning Flow: 2 bits (value 0 for Standard onboarding)
    - Discovery Capabilities: 8 bits (value 4 for BLE transport beacon discovery)
    - Discriminator: 12 bits 
    - Passcode: 27 bits
    - Padding/Reserved: 4 bits (value 0)
    Total payload bits required = 88 bits (11 raw bytes)
    """
    # 1. Arrange the parameters to a continuous integer based on standard sequential bit alignments
    bit_payload = 0
    bit_payload |= (0 & 0x07)          # Bits 0-2: Version (0)
    bit_payload |= (vid & 0xFFFF) << 3 # Bits 3-18: Vendor ID
    bit_payload |= (pid & 0xFFFF) << 19 # Bits 19-34: Product ID
    bit_payload |= (0 & 0x03) << 35    # Bits 35-36: Commissioning Flow (0)
    bit_payload |= (4 & 0xFF) << 37    # Bits 37-44: Discovery Capabilities (4 = BLE)
    bit_payload |= (discriminator & 0xFFF) << 45 # Bits 45-56: 12-bit Discriminator
    bit_payload |= (passcode & 0x7FFFFFF) << 57  # Bits 57-83: 27-bit Passcode
    # Bits 84-87 are trailing 0 padding up to full data array byte structures
    
    # 2. Convert the accumulated bit sequence string into explicit 11 raw data bytes
    raw_bytes = []
    temp_payload = bit_payload
    for _ in range(11):
        raw_bytes.append(temp_payload & 0xFF)
        temp_payload >>= 8

    # 3. Base38 Character Map definitions 
    BASE38_CHARS = "0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZ-."
    base38_encoded_string = ""
    
    # Group every 3 distinct raw data bytes into precise 5-character alphanumeric Base38 blocks
    # Length of 11 bytes splits cleanly into: three 3-byte blocks + one trailing 2-byte block
    byte_index = 0
    while byte_index < len(raw_bytes):
        remaining_bytes = len(raw_bytes) - byte_index
        chunk_value = 0
        char_count = 0
        
        if remaining_bytes >= 3:
            # 3-byte chunk expands into an integer, converted into 5 Base38 symbol structures
            chunk_value = raw_bytes[byte_index] | (raw_bytes[byte_index+1] << 8) | (raw_bytes[byte_index+2] << 16)
            char_count = 5
            byte_index += 3
        else:
            # Trailing 2-byte chunk converts into 4 Base38 characters
            chunk_value = raw_bytes[byte_index] | (raw_bytes[byte_index+1] << 8)
            char_count = 4
            byte_index += 2
            
        # Extract the Base38 positional index keys
        for _ in range(char_count):
            base38_encoded_string += BASE38_CHARS[chunk_value % 38]
            chunk_value //= 38
            
    return f"MT:{base38_encoded_string}"

def main():
    parser = argparse.ArgumentParser(description="Open Sesame Thermal Production Label Generator")
    parser.add_argument("--discriminator", type=int, required=True)
    parser.add_argument("--passcode", type=int, required=True)
    parser.add_argument("--mac", type=str, required=True)
    args = parser.parse_args()

    # 1. Compute the exact pairing payload string matching target NVS partitions dynamically
    qr_payload = generate_matter_qr_payload(args.discriminator, args.passcode)
    print(f"[Printer] Math Compiler generated a valid Matter BLE pairing string layout: {qr_payload}")

    qr = qrcode.QRCode(version=1, box_size=10, border=0)
    qr.add_data(qr_payload)
    qr.make(fit=True)
    qr_img = qr.make_image(fill_color="black", back_color="white")
    qr_path = "temp_qr.png"
    qr_img.save(qr_path)

    logo_path = "logo.png"
    if not os.path.exists(logo_path):
        print("⚠️  Warning: 'logo.png' not found. Creating a generic temporary placeholder logo text graphic.")
        from PIL import Image as PILImage, ImageDraw
        img = PILImage.new('RGB', (150, 75), color = (0, 0, 0))
        d = ImageDraw.Draw(img)
        d.text((10,30), "OPEN SESAME", fill=(255,255,255))
        img.save(logo_path)

    # 2. Formulate the Label Canvas Blueprint Layout (Standard 4" x 2" Thermal Layout)
    pdf_filename = "print_job.pdf"
    doc = SimpleDocTemplate(
        pdf_filename,
        pagesize=(4 * inch, 2 * inch),
        leftMargin=0.05 * inch,
        rightMargin=0.05 * inch,
        topMargin=0.05 * inch,
        bottomMargin=0.05 * inch,
        title="Production Manufacturing Label Layout"
    )

    # Instantiate ReportLab image objects for grid distribution injection
    logo_widget = Image(logo_path, width=1.5 * inch, height=0.65 * inch)
    main_qr_widget = Image(qr_path, width=1.1 * inch, height=1.1 * inch)
    sub_qr_widget = Image(qr_path, width=0.6 * inch, height=0.6 * inch)

    # Create Paragraph Style for clean human-readable MAC text under the primary code block
    styles = getSampleStyleSheet()
    mac_style = ParagraphStyle(
        'MacStyle',
        parent=styles['Normal'],
        fontName='Helvetica-Bold',
        fontSize=7,
        leading=8,
        alignment=1 # Centered
    )
    mac_text = Paragraph(f"MAC: {args.mac.upper()}", mac_style)

    # Construct the 4-quadrant layout array map structure grid matrix
    data = [
        [logo_widget, sub_qr_widget],    # Row 1: Logo next to QR Item 2
        [main_qr_widget, sub_qr_widget], # Row 2: Main Pairing QR 1 next to QR Item 3
        [mac_text, sub_qr_widget]        # Row 3: MAC Text block next to QR Item 4
    ]

    # Render spacing constraints and layout grid cell dimensions
    label_table = Table(data, colWidths=[2.3 * inch, 1.6 * inch], rowHeights=[0.7 * inch, 0.6 * inch, 0.6 * inch])
    label_table.setStyle(TableStyle([
        ('ALIGN', (0,0), (-1,-1), 'CENTER'),
        ('VALIGN', (0,0), (-1,-1), 'MIDDLE'),
        ('SPAN', (0,1), (0,1)), # Binds the main QR cleanly to its target center row location
        ('BOTTOMPADDING', (0,0), (-1,-1), 1),
        ('TOPPADDING', (0,0), (-1,-1), 1),
    ]))

    story = [label_table]
    doc.build(story)

    # 3. Fire the Output Payload Directly down to the OS Default Desktop Printer Spooler
    print("[Printer] Shipping binary graphics payload directly out to system print buffer tracking queues...")
    try:
        if sys.platform == "win32":
            os.startfile(pdf_filename, "print")
        else:
            subprocess.run(["lp", pdf_filename], check=True)
        print("🎉 SUCCESS: Label layout processed cleanly down to the physical hardware terminal unit.")
    except Exception as e:
        print(f"❌ PRINTER PIPELINE FAILURE: Details: {e}")
        print(f"💡 You can manually open and verify the generated layout inside the folder: {pdf_filename}")

    if os.path.exists(qr_path):
        os.remove(qr_path)

if __name__ == "__main__":
    main()
