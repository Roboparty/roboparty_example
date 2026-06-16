# roboto_motors — Python API

## 导入

```python
from motors_py import MotorDriver, MotorControlMode
```

## MotorControlMode（控制模式枚举）

```python
MotorControlMode.NONE   # 0 — 无模式
MotorControlMode.MIT    # 1 — 阻抗控制
MotorControlMode.POS    # 2 — 位置控制
MotorControlMode.SPD    # 3 — 速度控制
```

---

## MotorDriver.create_motor（工厂方法）

```python
motor = MotorDriver.create_motor(
    motor_id,          # int: CAN 节点 ID
    interface_type,    # str: "can" 或 "canfd"
    interface,         # str: CAN 接口名，如 "can0"
    motor_type,        # str: "DM" / "EVO" / "LRO"
    motor_model,       # int: 型号枚举值
    master_id_offset=0,# int: DM 主站 ID 偏移（可选，默认 0）
    motor_zero_offset=0.0  # float: 零位偏移，单位 rad（可选，默认 0.0）
)
```

**motor_type** 与 **motor_model** 对照表：

| `motor_type` | 0 | 1 | 2 | 3 | 4 |
|---|---|---|---|---|---|
| `"DM"` | DM4340P_48V | DM10010L_48V | — | — | — |
| `"EVO"` | EVO431040 | EVO811825 | EVO811832 | — | — |
| `"LRO"` | LRO_5550 | LRO_6562 | LRO_8462 | LRO_10062 | — |

```python
# DM 达妙电机
motor = MotorDriver.create_motor(0x01, "can", "can0", "DM", 0)

# EVO 电机
motor = MotorDriver.create_motor(0x01, "can", "can0", "EVO", 0)

# LRO LeadRobot 电机
motor = MotorDriver.create_motor(0x01, "canfd", "can0", "LRO", 0)
```

---

## 生命周期

### `motor.init_motor()`

使能电机并进入默认控制模式（POS）。返回错误码（int）。

```python
err = motor.init_motor()
if err != 0:
    print(f"初始化错误: 0x{err:02X}")
```

### `motor.deinit_motor()`

停止并失能电机。

```python
motor.deinit_motor()
```

---

## 控制

### `motor.set_motor_control_mode(mode)`

切换控制模式。发送控制指令前必须先设置模式。

```python
motor.set_motor_control_mode(MotorControlMode.MIT)
motor.set_motor_control_mode(MotorControlMode.POS)
motor.set_motor_control_mode(MotorControlMode.SPD)
```

### `motor.motor_mit_cmd(pos, vel, kp, kd, torque)`

MIT 阻抗控制。当前模式必须为 MIT。

| 参数 | 类型 | 单位 | 说明 |
|---|---|---|---|
| `pos` | float | rad | 目标位置 |
| `vel` | float | rad/s | 目标速度 |
| `kp` | float | Nm/rad | 位置刚度增益 |
| `kd` | float | Nm/(rad/s) | 速度阻尼增益 |
| `torque` | float | Nm | 前馈力矩 |

```python
motor.set_motor_control_mode(MotorControlMode.MIT)
motor.motor_mit_cmd(0.0, 0.0, 10.0, 1.0, 0.0)  # 保持位置，较低刚度
```

### `motor.motor_pos_cmd(pos, spd, ignore_limit=False)`

位置控制。当前模式必须为 POS。

| 参数 | 类型 | 单位 | 说明 |
|---|---|---|---|
| `pos` | float | rad | 目标位置 |
| `spd` | float | rad/s | 速度限制（0 = 不限速） |
| `ignore_limit` | bool | — | 是否忽略位置限位 |

```python
motor.set_motor_control_mode(MotorControlMode.POS)
motor.motor_pos_cmd(1.57, 3.14)           # 转到 90°，最高 ~180°/s
motor.motor_pos_cmd(-0.5, 1.0, False)    # 转到 -0.5 rad，限速 1 rad/s
```

### `motor.motor_spd_cmd(spd)`

速度控制。当前模式必须为 SPD。

| 参数 | 类型 | 单位 | 说明 |
|---|---|---|---|
| `spd` | float | rad/s | 目标角速度 |

```python
motor.set_motor_control_mode(MotorControlMode.SPD)
motor.motor_spd_cmd(3.14)   # 正向旋转 ~180°/s
motor.motor_spd_cmd(-1.57)  # 反向旋转 ~90°/s
```

---

## 配置

### `motor.lock_motor()`

使能电机驱动电路（等效于 init 的第一步）。

```python
motor.lock_motor()
```

### `motor.unlock_motor()`

停止并断开电机驱动电路。

```python
motor.unlock_motor()
```

### `motor.set_motor_zero()`

将当前位置设置为新的零位参考点。返回 `bool`。

```python
ok = motor.set_motor_zero()
if not ok:
    print("调零失败")
```

### `motor.write_motor_flash()`

将当前参数写入 Flash 持久保存。返回 `bool`。

```python
motor.write_motor_flash()
```

### `motor.clear_motor_error()`

清除电机当前错误标志。

```python
motor.clear_motor_error()
```

### `motor.reset_motor_id()`

将电机的 CAN ID 恢复为出厂默认值。

```python
motor.reset_motor_id()
```

### `motor.refresh_motor_status()`

主动请求电机上报当前遥测数据（位置、速度、力矩、温度）。

```python
motor.refresh_motor_status()
```

---

## 反馈数据（Getter）

| 方法 | 返回类型 | 单位 | 说明 |
|---|---|---|---|
| `motor.get_motor_pos()` | float | rad | 当前位置 |
| `motor.get_motor_spd()` | float | rad/s | 当前角速度 |
| `motor.get_motor_current()` | float | A | 相电流（部分电机为力矩 Nm） |
| `motor.get_motor_temperature()` | float | °C | 电机绕组温度 |
| `motor.get_motor_id()` | int | — | CAN 节点 ID |
| `motor.get_motor_control_mode()` | int | — | 当前模式: 0=NONE, 1=MIT, 2=POS, 3=SPD |
| `motor.get_error_id()` | int | — | 错误码（0 = 无错误） |
| `motor.get_response_count()` | int | — | 该电机实例的 CAN 发送计数 |
| `motor.get_can_name()` | str | — | CAN 接口名称（如 "can0"） |

```python
# 读取反馈
pos = motor.get_motor_pos()
spd = motor.get_motor_spd()
temp = motor.get_motor_temperature()
err = motor.get_error_id()

if err != 0:
    print(f"电机 {motor.get_motor_id()} 错误: 0x{err:02X}")
    motor.clear_motor_error()
```

---

## 底层参数访问

### `motor.get_motor_param(param_cmd)`

请求从电机读取指定参数。param_cmd 取值因电机型号而异。

```python
motor.get_motor_param(0x01)  # 如读取 LPF 参数（XYN）
```

---

## 完整示例

```python
from motors_py import MotorDriver, MotorControlMode
import time

# 创建并初始化
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
    raise RuntimeError(f"初始化错误: 0x{err:02X}")

# MIT 阻抗控制
motor.set_motor_control_mode(MotorControlMode.MIT)

for _ in range(1000):
    motor.motor_mit_cmd(0.0, 0.0, 10.0, 1.0, 0.0)
    pos = motor.get_motor_pos()
    temp = motor.get_motor_temperature()
    print(f"位置={pos:.3f} rad, 温度={temp:.1f} °C")
    time.sleep(0.001)

motor.deinit_motor()
```
