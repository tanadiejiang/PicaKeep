# PicaKeep Docker host 网络模式 + mDNS 自动发现部署指引

## 为什么 bridge 模式 mDNS 发现不了

docker 默认的 bridge 模式中，容器处于独立的虚拟网络（docker0 网桥），与宿主机物理网卡之间**没有二层桥接**。mDNS 依赖组播地址 `224.0.0.251:5353` 在本地链路（Link-Local）广播，而组播帧无法穿越 NAT，也不会从 docker0 转发到物理网卡，因此 App 的 mDNS 发现对运行在 bridge 模式容器内的服务端无效。

NAT 端口映射（`-p 9527:9527`）仅对单播 TCP/UDP 连接有效，无法解决组播的传播问题。

> 子网扫描是不依赖 mDNS 的替代方案，见文末。

---

## 切换 host 网络模式

### docker run 方式

去掉所有 `-p` 端口映射参数，改为 `--network host`：

```bash
docker run -d \
  --network host \
  --name picakeep \
  -e PICAKEEP_DATA_DIR=/data/picakeep \
  -v /var/apps/picakeep/shares/picakeep/data:/data/picakeep \
  -v /vol1:/vol1 -v /vol2:/vol2 -v /vol3:/vol3 \
  picakeep:<version>
```

host 模式下容器直接复用宿主机网络栈，服务端配置里的 `port`（默认 `9527`）就是对外端口，无需额外映射。

### docker-compose 方式

删除 `ports:` 块，添加 `network_mode: "host"`：

```yaml
services:
  picakeep:
    image: picakeep:<version>
    network_mode: "host"
    # ports:          ← 删除此行，host 模式不支持端口映射
    #   - "9527:9527"
    environment:
      - PICAKEEP_DATA_DIR=/data/picakeep
    volumes:
      - /var/apps/picakeep/shares/picakeep/data:/data/picakeep
      - /vol1:/vol1
      - /vol2:/vol2
      - /vol3:/vol3
```

### 群晖 DSM 注意事项

DSM 部分版本的 GUI 未暴露 host 模式开关，需通过 **SSH + docker CLI** 或手动编写 compose 文件来指定。

- 操作前确认群晖 Docker（Container Manager）版本支持 host 模式，较新版本通常已支持。
- 若 GUI 报错，改用 SSH 登录后执行上方 `docker run` 命令。

---

## 配置对外广播地址与端口（advertiseHost / advertisePort）

切换到 host 模式后，若服务端能自动枚举到正确的 LAN IP，mDNS 通常已能正常工作。但在以下情况需手动配置覆盖值：

- 主机有多块网卡，自动选到了错误的网卡地址
- 对外端口与监听端口不同（反代/端口转发场景）
- LAN 网段为 `10.x.x.x`，自动过滤逻辑可能误排除该地址段

### 通过网页后台配置

进入管理后台 → **服务配置**，找到「对外广播地址」和「对外广播端口」：

| 字段 | 填写说明 |
|---|---|
| 对外广播地址 | NAS 在局域网的真实 IP，如 `192.168.1.100` 或 `10.0.0.5` |
| 对外广播端口 | 留空表示与监听端口相同；对外端口不同时填写实际对外端口 |

保存后重启服务端，新广播值即时生效。

### 通过配置文件配置

在 `picakeep_server.json` 中加入以下字段：

```json
{
  "advertiseHost": "192.168.1.100",
  "advertisePort": 8080
}
```

- `advertiseHost` 设为空串 `""` = 自动枚举
- `advertisePort` 省略或设为 `null` = 与监听端口相同

---

## 不想改 Docker 配置？用子网扫描替代

若不方便切换到 host 网络模式，可在 App **「设置 → 远程服务」** 里开启**子网扫描**。App 会主动扫描局域网 IP 端口，不依赖 mDNS 组播，同样能找到运行在 bridge 模式容器内的服务端。

子网扫描是计划 01 已实现的兜底能力，与 mDNS 发现两种方式可以共存，互不干扰。
