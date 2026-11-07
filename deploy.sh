#!/usr/bin/env bash
# deploy.sh：在 AWS CloudShell 里一键部署 VLESS + Reality 节点
#
# 用法：
#   bash deploy.sh             部署节点，最后显示 vless:// 链接和二维码
#   bash deploy.sh --show      再次显示链接和二维码
#   bash deploy.sh --newip     IP 被墙后换一个新 IP（UUID 和密钥不变）
#   bash deploy.sh --destroy   删除节点，停止计费（加 --yes 跳过确认）
# 其他参数：--name 节点名（默认 reality-node）、--region 区域、--sni 伪装网站、--port 端口
# 用 curl 运行时，参数写在 bash -s -- 后面：curl -fsSL <脚本地址> | bash -s -- --show
set -euo pipefail

# ---------- 环境探测 ----------

# 确定部署区域：优先命令行参数，其次 CloudShell 的环境变量，最后是 AWS CLI 默认配置
detect_region() {
  local flag_region="$1"
  if [[ -n "$flag_region" ]]; then
    echo "$flag_region"
    return
  fi
  if [[ -n "${AWS_REGION:-}" ]]; then
    echo "$AWS_REGION"
    return
  fi
  aws configure get region || true
}

# 选该区域最便宜的、带公网 IPv4 的 Linux 套餐；查不到时输出空
pick_bundle() {
  local region="$1"
  local query="sort_by(bundles[?isActive && publicIpv4AddressCount>=\`1\` && contains(supportedPlatforms, 'LINUX_UNIX')], &price)[0].bundleId"
  aws lightsail get-bundles --region "$region" --query "$query" --output text 2>/dev/null || true
}

# 优先用 Debian 12（实测过），没有就用该区域最新的 Debian
pick_blueprint() {
  local region="$1"
  local ids
  ids=$(aws lightsail get-blueprints --region "$region" \
    --query "blueprints[?isActive && starts_with(blueprintId, 'debian')].blueprintId" \
    --output text 2>/dev/null || true)

  if grep -qw "debian_12" <<< "$ids"; then
    echo "debian_12"
    return
  fi
  echo "$ids" | tr '\t' '\n' | sort | tail -n 1
}

# 选该区域第一个可用的可用区；查不到时输出空
pick_az() {
  local region="$1"
  local query="regions[?name=='$region'].availabilityZones[?state=='available'].zoneName | [0] | [0]"
  aws lightsail get-regions --region "$region" --include-availability-zones \
    --query "$query" --output text 2>/dev/null || true
}

# ---------- 查询现有资源 ----------

# 查实例状态（pending / running / …）；实例不存在时输出空
get_instance_state() {
  local region="$1"
  local name="$2"
  aws lightsail get-instance --region "$region" --instance-name "$name" \
    --query 'instance.state.name' --output text 2>/dev/null || true
}

# 查实例的 managed-by 标签；没有这个标签或实例不存在时输出空
get_instance_tag() {
  local region="$1"
  local name="$2"
  local value
  value=$(aws lightsail get-instance --region "$region" --instance-name "$name" \
    --query "instance.tags[?key=='managed-by'].value | [0]" --output text 2>/dev/null || true)
  if [[ "$value" != "None" ]]; then
    echo "$value"
  fi
}

# 查静态 IP 的地址；静态 IP 不存在时输出空
get_static_ip() {
  local region="$1"
  local ip_name="$2"
  local value
  value=$(aws lightsail get-static-ip --region "$region" --static-ip-name "$ip_name" \
    --query 'staticIp.ipAddress' --output text 2>/dev/null || true)
  if [[ "$value" != "None" ]]; then
    echo "$value"
  fi
}

# 查静态 IP 挂在哪个实例上；没挂或静态 IP 不存在时输出空
get_static_ip_owner() {
  local region="$1"
  local ip_name="$2"
  local value
  value=$(aws lightsail get-static-ip --region "$region" --static-ip-name "$ip_name" \
    --query 'staticIp.attachedTo' --output text 2>/dev/null || true)
  if [[ "$value" != "None" ]]; then
    echo "$value"
  fi
}

# ---------- 生成凭证 ----------

# 把标准输入的二进制数据转成不带填充的 base64url（Xray 的密钥格式）
b64url() {
  base64 -w0 | tr '+/' '-_' | tr -d '='
}

# 生成客户端 UUID
gen_uuid() {
  uuidgen
}

# 生成 Reality 用的 X25519 密钥对，输出 "私钥 公钥"
gen_x25519() {
  local pem
  pem=$(openssl genpkey -algorithm X25519)

  # DER 编码的最后 32 字节就是原始密钥
  local priv
  priv=$(printf '%s\n' "$pem" | openssl pkey -outform DER | tail -c 32 | b64url)

  local pub
  pub=$(printf '%s\n' "$pem" | openssl pkey -pubout -outform DER | tail -c 32 | b64url)

  echo "$priv $pub"
}

# 生成 Reality 的 shortId（16 位十六进制）
gen_short_id() {
  openssl rand -hex 8
}

# ---------- 服务器开机脚本 ----------

# 生成服务器首次开机时执行的脚本：安装 Xray 并写入 Reality 配置。
# Lightsail 会把这段脚本接在它自己的初始化脚本后面，用 /bin/sh（Debian 上是 dash）运行，
# 第一行的 #! 不起作用，所以这里只能用 POSIX sh 语法：不用 pipefail、[[ ]] 这类 bash 写法。
gen_user_data() {
  local uuid="$1"
  local priv="$2"
  local short_id="$3"
  local sni="$4"
  local port="$5"

  cat <<EOF
#!/bin/sh
# 注意：Lightsail 用 /bin/sh 运行本脚本，只能用 POSIX sh 语法
set -eu

# 安装依赖：等待系统自带的自动更新释放 apt 锁，下载失败自动重试。
# 挂静态 IP 时公网 IP 会变，正在进行的下载可能断开，所以整步再包一层重试
for i in 1 2 3 4 5; do
  if apt-get -o DPkg::Lock::Timeout=300 -o Acquire::Retries=5 update -y \\
    && apt-get -o DPkg::Lock::Timeout=300 -o Acquire::Retries=5 install -y curl unzip; then
    break
  fi
  sleep 10
done

# 用官方脚本安装 Xray，会注册 systemd 服务。
# 同样可能被换 IP 打断：先把安装脚本下载成文件（下载失败才能被发现），再限时运行，失败就重试
for i in 1 2 3 4 5; do
  if curl -fsSL --connect-timeout 10 --max-time 60 --retry 5 --retry-all-errors \\
      -o /root/xray-install.sh https://github.com/XTLS/Xray-install/raw/main/install-release.sh \\
    && timeout 300 bash /root/xray-install.sh install; then
    break
  fi
  sleep 10
done

# 5 次都失败就报错退出
if ! test -x /usr/local/bin/xray; then
  echo "Xray 安装失败" >&2
  exit 1
fi

# 写入 Reality 配置
cat > /usr/local/etc/xray/config.json <<'CONFIG'
{
  "log": { "loglevel": "warning" },
  "inbounds": [{
    "port": ${port},
    "protocol": "vless",
    "settings": {
      "clients": [{ "id": "${uuid}", "flow": "xtls-rprx-vision" }],
      "decryption": "none"
    },
    "streamSettings": {
      "network": "tcp",
      "security": "reality",
      "realitySettings": {
        "target": "${sni}:443",
        "serverNames": ["${sni}"],
        "privateKey": "${priv}",
        "shortIds": ["${short_id}"]
      }
    }
  }],
  "outbounds": [{ "protocol": "freedom" }]
}
CONFIG

# 开机自启并立即启动
systemctl enable xray
systemctl restart xray
EOF
}

# ---------- 创建和删除资源 ----------

# 判断 AWS 操作是否成功：拿到了状态且不是 Failed（Started、Succeeded 等都算成功）
op_ok() {
  local status="$1"
  [[ -n "$status" && "$status" != "Failed" ]]
}

# 创建实例，首次开机执行 user_data；输出操作状态，命令出错时输出空（报错由 AWS CLI 打到 stderr）
create_instance() {
  local region="$1"
  local az="$2"
  local blueprint="$3"
  local bundle="$4"
  local name="$5"
  local user_data="$6"
  aws lightsail create-instances --region "$region" \
    --instance-names "$name" \
    --availability-zone "$az" \
    --blueprint-id "$blueprint" \
    --bundle-id "$bundle" \
    --user-data "$user_data" \
    --tags key=managed-by,value=deploy.sh \
    --query 'operations[0].status' --output text || true
}

# 每 5 秒查一次实例状态，最多等 3 分钟（AWS CLI 没有 Lightsail 的 waiter）；输出最后一次查到的状态
wait_instance_running() {
  local region="$1"
  local name="$2"
  local state=""
  local i
  for (( i = 1; i <= 36; i++ )); do
    state=$(get_instance_state "$region" "$name")
    if [[ "$state" == "running" ]]; then
      break
    fi
    sleep 5
  done
  echo "$state"
}

# 删除实例（AWS 在后台异步删除）；输出操作状态，出错时输出空
delete_instance() {
  local region="$1"
  local name="$2"
  aws lightsail delete-instance --region "$region" --instance-name "$name" \
    --query 'operations[0].status' --output text || true
}

# 申请静态 IP；输出操作状态，出错时输出空
allocate_static_ip() {
  local region="$1"
  local ip_name="$2"
  aws lightsail allocate-static-ip --region "$region" --static-ip-name "$ip_name" \
    --query 'operations[0].status' --output text || true
}

# 把静态 IP 挂到实例上（实例的公网 IPv4 会换成这个 IP）；输出操作状态，出错时输出空
attach_static_ip() {
  local region="$1"
  local ip_name="$2"
  local name="$3"
  aws lightsail attach-static-ip --region "$region" --static-ip-name "$ip_name" --instance-name "$name" \
    --query 'operations[0].status' --output text || true
}

# 把静态 IP 从实例上解绑；输出操作状态，出错时输出空
detach_static_ip() {
  local region="$1"
  local ip_name="$2"
  aws lightsail detach-static-ip --region "$region" --static-ip-name "$ip_name" \
    --query 'operations[0].status' --output text || true
}

# 释放静态 IP（没挂在实例上的静态 IP 会收费）；输出操作状态，出错时输出空
release_static_ip() {
  local region="$1"
  local ip_name="$2"
  aws lightsail release-static-ip --region "$region" --static-ip-name "$ip_name" \
    --query 'operations[0].status' --output text || true
}

# 防火墙只开 22（浏览器 SSH）和代理端口。put-instance-public-ports 会关掉请求里没列出的端口，
# 正好关掉 Lightsail 默认开的 80。cidrs 显式写出来，并用 JSON 写法避免简写语法分错逗号
open_ports() {
  local region="$1"
  local name="$2"
  local port="$3"
  local ports="[
    {\"fromPort\":22,\"toPort\":22,\"protocol\":\"tcp\",\"cidrs\":[\"0.0.0.0/0\"],\"ipv6Cidrs\":[\"::/0\"]},
    {\"fromPort\":$port,\"toPort\":$port,\"protocol\":\"tcp\",\"cidrs\":[\"0.0.0.0/0\"],\"ipv6Cidrs\":[\"::/0\"]}
  ]"
  aws lightsail put-instance-public-ports --region "$region" --instance-name "$name" \
    --port-infos "$ports" --query 'operation.status' --output text || true
}

# ---------- 就绪检测 ----------

# 对代理端口做一次普通 TLS 握手。Reality 会把没通过认证的握手转发给 SNI 网站，
# 所以拿到 SNI 网站的真证书，就说明静态 IP、防火墙、Xray 进程和转发目标都通了；就绪时输出 ok
probe_reality() {
  local ip="$1"
  local port="$2"
  local sni="$3"

  # CloudShell（Amazon Linux）的系统 CA 文件；存在就显式指定，免得 openssl 找不到
  local ca_args=()
  if [[ -f /etc/pki/tls/certs/ca-bundle.crt ]]; then
    ca_args=(-CAfile /etc/pki/tls/certs/ca-bundle.crt)
  fi

  if timeout 10 openssl s_client -connect "$ip:$port" -servername "$sni" \
      -verify_hostname "$sni" -verify_return_error "${ca_args[@]}" </dev/null >/dev/null 2>&1; then
    echo "ok"
  fi
}

# 每 10 秒探一次，最多 60 次（约 10 分钟）；就绪时输出 ok，超时输出空
wait_reality_ready() {
  local ip="$1"
  local port="$2"
  local sni="$3"
  local result
  local i
  for (( i = 1; i <= 60; i++ )); do
    result=$(probe_reality "$ip" "$port" "$sni")
    if [[ "$result" == "ok" ]]; then
      echo "ok"
      return
    fi
    echo "等待节点就绪…（第 $i 次，最多 60 次）" >&2
    sleep 10
  done
}

# ---------- 节点链接 ----------

# 拼出 vless:// 链接，格式和 3X-UI 导出的一致（已在 Shadowrocket、Hiddify 上验证）
build_link() {
  local uuid="$1"
  local ip="$2"
  local port="$3"
  local sni="$4"
  local pub="$5"
  local short_id="$6"
  local remark="$7"
  echo "vless://${uuid}@${ip}:${port}?encryption=none&flow=xtls-rprx-vision&security=reality&sni=${sni}&fp=chrome&pbk=${pub}&sid=${short_id}&type=tcp#${remark}"
}

# 从链接里取出 IP（@ 和后面第一个 : 之间）
link_ip() {
  local link="$1"
  local rest="${link#*@}"
  echo "${rest%%:*}"
}

# 从链接里取出端口（IP 后面的 : 和 ? 之间）
link_port() {
  local link="$1"
  local rest="${link#*@}"
  rest="${rest#*:}"
  echo "${rest%%\?*}"
}

# 从链接的查询参数里取出 sni
link_sni() {
  local link="$1"
  local query="${link#*\?}"
  query="${query%%#*}"
  tr '&' '\n' <<< "$query" | sed -n 's/^sni=//p'
}

# 把链接里的 IP 换成新 IP，其余部分不变
replace_link_ip() {
  local link="$1"
  local new_ip="$2"
  local head="${link%%@*}"
  local rest="${link#*@}"
  echo "${head}@${new_ip}:${rest#*:}"
}

# 读出本地保存的链接；文件不存在或内容不对时输出空
read_link() {
  local file="$1"
  local link=""
  if [[ -f "$file" ]]; then
    link=$(head -n 1 "$file" 2>/dev/null || true)
  fi
  if [[ "$link" == vless://* ]]; then
    echo "$link"
  fi
}

# 把链接存到本地文件（只有这一行，权限 600）；成功时输出文件路径，失败时输出空
save_link() {
  local file="$1"
  local link="$2"
  if (umask 077 && mkdir -p "$(dirname "$file")" && printf '%s\n' "$link" > "$file" && chmod 600 "$file") 2>/dev/null; then
    echo "$file"
  fi
}

# ---------- 屏幕输出与交互 ----------

# 把链接画成终端二维码（CloudShell 没有 qrencode，用 Python 的 qrcode 库）；画不出来时输出空
render_qr() {
  local link="$1"
  if ! command -v python3 >/dev/null 2>&1; then
    return 0
  fi

  # CloudShell 的 python3 在虚拟环境里，pip 不能用 --user（实测报错），
  # 所以把库装到 $HOME 下的单独目录，用 PYTHONPATH 引用；$HOME 是持久存储，下次不用再装
  local lib="$HOME/.local/lib/reality-qrcode"
  if ! PYTHONPATH="$lib" python3 -c 'import qrcode' >/dev/null 2>&1; then
    python3 -m pip install --quiet --target "$lib" qrcode >/dev/null 2>&1 || true
  fi

  # invert=True 适合深色背景的终端
  PYTHONPATH="$lib" PYTHONIOENCODING=utf-8 python3 -c 'import sys, qrcode; q = qrcode.QRCode(border=2); q.add_data(sys.argv[1]); q.print_ascii(invert=True)' "$link" 2>/dev/null || true
}

# 显示链接、二维码和客户端用法；note 是链接文件的说明，放在二维码下面
print_node() {
  local link="$1"
  local note="$2"
  local qr
  qr=$(render_qr "$link")

  echo "节点链接："
  echo "$link"
  echo
  if [[ -n "$qr" ]]; then
    echo "$qr"
  else
    echo "（这里显示不了二维码，请把上面的链接复制到手机上导入）"
  fi
  echo
  echo "$note"
  echo "iPhone：Shadowrocket 扫码。Mac / Windows / 安卓：Hiddify 从剪贴板导入，服务模式选 VPN。"
  echo "链接就是密码，不要发到公开的地方。关掉 CloudShell 不影响节点。"
}

# 告诉用户怎么删掉已经创建的资源
print_destroy_hint() {
  local region="$1"
  local name="$2"
  echo "清理已创建的资源：运行本脚本时加上 --destroy --name $name --region $region" >&2
  echo "（用 curl 运行的写成：curl -fsSL <脚本地址> | bash -s -- --destroy --name $name --region $region）" >&2
}

# 从终端读一行输入。脚本通过 curl | bash 运行时，标准输入是脚本本身，所以必须读 /dev/tty
read_answer() {
  local answer=""
  { read -r answer < /dev/tty; } 2>/dev/null || true
  echo "$answer"
}

# ---------- 命令 ----------

# 部署一个新节点：创建实例 → 静态 IP 和防火墙 → 保存链接 → 就绪检测 → 显示链接和二维码
deploy_node() {
  local region="$1"
  local bundle="$2"
  local name="$3"
  local sni="$4"
  local port="$5"
  local file="$6"

  # 同名实例或静态 IP 已存在就不部署（上次失败可能留下了没挂上的静态 IP）
  local state
  state=$(get_instance_state "$region" "$name")
  local static_ip
  static_ip=$(get_static_ip "$region" "$name-ip")
  if [[ -n "$state" || -n "$static_ip" ]]; then
    echo "区域 $region 里已经有实例 $name 或静态 IP $name-ip，不再重复创建。" >&2
    echo "查看链接用 --show，删除用 --destroy，或者用 --name 换个名字部署新节点。" >&2
    exit 1
  fi

  # 探测系统和可用区
  local blueprint
  blueprint=$(pick_blueprint "$region")
  if [[ -z "$blueprint" ]]; then
    echo "区域 $region 没有可用的 Debian 镜像" >&2
    exit 1
  fi

  local az
  az=$(pick_az "$region")
  if [[ -z "$az" || "$az" == "None" ]]; then
    az="${region}a"
  fi

  # 生成凭证
  local uuid
  uuid=$(gen_uuid)

  local keys
  keys=$(gen_x25519)
  local priv pub
  read -r priv pub <<< "$keys"

  local short_id
  short_id=$(gen_short_id)

  if [[ -z "$uuid" || -z "$priv" || -z "$pub" || -z "$short_id" ]]; then
    echo "生成凭证失败" >&2
    exit 1
  fi

  # 生成服务器开机脚本
  local user_data
  user_data=$(gen_user_data "$uuid" "$priv" "$short_id" "$sni" "$port")

  # 创建实例并等到 running（running 只表示机器开了，Xray 还在后台安装）
  echo "创建实例 $name（$az，$bundle，$blueprint）…" >&2
  local status
  status=$(create_instance "$region" "$az" "$blueprint" "$bundle" "$name" "$user_data")
  if ! op_ok "$status"; then
    echo "创建实例失败（AWS 的报错见上方）。如果 Lightsail 控制台里已经出现了实例 $name：" >&2
    print_destroy_hint "$region" "$name"
    exit 1
  fi

  echo "等待实例开机…" >&2
  state=$(wait_instance_running "$region" "$name")
  if [[ "$state" != "running" ]]; then
    echo "实例 3 分钟内没有进入 running 状态（当前：${state:-查不到}）。" >&2
    print_destroy_hint "$region" "$name"
    exit 1
  fi

  # 申请静态 IP 并挂上：不挂的话实例停机再开机后公网 IP 会变，链接就失效了
  echo "申请静态 IP 并挂到实例上…" >&2
  status=$(allocate_static_ip "$region" "$name-ip")
  if ! op_ok "$status"; then
    echo "申请静态 IP 失败（AWS 的报错见上方）。如果是数量到了上限，先去 Lightsail 控制台释放不用的静态 IP。" >&2
    print_destroy_hint "$region" "$name"
    exit 1
  fi

  status=$(attach_static_ip "$region" "$name-ip" "$name")
  if ! op_ok "$status"; then
    echo "静态 IP 没能挂到实例上（AWS 的报错见上方）。没挂在实例上的静态 IP 会收费。" >&2
    print_destroy_hint "$region" "$name"
    exit 1
  fi

  local ip
  ip=$(get_static_ip "$region" "$name-ip")
  if [[ -z "$ip" ]]; then
    echo "查不到静态 IP $name-ip 的地址。" >&2
    print_destroy_hint "$region" "$name"
    exit 1
  fi

  echo "设置防火墙（只开 22 和 $port）…" >&2
  status=$(open_ports "$region" "$name" "$port")
  if ! op_ok "$status"; then
    echo "设置防火墙失败（AWS 的报错见上方）。" >&2
    print_destroy_hint "$region" "$name"
    exit 1
  fi

  # 拼出链接并立刻存盘：就绪检测最长要等 10 分钟，CloudShell 中途断开也不会丢。
  # 链接备注（客户端里显示的节点名）就用 --name，不带区域，免得客户端按名字猜错国家
  local link
  link=$(build_link "$uuid" "$ip" "$port" "$sni" "$pub" "$short_id" "$name")
  local saved
  saved=$(save_link "$file" "$link")
  if [[ -z "$saved" ]]; then
    echo "警告：链接没能保存到 ~/reality/$name.txt，部署完成后请自己复制保存。" >&2
  fi

  # 就绪检测
  echo "服务器正在安装 Xray，一般需要 1–3 分钟…" >&2
  local ready
  ready=$(wait_reality_ready "$ip" "$port" "$sni")
  if [[ "$ready" != "ok" ]]; then
    echo "等了 10 分钟，服务器 $ip 的 $port 端口还没有正常应答。查看服务器日志：" >&2
    echo "  Lightsail 控制台 → 实例 $name → 用浏览器 SSH 连接，然后运行：" >&2
    echo "  sudo tail -n 50 /var/log/cloud-init-output.log" >&2
    echo "  systemctl status xray" >&2
    if [[ -n "$saved" ]]; then
      echo "链接已保存到 ~/reality/$name.txt，服务器装好后可以用 --show 查看。" >&2
    else
      echo "节点链接（还没通过检测）：$link" >&2
    fi
    echo "想删掉重来的话：" >&2
    print_destroy_hint "$region" "$name"
    exit 1
  fi

  # 显示结果
  local note="链接已保存到 ~/reality/$name.txt，以后用 --show 再看。"
  if [[ -z "$saved" ]]; then
    note="链接没能保存到本地，请自己复制保存。"
  fi
  echo >&2
  echo "部署完成（$region，IP $ip）"
  echo
  print_node "$link" "$note"
}

# 重新显示本地保存的链接和二维码
show_node() {
  local name="$1"
  local file="$2"

  local link
  link=$(read_link "$file")
  if [[ -z "$link" ]]; then
    echo "没有找到 ~/reality/$name.txt。可能的原因：" >&2
    echo "  CloudShell 的主目录每个区域各一份：确认控制台右上角选的是部署节点时的区域。" >&2
    echo "  部署时用了 --name 的话，这里也要加上同样的 --name。" >&2
    echo "  一个区域 120 天没用过 CloudShell，主目录会被清空。" >&2
    echo "找不回来的话，可以用 --destroy 删掉节点后重新部署。" >&2
    exit 1
  fi

  print_node "$link" "链接保存在 ~/reality/$name.txt。"
}

# 删除节点：确认 → 解绑静态 IP → 释放静态 IP → 删实例 → 删本地文件。
# 能处理半成品（只剩静态 IP、静态 IP 没挂上等）：每一步失败都继续下一步，最后报告结果
destroy_node() {
  local region="$1"
  local name="$2"
  local file="$3"
  local yes="$4"

  # 只删本脚本创建的实例，避免误删用户自己的服务器
  local state
  state=$(get_instance_state "$region" "$name")
  if [[ -n "$state" ]]; then
    local tag
    tag=$(get_instance_tag "$region" "$name")
    if [[ "$tag" != "deploy.sh" ]]; then
      echo "实例 $name 不是本脚本创建的（没有 managed-by=deploy.sh 标签），不删除。" >&2
      exit 1
    fi
  fi

  # 静态 IP 挂在别的实例上时也不动它
  local static_ip
  static_ip=$(get_static_ip "$region" "$name-ip")
  local owner=""
  if [[ -n "$static_ip" ]]; then
    owner=$(get_static_ip_owner "$region" "$name-ip")
    if [[ -n "$owner" && "$owner" != "$name" ]]; then
      echo "静态 IP $name-ip 挂在别的实例 $owner 上，不删除。" >&2
      exit 1
    fi
  fi

  if [[ -z "$state" && -z "$static_ip" && ! -f "$file" ]]; then
    echo "区域 $region 里没有找到节点 $name，没有需要删除的东西。" >&2
    return
  fi

  # 删除不可恢复，先确认
  echo "将删除（区域 $region）：" >&2
  if [[ -n "$state" ]]; then
    echo "  实例 $name" >&2
  fi
  if [[ -n "$static_ip" ]]; then
    echo "  静态 IP $name-ip（$static_ip）" >&2
  fi
  if [[ -f "$file" ]]; then
    echo "  本地文件 ~/reality/$name.txt" >&2
  fi
  echo "节点链接会永久失效。" >&2
  if [[ "$yes" != "yes" ]]; then
    printf '输入 yes 确认：' >&2
    local answer
    answer=$(read_answer)
    if [[ "$answer" != "yes" ]]; then
      echo >&2
      echo "已取消，没有删除任何东西。" >&2
      exit 1
    fi
  fi

  local failed=0
  local status

  # 先解绑、释放静态 IP，再删实例：删实例是异步的，反过来做的话释放时 IP 可能还挂着
  if [[ -n "$owner" ]]; then
    status=$(detach_static_ip "$region" "$name-ip")
    if op_ok "$status"; then
      echo "已解绑静态 IP $name-ip" >&2
    else
      echo "解绑静态 IP $name-ip 失败" >&2
      failed=$((failed + 1))
    fi
  fi

  if [[ -n "$static_ip" ]]; then
    status=$(release_static_ip "$region" "$name-ip")
    if op_ok "$status"; then
      echo "已释放静态 IP $name-ip" >&2
    else
      echo "释放静态 IP $name-ip 失败" >&2
      failed=$((failed + 1))
    fi
  fi

  local instance_gone="yes"
  if [[ -n "$state" ]]; then
    status=$(delete_instance "$region" "$name")
    if op_ok "$status"; then
      echo "已删除实例 $name（AWS 会在后台完成）" >&2
    else
      echo "删除实例 $name 失败" >&2
      failed=$((failed + 1))
      instance_gone="no"
    fi
  fi

  # 实例确实删了才删本地链接，免得节点还在、链接却没了
  if [[ -f "$file" ]]; then
    if [[ "$instance_gone" == "yes" ]]; then
      rm -f "$file"
      echo "已删除本地文件 ~/reality/$name.txt" >&2
    else
      echo "实例还在，保留本地文件 ~/reality/$name.txt" >&2
    fi
  fi

  echo >&2
  if [[ "$failed" -gt 0 ]]; then
    echo "有 $failed 步没有成功（AWS 的报错见上方）。再运行一次 --destroy 会接着清理剩下的。" >&2
    exit 1
  fi
  echo "清理完成。可以用下面两条命令确认这个节点已经不在了：" >&2
  echo "  aws lightsail get-instances --region $region --query 'instances[].name'" >&2
  echo "  aws lightsail get-static-ips --region $region --query 'staticIps[].name'" >&2
}

# IP 被墙后换一个新 IP：UUID、密钥、shortId 都不变，只把链接里的 IP 换掉
new_ip_node() {
  local region="$1"
  local name="$2"
  local file="$3"

  # 只换 IP，所以必须有本地保存的链接
  local link
  link=$(read_link "$file")
  if [[ -z "$link" ]]; then
    echo "没有找到 ~/reality/$name.txt。--newip 只换 IP、沿用原来的密钥，所以需要这个文件。" >&2
    echo "先按 --show 的提示找回链接；找不回的话，用 --destroy 删掉节点后重新部署。" >&2
    exit 1
  fi

  # 只操作本脚本创建的实例
  local state
  state=$(get_instance_state "$region" "$name")
  if [[ -z "$state" ]]; then
    echo "区域 $region 里没有实例 $name。" >&2
    exit 1
  fi
  local tag
  tag=$(get_instance_tag "$region" "$name")
  if [[ "$tag" != "deploy.sh" ]]; then
    echo "实例 $name 不是本脚本创建的（没有 managed-by=deploy.sh 标签），不操作。" >&2
    exit 1
  fi

  local old_ip
  old_ip=$(link_ip "$link")

  # 旧 IP 已经被墙，先释放再申请没有损失。上次中途失败时静态 IP 可能已经不在或没挂上
  local static_ip
  static_ip=$(get_static_ip "$region" "$name-ip")
  local status
  if [[ -n "$static_ip" ]]; then
    local owner
    owner=$(get_static_ip_owner "$region" "$name-ip")
    if [[ -n "$owner" && "$owner" != "$name" ]]; then
      echo "静态 IP $name-ip 挂在别的实例 $owner 上，不操作。" >&2
      exit 1
    fi

    if [[ -n "$owner" ]]; then
      echo "解绑旧 IP $static_ip…" >&2
      status=$(detach_static_ip "$region" "$name-ip")
      if ! op_ok "$status"; then
        echo "解绑旧静态 IP 失败（AWS 的报错见上方），什么都没改，可以再试一次。" >&2
        exit 1
      fi
    fi

    echo "释放旧 IP $static_ip…" >&2
    status=$(release_static_ip "$region" "$name-ip")
    if ! op_ok "$status"; then
      echo "释放旧静态 IP 失败（AWS 的报错见上方）。它现在没挂在实例上，会收费：请再运行一次 --newip。" >&2
      exit 1
    fi
  fi

  echo "申请新的静态 IP 并挂到实例上…" >&2
  status=$(allocate_static_ip "$region" "$name-ip")
  if ! op_ok "$status"; then
    echo "申请新静态 IP 失败（AWS 的报错见上方）。实例现在用的是一个临时公网 IP，重新运行 --newip 即可。" >&2
    echo "如果是数量到了上限，先去 Lightsail 控制台释放不用的静态 IP。" >&2
    exit 1
  fi

  status=$(attach_static_ip "$region" "$name-ip" "$name")
  if ! op_ok "$status"; then
    echo "新静态 IP 没能挂到实例上（AWS 的报错见上方）。没挂在实例上的静态 IP 会收费：请重新运行 --newip。" >&2
    exit 1
  fi

  local new_ip
  new_ip=$(get_static_ip "$region" "$name-ip")
  if [[ -z "$new_ip" ]]; then
    echo "查不到新静态 IP 的地址，请重新运行 --newip。" >&2
    exit 1
  fi

  # 把链接里的旧 IP 换成新 IP，立刻存盘
  local new_link
  new_link=$(replace_link_ip "$link" "$new_ip")
  local saved
  saved=$(save_link "$file" "$new_link")
  if [[ -z "$saved" ]]; then
    echo "警告：新链接没能保存到 ~/reality/$name.txt，请自己复制保存。" >&2
  fi

  # 就绪检测
  local port
  port=$(link_port "$new_link")
  local sni
  sni=$(link_sni "$new_link")
  echo "检测新 IP…" >&2
  local ready
  ready=$(wait_reality_ready "$new_ip" "$port" "$sni")
  if [[ "$ready" != "ok" ]]; then
    echo "新 IP $new_ip 的 $port 端口没有正常应答。用浏览器 SSH 连上服务器，运行 systemctl status xray 看看。" >&2
    if [[ -z "$saved" ]]; then
      echo "新链接：$new_link" >&2
    fi
    exit 1
  fi

  # 显示结果
  local note="新链接已保存到 ~/reality/$name.txt。客户端里的旧节点要删掉，重新导入新链接。"
  if [[ -z "$saved" ]]; then
    note="新链接没能保存到本地，请自己复制保存。客户端里的旧节点要删掉，重新导入新链接。"
  fi
  echo >&2
  echo "已换新 IP（$region，$old_ip → $new_ip）"
  if [[ "$new_ip" == "$old_ip" ]]; then
    echo "注意：AWS 分到的新 IP 和旧 IP 一样，可以再运行一次 --newip。"
  fi
  echo
  print_node "$new_link" "$note"
}

# ---------- 主流程 ----------

main() {
  # 关掉 AWS CLI 的分页器，免得输出停在 less 里等按键
  export AWS_PAGER=""

  # 解析参数
  local flag_region=""
  local sni="aws.amazon.com"
  local port="443"
  local name="reality-node"
  local mode="deploy"
  local yes="no"
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --region) flag_region="$2"; shift 2 ;;
      --sni) sni="$2"; shift 2 ;;
      --port) port="$2"; shift 2 ;;
      --name) name="$2"; shift 2 ;;
      --yes) yes="yes"; shift ;;
      --show|--destroy|--newip)
        if [[ "$mode" != "deploy" ]]; then
          echo "--show、--destroy、--newip 一次只能用一个" >&2
          exit 1
        fi
        mode="${1#--}"
        shift
        ;;
      *) echo "未知参数：$1" >&2; exit 1 ;;
    esac
  done

  # 检查参数：名字会用在资源名、文件名和链接备注里，端口和 SNI 会写进服务器配置
  if [[ ! "$name" =~ ^[A-Za-z0-9][A-Za-z0-9_-]*$ ]]; then
    echo "--name 只能用字母、数字、- 和 _，并且以字母或数字开头" >&2
    exit 1
  fi
  if [[ ! "$port" =~ ^[1-9][0-9]{0,4}$ ]] || (( port > 65535 )) || [[ "$port" == "22" ]]; then
    echo "--port 要是 1–65535 之间的数字，并且不能是 22（留给 SSH）" >&2
    exit 1
  fi
  if [[ ! "$sni" =~ ^[A-Za-z0-9.-]+$ ]]; then
    echo "--sni 要是一个域名，比如 aws.amazon.com" >&2
    exit 1
  fi

  # 本地只存一行 vless:// 链接
  local file="$HOME/reality/$name.txt"

  # --show 只读本地文件，不需要调用 AWS
  if [[ "$mode" == "show" ]]; then
    show_node "$name" "$file"
    return
  fi

  # 探测区域
  local region
  region=$(detect_region "$flag_region")
  if [[ -z "$region" ]]; then
    echo "无法确定区域，请加上 --region 参数，比如 --region us-east-2" >&2
    exit 1
  fi

  # 查套餐，顺便确认这个区域能用 Lightsail（新账号在别的区域调用会被拒绝）
  local bundle
  bundle=$(pick_bundle "$region")
  if [[ -z "$bundle" || "$bundle" == "None" ]]; then
    echo "区域 $region 无法使用 Lightsail。新注册的 AWS 账号通常只能用注册时分配的区域：" >&2
    echo "去掉 --region 参数，或者在控制台右上角切换到那个区域，再重新打开 CloudShell 运行。" >&2
    exit 1
  fi

  case "$mode" in
    destroy) destroy_node "$region" "$name" "$file" "$yes" ;;
    newip) new_ip_node "$region" "$name" "$file" ;;
    *) deploy_node "$region" "$bundle" "$name" "$sni" "$port" "$file" ;;
  esac
}

main "$@"
