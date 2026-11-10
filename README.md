# 一键部署 VLESS + Reality 节点（AWS Lightsail）

在 AWS CloudShell 里粘贴一条命令，几分钟后得到一条 `vless://` 链接和二维码，导入客户端就能用。

- 服务器：AWS Lightsail 最便宜的带公网 IPv4 的 Linux 套餐（美国区域约 5 美元/月，含 1TB 流量）
- 协议：VLESS + Reality + xtls-rprx-vision，服务端是纯 Xray，没有面板
- 区域、套餐、系统、密钥全部自动决定，不需要填任何配置

## 前提

一个 AWS 账号。新注册的账号通常只能在注册时分配的区域使用 Lightsail，脚本会自动用你当前所在的区域。

## 部署

1. 登录 [AWS 控制台](https://console.aws.amazon.com/)，点顶栏的 CloudShell 图标（`>_`）打开终端。
2. 粘贴下面这条命令，回车：

   ```bash
   curl -fsSL https://raw.githubusercontent.com/keeeevinShen/node-creation/main/deploy.sh | bash
   ```

3. 等 3–5 分钟，屏幕上会出现「部署完成」、节点链接和二维码。

链接同时保存在 CloudShell 的 `~/reality/reality-node.txt`，关掉 CloudShell 不影响节点。

> 也可以不用 curl：下载 `deploy.sh`，在 CloudShell 右上角 Actions → Upload file 上传，然后运行 `bash deploy.sh`。

## 用不了 CloudShell：用 Chrome 插件版

有的 AWS 账号打不开 CloudShell，这时用插件版 [`VPS-AWS部署插件.zip`](VPS-AWS%E9%83%A8%E7%BD%B2%E6%8F%92%E4%BB%B6.zip)。它在 Lightsail 控制台里自动点完建实例的流程，服务器上装的是 3X-UI 面板 + VLESS Reality 入站，部署完自动打开面板并登录，节点链接和二维码在面板里看。

1. 下载 `VPS-AWS部署插件.zip` 并解压，得到 `lightsail-node-extension` 文件夹，放到一个不会删的位置。
2. Chrome 打开 `chrome://extensions`，打开右上角「开发者模式」，点「加载已解压的扩展程序」，选这个文件夹。
3. 在已登录 AWS 的 Chrome 里点插件图标，选账号，点「创建并部署」，约 3 分钟后面板自动打开。

详细用法和出错处理见压缩包里的 `README.md`。插件建的节点用插件和 Lightsail 控制台管理，下面的 `--show`、`--newip`、`--destroy` 对它不起作用。

## 导入客户端

| 设备 | 客户端 | 导入方式 |
| --- | --- | --- |
| iPhone / iPad | Shadowrocket 或 V2Box | 扫二维码 |
| Mac | Hiddify | 复制链接，从剪贴板导入 |
| Windows | Hiddify 或 v2rayN | 复制链接，从剪贴板导入 |
| 安卓 | Hiddify 或 v2rayNG | 扫二维码或从剪贴板导入 |

- Shadowrocket 和 V2Box 在中国区 App Store 搜不到，要用外区 Apple ID 下载。
- Hiddify 的服务模式要选 **VPN**。选 Proxy 的话，浏览器可能通过 WebRTC 泄露本地 IP。
- Mac 版 Shadowrocket 实测所有连接报 `CERTIFICATE_VERIFY_FAILED`，Mac 上请用 Hiddify。
- 连上后打开 [ip.sb](https://ip.sb) 应该显示节点的 IP；用 [ipleak.net](https://ipleak.net) 检查 IPv4、IPv6、WebRTC、DNS 都不出现本地 IP。

**链接就是密码，不要发到公开的地方。**

## 管理节点

在 CloudShell 里运行（用 curl 的话，参数写在 `bash -s --` 后面）：

| 命令 | 作用 |
| --- | --- |
| `... \| bash -s -- --show` | 再次显示链接和二维码 |
| `... \| bash -s -- --newip` | IP 被墙后换一个新 IP（密钥不变）。换完要在客户端删掉旧节点、重新导入新链接 |
| `... \| bash -s -- --destroy` | 删除节点，停止计费（会要求输入 yes 确认，加 `--yes` 跳过） |

`...` 指上面那条 `curl -fsSL ...` 命令。

想部署多个节点，给每个节点起不同的名字，管理时也带上同样的名字：

```bash
curl -fsSL https://raw.githubusercontent.com/keeeevinShen/node-creation/main/deploy.sh | bash -s -- --name node2
curl -fsSL https://raw.githubusercontent.com/keeeevinShen/node-creation/main/deploy.sh | bash -s -- --destroy --name node2
```

其他可选参数：`--region`（指定区域）、`--sni`（伪装网站，默认 `aws.amazon.com`）、`--port`（端口，默认 443）。一般不需要改。

## 费用

- Lightsail 套餐按小时计费，美国区域约 5 美元/月。
- 静态 IP 挂在实例上时免费；没挂在实例上会收费。`--destroy` 会把实例和静态 IP 一起删掉。
- 不用了记得 `--destroy`。

## 脚本做了什么

脚本只用你当前 CloudShell 已登录的 AWS 账号，创建以下资源，不碰你账号里的其他东西：

| 资源 | 名字 | 说明 |
| --- | --- | --- |
| Lightsail 实例 | `reality-node` | Debian，带标签 `managed-by=deploy.sh`，首次开机时自动安装 Xray |
| 静态 IP | `reality-node-ip` | 挂在实例上，重启后 IP 不变 |
| 防火墙 | — | 只开 22（控制台浏览器 SSH）和 443 |
| 本地文件 | `~/reality/reality-node.txt` | 只有一行节点链接，权限 600 |

- 密钥在 CloudShell 里生成，私钥只写进服务器的 Xray 配置，不会显示在屏幕上。
- 服务器访问网站时优先用 IPv4 出口。实例本身也有 IPv6，但 AWS 的 IPv6 常被地理位置数据库标成别的国家，ChatGPT 这类服务还会把 IPv4、IPv6 位置不一致视为风险。
- `--destroy` 和 `--newip` 只操作带 `managed-by=deploy.sh` 标签的实例，不会误删你自己的服务器。
- 同一个区域里重复运行不会重复创建：发现同名节点已存在就停下，提示用 `--show`、`--destroy` 或 `--name`。
- 二维码用 Python 的 `qrcode` 库画，第一次运行时自动装到 `~/.local/lib/reality-qrcode`。

## 常见问题

**提示「区域 xxx 无法使用 Lightsail」**
新账号只能用注册时分配的区域。在控制台右上角切换到那个区域，重新打开 CloudShell 再运行。

**等了 10 分钟还没就绪**
Lightsail 控制台 → 实例 `reality-node` → 用浏览器 SSH 连接，运行下面两条看日志：

```bash
sudo tail -n 50 /var/log/cloud-init-output.log
systemctl status xray
```

想删掉重来就运行 `--destroy`。

**`--show` 提示找不到链接**
CloudShell 的主目录每个区域各一份，确认控制台右上角选的是部署时的区域；部署时用了 `--name` 的话，这里也要带上。一个区域 120 天没用过 CloudShell，主目录会被清空，这时只能 `--destroy` 后重新部署。

**客户端里显示的国旗不是美国**
客户端自己查 IP 数据库或按名字猜出来的，不影响使用。以 ip.sb 显示的国家为准；如果网站也认为你在别的国家，运行 `--newip` 换一个 IP。
