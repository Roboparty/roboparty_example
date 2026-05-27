#!/usr/bin/env python3

# SPDX-License-Identifier: GPL-3.0
# Copyright (C) 2026 wentywenty

import motors_py as mpy
import time

# 创建电机实例
m_list = []
for bus_name in ["can6", "can7"]:
    # 每条总线上挂载 7 个电机 (ID 1~7)
    for motor_id in range(1, 8):
        # 参数：电机ID、接口类型、接口名称、品牌、模型索引
        motor = mpy.MotorDriver.create_motor(motor_id, "canfd", bus_name, "LRO", 0)
        m_list.append(motor)

# 2. 批量解锁（允许手动转动到零位）
print("正在释放电机，以便手动对齐零位...")

for motor in m_list:
    motor.lock_motor()  # 发送解除锁定指令
for motor in m_list:
    motor.unlock_motor()  # 发送解除锁定指令

time.sleep(1.0)

print(">>> 请手动将所有关节移动到理想的机械零点位置 <<<")
input("对齐完成后，按回车键开始 [批量零位校准]...")

# 3. 批量归零
print("正在执行零位校准并写入电机控制参数...")
for motor in m_list:
    # 调用底层 LRO 归零指令 (0x03)
    motor.set_motor_zero()

time.sleep(1.0)  # 等待电机内部 Flash 写入完成

# 4. 最终状态验证
print("校准完成！当前系统读数：")
for motor in m_list:
    motor.refresh_motor_status()  # 请求电机状态更新

time.sleep(0.1)  # 等待总线回包

# 打印各电机位置
for motor in m_list:
    print(f"电机 {motor.get_motor_id()} @ {motor.get_can_name()}: {motor.get_motor_pos():.4f} rad")

print("零点校准成功。现在可以安全断电或开始正常控制。")
for motor in m_list:
    motor.lock_motor()  # 发送解除锁定指令
