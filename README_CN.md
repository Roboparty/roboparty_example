# roboparty_py_example

RoboParty 机器人平台 Python SDK 示例脚本，包含电机控制、IMU 读取、动作回放和零位标定。

## 脚本说明

| 脚本 | 功能 |
|---|---|
| `motors_py_example.py` | CAN 电机控制示例（DM 电机） |
| `imu_py_example.py` | IMU 读取示例（串口/CAN，HiPNUC） |
| `motion_player.py` | 动作文件回放（`.npz` 格式） |
| `set_zero.py` | 交互式零位标定工具 |

## 安装

```bash
./build_deb.sh
sudo dpkg -i roboparty-py-example_*.deb
```

脚本安装到 `/opt/roboparty/sample/` 目录下。

## 使用

```bash
cd /opt/roboparty/sample
python3 motors_py_example.py
python3 imu_py_example.py
python3 motion_player.py --motion <动作文件.npz>
python3 set_zero.py
```

## 依赖

- `roboparty-base` (>= 1.0.0)
- `roboparty-motors` (>= 1.0.0)
- `roboparty-imu` (>= 1.0.0)
