#!/usr/bin/env python3

# SPDX-License-Identifier: GPL-3.0
# Copyright (C) 2026 wentywenty

import bms_py
import time

def main():
    # 1. Create BMS instance
    # Supported types depend on the implementation, common types might be "TWS" or "standard"
    # The second parameter is the Unix Domain Socket path used by the BMS daemon
    print(">>> Connecting to BMS daemon...")
    bms = bms_py.BmsDriver.create_bms("TWS", "/tmp/bms.sock")

    # 2. Check connection status
    if not bms.is_connected():
        print("Error: Could not connect to BMS daemon. Make sure bms_node is running.")
        return

    print(">>> BMS Connected. Reading battery status...\n")

    try:
        while True:
            # 3. Read basic battery metrics
            voltage = bms.get_voltage()      # V
            current = bms.get_current()      # A
            temp = bms.get_temperature()     # Celsius
            percentage = bms.get_percentage() # 0-100%
            
            # 4. Read advanced information
            capacity = bms.get_capacity()    # Ah
            soh = bms.get_soh()              # State of Health (%)
            cycles = bms.get_cycles()        # Charge cycles
            
            # 5. Cell-level info (if supported)
            v_max = bms.get_max_cell_voltage()
            v_min = bms.get_min_cell_voltage()

            print("-" * 40)
            print(f"Status:      {bms.get_work_state()}")
            print(f"SoC:         {percentage:.1f}%")
            print(f"Voltage:     {voltage:.2f} V")
            print(f"Current:     {current:.2f} A")
            print(f"Temperature: {temp:.1f} °C")
            print(f"SOH:         {soh:.1f}%")
            print(f"Cycles:      {cycles}")
            print(f"Cell Delta:  {(v_max - v_min)*1000:.1f} mV (Max: {v_max:.3f}V, Min: {v_min:.3f}V)")
            
            # Check for protection flags
            protect = bms.get_protect_status()
            if protect != 0:
                print(f"WARNING: BMS Protection Flag Active (0x{protect:X})")

            time.sleep(1.0)
            
    except KeyboardInterrupt:
        print("\n>>> Monitoring stopped.")

if __name__ == "__main__":
    main()
