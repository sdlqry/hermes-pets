#!/usr/bin/env python3
"""Screenshot Hermes Pets window using mss"""
import mss
import time

time.sleep(1)

with mss.MSS() as sct:
    # Get monitor info
    monitor = sct.monitors[1]  # Primary monitor
    print(f"Monitor: {monitor}")
    
    # Screenshot the area where Hermes Pets window should be
    # Window is at (1500, 600), size 280x340
    # But let's screenshot a larger area to make sure we capture it
    region = {
        "left": 1480,
        "top": 580,
        "width": 320,
        "height": 380,
        "monitor": 1
    }
    
    shot = sct.grab(region)
    
    # Check if the captured image has any non-black pixels
    from PIL import Image
    img = Image.frombytes("RGB", shot.size, shot.bgra, "raw", "BGRX")
    
    # Count non-black pixels
    pixels = list(img.getdata())
    non_black = sum(1 for p in pixels if p != (0, 0, 0))
    total = len(pixels)
    
    print(f"Region: {shot.size}")
    print(f"Non-black pixels: {non_black}/{total} ({non_black/total*100:.1f}%)")
    
    if non_black > total * 0.01:
        print("Window IS rendering content!")
    else:
        print("Window appears to be empty/transparent - NOT visible")
    
    # Also check the entire screen for any hermes-pet-like content
    full_shot = sct.grab(monitor)
    full_img = Image.frombytes("RGB", full_shot.size, full_shot.bgra, "raw", "BGRX")
    full_pixels = list(full_img.getdata())
    full_non_black = sum(1 for p in full_pixels if p != (0, 0, 0))
    print(f"\nFull screen non-black: {full_non_black}/{len(full_pixels)} ({full_non_black/len(full_pixels)*100:.1f}%)")
    
    # Save screenshots
    img.save("/tmp/hermes-pet-region.png")
    full_img.save("/tmp/hermes-pet-fullscreen.png")
    print("Screenshots saved to /tmp/hermes-pet-region.png and /tmp/hermes-pet-fullscreen.png")
