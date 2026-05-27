# roboparty_py_example

Python SDK example scripts for the RoboParty robot platform, demonstrating motor control, IMU reading, motion playback and zero-position calibration.

## Scripts

| Script | Description |
|---|---|
| `motors_py_example.py` | CAN motor control example (DM motors) |
| `imu_py_example.py` | IMU reading via serial/CAN (HiPNUC) |
| `motion_player.py` | Motion file playback (`.npz` format) |
| `set_zero.py` | Interactive zero-position calibration tool |

## Install

```bash
./build_deb.sh
sudo dpkg -i roboparty-py-example_*.deb
```

Scripts are installed to `/opt/roboparty/sample/`.

## Usage

```bash
cd /opt/roboparty/sample
python3 motors_py_example.py
python3 imu_py_example.py
python3 motion_player.py --motion <motion_file.npz>
python3 set_zero.py
```

## Dependencies

- `roboparty-base` (>= 1.0.0)
- `roboparty-motors` (>= 1.0.0)
- `roboparty-imu` (>= 1.0.0)
