# Realm AIO 一键脚本（中转机 / 落地机 / TLS / WS / WSS）

这是一个 **Realm（https://github.com/zhboner/realm）的一键部署脚本**，  
将 **中转机（入口）** 和 **落地机（出口）** 的配置逻辑融合在 **同一个脚本** 中，支持：

- 自动检测 CPU 架构并下载对应的 realm 二进制
- 交互式向导（wizard），一键生成配置
- 同时支持：
  - plain（明文）
  - TLS（加密）
  - WS（WebSocket 伪装）
  - **WSS（WS + TLS，加密 + 伪装，推荐）**
- 落地机可 **自动生成 TLS 自签证书**
- 自动创建 systemd 服务并设置开机自启

---

## 一、仓库结构建议

```text
.
├── realm-aio.sh
└── README.md
```
二、支持的模式说明（非常重要）
| 模式      | 是否加密 | 是否伪装 | 说明                 |
| ------- | ---- | ---- | ------------------ |
| plain   | ❌    | ❌    | 明文 TCP/UDP 转发，仅测试用 |
| TLS     | ✅    | ❌    | 纯 TLS 加密           |
| WS      | ❌    | ✅    | WebSocket 伪装，不加密   |
| **WSS** | ✅    | ✅    | **WS + TLS（推荐）**   |

## 🚀 公网中转 **强烈推荐使用 TLS WSS**


三、快速开始（推荐流程）
1️⃣ 在【落地机】执行（先做）
```sh
sudo bash realm-aio.sh wizard
```

选择：

2) 落地机（出口）

加密方式建议选：4) WSS

脚本会提示你是否生成 TLS 证书（建议选 y）

示例输入：
```sh
listen  = 0.0.0.0:20000
remote  = 127.0.0.1:443
```

落地机负责：

接收中转机的加密流量

解密后转发到真实目标（本机或其他服务器）

2️⃣ 在【中转机】执行（后做）
sudo bash realm-aio.sh wizard


选择：

1) 中转机（入口）

加密方式必须和落地机一致

remote 填写：落地机IP:端口

示例输入：
```sh
listen = 0.0.0.0:10000
remote = 落地机IP:20000
```
四、端口转发示意图（WSS）
客户端
   |
   |  (WSS / TLS 加密 + WS 伪装)
   v
中转机 :10000
   |
   |  (WSS)
   v
落地机 :20000
   |
   |  (明文)
   v
真实目标 (127.0.0.1:443 / 8.8.8.8:222)


五、配置文件位置
| 项目         | 路径                                  |
| ---------- | ----------------------------------- |
| realm 二进制  | `/usr/local/bin/realm`              |
| 主配置文件      | `/etc/realm/realm.toml`             |
| TLS 证书     | `/etc/realm/certs/realm.crt`        |
| TLS 私钥     | `/etc/realm/certs/realm.key`        |
| systemd 服务 | `/etc/systemd/system/realm.service` |

六、常用命令
查看状态
```sh
sudo systemctl status realm
```
重启服务
```sh
sudo systemctl restart realm
```
修改配置后生效
```sh
sudo systemctl restart realm
```
七、卸载
```sh
sudo bash realm-aio.sh uninstall
```
会自动：
- 停止服务
- 删除 realm 二进制
- 删除配置文件
- 删除 systemd 服务

八、常见问题（FAQ）
Q1：plain 是什么？安全吗？
- plain = 明文直连
- 不加密、不伪装
- 不建议公网使用

Q2：TLS / WSS 为什么要用 insecure？
- 落地机通常使用自签证书
- 中转机无法校验证书
- insecure = 允许自签（这是正常用法）

Q3：一个端口能写多个 endpoints 吗？
- 不建议
- 同一端口重复 listen 通常会冲突
- 建议：一个 listen 对应一个 remote

Q4：realm 支持 UDP 吗？
- 支持
- 脚本中可选择是否启用 UDP

九、安全与合规提醒

本脚本仅用于 网络加速 / 中转 / 合法用途

请遵守你所在地的法律法规

作者不对任何滥用行为负责

十、推荐组合（实战）
| 场景      | 推荐方案     |
| ------- | -------- |
| 公网中转    | **WSS**  |
| 内网 / 专线 | TLS      |
| 调试      | plain    |
| 伪装优先    | WS / WSS |


