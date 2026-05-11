#!/usr/bin/env python3
"""Move Hermes Pets window to visible position."""
import subprocess, sys

def main():
    target_x, target_y = int(sys.argv[1]) if len(sys.argv) > 1 else 100, int(sys.argv[2]) if len(sys.argv) > 2 else 100
    
    # Try wmctrl first
    try:
        r = subprocess.run(['wmctrl', '-i', '-r', '0x5400004', '-e', f'0,{target_x},{target_y},280,340'],
                          capture_output=True, text=True, timeout=5)
        if r.returncode == 0:
            print(f"Window moved to ({target_x}, {target_y}) via wmctrl")
            return
    except FileNotFoundError:
        pass
    
    # Fallback: use xprop + xdpyinfo to find and move
    try:
        r = subprocess.run(['xdotool', 'search', '--name', 'Hermes Pets', 'windowmove', str(target_x), str(target_y)],
                          capture_output=True, text=True, timeout=5)
        if r.returncode == 0:
            print(f"Window moved to ({target_x}, {target_y}) via xdotool")
            return
    except FileNotFoundError:
        pass
    
    # Last resort: use X11 via ctypes
    try:
        import ctypes
        import ctypes.util
        xlib = ctypes.CDLL(ctypes.util.find_library('X11'))
        display = xlib.XOpenDisplay(None)
        if display:
            # Get root window
            root = xlib.XDefaultRootWindow(display)
            # Find Hermes Pets window by iterating
            from ctypes import c_int, c_uint, POINTER, Structure, byref
            
            class XWindowAttributes(Structure):
                _fields_ = [("x", c_int), ("y", c_int), ("width", c_int), ("height", c_int),
                           ("border_width", c_int), ("depth", c_int), ("visual", c_void_p),
                           ("root", c_void_p), ("class", c_int), ("bit_gravity", c_int),
                           ("win_gravity", c_int), ("backing_store", c_int),
                           ("backing_planes", c_uint), ("backing_pixel", c_uint),
                           ("save_under", c_int), ("colormap", c_void_p),
                           ("map_installed", c_int), ("map_state", c_int),
                           ("all_event_masks", c_uint), ("your_event_mask", c_uint),
                           ("do_not_propagate_mask", c_uint), ("override_redirect", c_int)]
            
            wa = XWindowAttributes()
            target_wid = 0x5400004
            xlib.XGetWindowAttributes(display, target_wid, byref(wa))
            xlib.XMoveResizeWindow(display, target_wid, target_x, target_y, 280, 340)
            xlib.XFlush(display)
            xlib.XCloseDisplay(display)
            print(f"Window moved to ({target_x}, {target_y}) via X11 ctypes")
            return
    except Exception as e:
        print(f"X11 ctypes failed: {e}")
    
    print("Could not move window - no suitable tool found")
    print("Try: sudo apt install wmctrl xdotool")

if __name__ == '__main__':
    main()
