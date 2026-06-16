# roboto_motors — Python API

## Import

```python
from motors_py import MotorDriver, MotorControlMode
```

## MotorControlMode

```python
MotorControlMode.NONE   # 0
MotorControlMode.MIT    # 1 — impedance control
MotorControlMode.POS    # 2 — position control
MotorControlMode.SPD    # 3 — speed control
```

---

## MotorDriver.create_motor (factory)

```python
motor = MotorDriver.create_motor(
    motor_id,          # int: CAN node ID
    interface_type,    # str: "can" or "canfd"
    interface,         # str: CAN interface name, e.g. "can0"
    motor_type,        # str: "DM" / "EVO" / "LRO"
    motor_model,       # int: model enum value
    master_id_offset=0,# int: DM master offset (optional, default 0)
    motor_zero_offset=0.0  # float: rad (optional, default 0.0)
)
```

**motor_type** & **motor_model** mapping:

| `motor_type` | model 0 | model 1 | model 2 | model 3 | model 4 |
|---|---|---|---|---|---|
| `"DM"` | DM4340P_48V | DM10010L_48V | — | — | — |
| `"EVO"` | EVO431040 | EVO811825 | EVO811832 | — | — |
| `"LRO"` | LRO_5550 | LRO_6562 | LRO_8462 | LRO_10062 | — |

```python
# DM motor
motor = MotorDriver.create_motor(0x01, "can", "can0", "DM", 0)

# EVO motor
motor = MotorDriver.create_motor(0x01, "can", "can0", "EVO", 0)

# LRO motor
motor = MotorDriver.create_motor(0x01, "canfd", "can0", "LRO", 0)
```

---

## Lifecycle

### `motor.init_motor()`

Enable the motor and enter default control mode (POS). Returns error code as `int`.

```python
err = motor.init_motor()
if err != 0:
    print(f"init error: 0x{err:02X}")
```

### `motor.deinit_motor()`

Stop and disable the motor.

```python
motor.deinit_motor()
```

---

## Control

### `motor.set_motor_control_mode(mode)`

Switch control mode before sending commands.

```python
motor.set_motor_control_mode(MotorControlMode.MIT)
motor.set_motor_control_mode(MotorControlMode.POS)
motor.set_motor_control_mode(MotorControlMode.SPD)
```

### `motor.motor_mit_cmd(pos, vel, kp, kd, torque)`

MIT impedance control. Mode must be MIT.

| Arg | Type | Unit | Description |
|---|---|---|---|
| `pos` | float | rad | Target position |
| `vel` | float | rad/s | Target velocity |
| `kp` | float | Nm/rad | Position stiffness gain |
| `kd` | float | Nm/(rad/s) | Velocity damping gain |
| `torque` | float | Nm | Feed-forward torque |

```python
motor.set_motor_control_mode(MotorControlMode.MIT)
motor.motor_mit_cmd(0.0, 0.0, 10.0, 1.0, 0.0)  # hold position, soft stiffness
```

### `motor.motor_pos_cmd(pos, spd, ignore_limit=False)`

Position control. Mode must be POS.

| Arg | Type | Unit | Description |
|---|---|---|---|
| `pos` | float | rad | Target position |
| `spd` | float | rad/s | Speed limit (0 = no limit) |
| `ignore_limit` | bool | — | Bypass position limits |

```python
motor.set_motor_control_mode(MotorControlMode.POS)
motor.motor_pos_cmd(1.57, 3.14)           # move to 90° at max ~180°/s
motor.motor_pos_cmd(-0.5, 1.0, False)    # move to -0.5 rad, limit 1 rad/s
```

### `motor.motor_spd_cmd(spd)`

Speed control. Mode must be SPD.

| Arg | Type | Unit | Description |
|---|---|---|---|
| `spd` | float | rad/s | Target velocity |

```python
motor.set_motor_control_mode(MotorControlMode.SPD)
motor.motor_spd_cmd(3.14)   # rotate at ~180°/s
motor.motor_spd_cmd(-1.57)  # reverse at ~90°/s
```

---

## Configuration

### `motor.lock_motor()`

Enable motor hardware (equivalent to step 1 of init).

```python
motor.lock_motor()
```

### `motor.unlock_motor()`

Stop and disable motor hardware.

```python
motor.unlock_motor()
```

### `motor.set_motor_zero()`

Set current position as the new zero reference. Returns `bool`.

```python
ok = motor.set_motor_zero()
if not ok:
    print("zero setting failed")
```

### `motor.write_motor_flash()`

Persist current parameters to flash memory. Returns `bool`.

```python
motor.write_motor_flash()
```

### `motor.clear_motor_error()`

Clear active error flags on the motor.

```python
motor.clear_motor_error()
```

### `motor.reset_motor_id()`

Reset the motor's CAN ID to factory default.

```python
motor.reset_motor_id()
```

### `motor.refresh_motor_status()`

Send a request to update telemetry (position, speed, torque, temperature).

```python
motor.refresh_motor_status()
```

---

## Feedback (Getters)

| Method | Return | Unit | Description |
|---|---|---|---|
| `motor.get_motor_pos()` | float | rad | Current position |
| `motor.get_motor_spd()` | float | rad/s | Current velocity |
| `motor.get_motor_current()` | float | A | Phase current (or torque Nm for some motors) |
| `motor.get_motor_temperature()` | float | °C | Motor winding temperature |
| `motor.get_motor_id()` | int | — | CAN node ID |
| `motor.get_motor_control_mode()` | int | — | Current mode: 0=NONE, 1=MIT, 2=POS, 3=SPD |
| `motor.get_error_id()` | int | — | Error code (0 = no error) |
| `motor.get_response_count()` | int | — | CAN transmit counter for the motor instance |
| `motor.get_can_name()` | str | — | CAN interface name (e.g. "can0") |

```python
# Poll feedback
pos = motor.get_motor_pos()
spd = motor.get_motor_spd()
temp = motor.get_motor_temperature()
err = motor.get_error_id()

if err != 0:
    print(f"motor {motor.get_motor_id()} error: 0x{err:02X}")
    motor.clear_motor_error()
```

---

## Low-Level Parameter Access

### `motor.get_motor_param(param_cmd)`

Request parameter read from the motor. Param codes vary by motor type.

```python
motor.get_motor_param(0x01)  # e.g. read LPF params (XYN)
```

---

## Full Example

```python
from motors_py import MotorDriver, MotorControlMode

# Create and init
motor = MotorDriver.create_motor(
    motor_id=0x01,
    interface_type="can",
    interface="can0",
    motor_type="DM",
    motor_model=0,
    motor_zero_offset=0.0
)
err = motor.init_motor()
if err != 0:
    raise RuntimeError(f"init error: 0x{err:02X}")

# MIT impedance control
motor.set_motor_control_mode(MotorControlMode.MIT)

import time
for _ in range(1000):
    motor.motor_mit_cmd(0.0, 0.0, 10.0, 1.0, 0.0)
    pos = motor.get_motor_pos()
    temp = motor.get_motor_temperature()
    print(f"pos={pos:.3f} rad, temp={temp:.1f} °C")
    time.sleep(0.001)

motor.deinit_motor()
```
