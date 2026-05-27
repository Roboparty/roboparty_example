#!/usr/bin/env python3

# SPDX-License-Identifier: GPL-3.0
# Copyright (C) 2026 wentywenty

import motors_py as mpy
import time

# Create motor instances.
m_list = []
for bus_name in ["can8", "can9"]:
    for mid in range(1, 6):  # Assume 5 motors per bus (IDs 1-5)
        # Parameters: ID, interface_type, interface_name, brand, model_idx
        m = mpy.MotorDriver.create_motor(mid, "canfd", bus_name, "EVO", 0)
        m_list.append(m)

# 2. Synchronous Enable (Batch Lock)
print("Executing synchronized motor enablement...")

for m in m_list:
    m.lock_motor()
for m in m_list:
    m.unlock_motor()
    
time.sleep(1.0)  # Wait for mechanical feedback (listening for the 'click' of the motors)

print(">>> Please manually move all joints to the desired physical zero position <<<")
input("Once positions are aligned, press Enter to start [Batch Zero Calibration]...")

# 3. Synchronous Zero-Setting and Flash Burning (0xFE Mode)
print("Calibrating zero positions and burning to Flash...")
for m in m_list:
    m.set_motor_zero() 

time.sleep(2.0)  # Allow sufficient time for Flash memory write operations

# 4. Final Verification
print("Calibration complete! Current system readings:")
for m in m_list:
    m.refresh_motor_status()  # Request status update from motors

time.sleep(0.1)  # Brief pause for bus response

for m in m_list:
    print(f"Motor {m.get_motor_id()} @ {m.get_can_name()}: {m.get_motor_pos()} rad")

print("Zero-point calibration successful. It is now safe to power down.")

for m in m_list:
    m.lock_motor()
