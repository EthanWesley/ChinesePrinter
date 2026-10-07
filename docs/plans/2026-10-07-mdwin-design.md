# 医智赢编码支持

参考来源：`F:/E_backup/FastInput/Reason/weixin-frontend/utils/BleManager.js`
中的 `stringToMdwinUnicodeBytes`。

网页新增 `mdwin` 编码选项。可打印 ASCII（含空格）及非 ASCII 字符按
UTF-16 单元计算 `charCode ^ 996`，生成十进制 Alt 码。补充平面字符保持
参考实现的双 UTF-16 单元行为。参考 BLE 协议中的 18/19 包裹标记对应
Alt 按下/释放，由现有 Shell/C HID 引擎执行，无需发送这些标记本身。

换行、Tab、退格及 Esc 使用现有控制键。CR 沿用网页既有的忽略规则，
避免 CRLF 重复换行；其余没有文本输入键映射的非打印 ASCII 忽略。
服务端按请求中的原始顺序解析数字码和控制键，保证混合文本顺序。

目标电脑需安装并启用医智赢输入法。既有 GBK、Unicode、ASCII、Base64
编码路径继续使用原来的转换规则。医智赢转换无需 GBK 表。

验证覆盖固定编码向量、空格、代理对、控制键、既有编码回归、API 请求
和服务端序列顺序，并与本地参考转换函数逐项比对。实际 USB 输入及
目标电脑输入法解码需要在设备上验收。

运行回归检查：`node tests/encoding.test.cjs`（服务端解析检查需要 awk；
Windows 默认使用 Git Bash，可用 `TEST_BASH` 指定其路径）。
