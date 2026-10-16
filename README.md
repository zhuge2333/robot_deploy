# robot_deploy — DECXIN USB 摄像头 → WebRTC + ROS2 推流

Docker 容器内单进程采集 DECXIN USB 摄像头，同时输出两路：

1. **WebRTC**（h264 640x480@30，浏览器低延迟预览，端口 8443）
2. **ROS2 话题 `/image_raw`**（raw `sensor_msgs/Image`，供 vla_client_ws 的 VLA 客户端订阅）

> 部署日期 2026-10-16，全部服务端验证通过（input 30.9fps / ros2 输出 31fps）。
> 领域约束与坑的权威记录见 [CLAUDE.md](CLAUDE.md)，本 README 面向使用与运维。

## 架构

```
DECXIN 摄像头 (宿主机 /dev/video4, by-id 稳定路径 → 容器内 /dev/video0)
        │  MJPEG 640x480@30
        ▼
┌─ robot_cam 容器 (host 网络, ROS 2 Jazzy, ROS_DOMAIN_ID=42) ─┐
│  ros_camera_server (v4l2 输入, 实测 30.9fps)                │
│    ├─ 输出1: WebRTC h264@640x480 (openh264enc 软编, 2Mbps)  │
│    └─ 输出2: /image_raw raw@31fps (frame_id=camera_link)    │
└─────────────────────────────────────────────────────────────┘
        │                                  │
  浏览器 http://58.206.217.128:8443   VLA 客户端 (需 ROS_DOMAIN_ID=42)
```

**核心选型**：采集不用 usb_cam（此摄像头上限 ~15fps，软件层瓶颈），由
[ros_camera_server](https://github.com/StefanFabian/ros_camera_server) 的
v4l2 输入直接走 GStreamer 管线（实测 30fps）。它要求 ROS 2 ≥ Jazzy，
故容器基于 `ros:jazzy-ros-base` 源码编译（无二进制包）。

## 目录结构

```
robot_deploy/
├── CLAUDE.md                    # 领域约束 + 本机环境事实 + 已知坑（权威文档）
├── README.md                    # 本文件
├── Dockerfile                   # Jazzy + GStreamer + 源码编译 ros_camera_server（含补丁）
├── docker-compose.yml           # 设备直通 / host 网络 / 自启动推流命令
├── config/
│   ├── camera_server.yaml       # 生效配置：v4l2 采集 + WebRTC/ros2 双输出
│   └── params.yaml              # usb_cam 参数（已弃用，仅留作回退参考）
└── patches/
    └── patch_v4l2_framerate_list.py   # 上游 bug 补丁（已烧入镜像，见"已知坑"）
```

## 快速开始

```bash
# 首次构建 + 启动（约 10-20 分钟，含源码编译）
# 本机 Docker Hub 被墙，Dockerfile 已用国内镜像源；若 1ms.run 失效可换
# docker.m.daocloud.io / docker.xuanyuan.me（ intermittent 502 重试即可）
cd ~/robot_deploy && docker compose up -d

# 日常启停
docker compose stop | start | down | up -d
docker logs robot_cam --tail 50     # 看推流状态块
```

容器启动即自动推流（compose `command` 直接 `ros2 launch`，无需进容器手动操作）。

## 验证

**服务端（已通过，可随时复查）：**

```bash
docker logs robot_cam --tail 20
```

状态块关键行及 2026-10-16 实测值：

```
state: PLAYING
input fps: 30.9
Output 1 (webrtc, h264@640x480, encoder: openh264enc): status: paused (no clients)   ← 正常，按需编码
Output 2 (ros2, raw@640x480): status: active, fps: 31, processing time: 2.1ms
```

注：`paused (no clients)` 表示输出按需启动——浏览器接入后才开始编码，不是故障。
`ros2 topic hz`（CLI 订阅）实测会低报（10~23fps），以服务端状态块为准。

**浏览器（需真人确认）：**

同一 WiFi 下用手机/电脑打开 `http://58.206.217.128:8443`：
- 画面流畅无卡顿
- 延迟粗测：秒表 App 对准摄像头，看浏览器画面里的秒数差，目标 < 200ms

**VLA 客户端订阅 `/image_raw`：**

客户端环境需 `export ROS_DOMAIN_ID=42`（否则发现不了话题）。

## 配置要点（config/camera_server.yaml）

| 项 | 值 | 说明 |
|---|---|---|
| `address` | `58.206.217.128` | **宿主机局域网 IP**，写 127.0.0.1 则其他设备无法访问；IP 变化后改此行并重启容器 |
| `signaling_port` | `8443` | host 网络，直接暴露在宿主机 |
| input `media_type` | `image/jpeg` | MJPEG 实测稳定 29.4fps；YUYV 亦可但带宽高 |
| input `device` | `/dev/video0` | 容器内固定节点，compose 已把 by-id 稳定路径映射过来 |
| webrtc `codec/bitrate` | h264 / 2000kbps | 编码器留 auto：无 NVIDIA GPU，自动选 openh264enc 软编 |
| ros2 `codec` | `raw` | 必须显式 raw——auto 会 JPEG 直通只出 `/image_raw/compressed` |

## 与最初设计文档的偏差

1. **Humble → Jazzy**：ros_camera_server 硬性要求 ≥ Jazzy。
2. **弃用 usb_cam**：实测此摄像头 usb_cam 只有 ~15fps（GStreamer 直采 29.4fps 正常，
   纯软件层瓶颈）；且 Jazzy 下参数改名（`camera_frame_id`→`frame_id`）、旧 UVC
   控制名（exposure_auto 等）全部失效。改用 v4l2 直接采集后 `/image_raw` 话题名不变，
   下游无感。`config/params.yaml` 保留作回退参考。
3. **打了上游补丁**：selectCaps 不认 UVC 常见的 framerate `GstValueList`，v4l2 输入
   必报 "No caps matching 640x480 @ 30/1"。`patches/patch_v4l2_framerate_list.py`
   在 Dockerfile 构建时自动应用（值得给上游提 PR）。
4. **镜像源与域名隔离**：Dockerfile FROM 走国内镜像（Hub 被 DNS 污染）；
   `ROS_DOMAIN_ID=42` 隔离校园网内其他 ROS2 节点。

## 已知坑（运维必读）

- **摄像头不是 /dev/video0**：宿主机 video0–3 是内置摄像头，DECXIN 实际在
  video4。compose 用稳定路径 `/dev/v4l/by-id/usb-DECXIN_DECXIN_CAMERA_01.00.00-video-index0`
  映射为容器内 /dev/video0，USB 插拔顺序变化不影响。
- **手动曝光会毁帧率**：manual 模式（auto_exposure=1）实测掉到 2~3fps。
  现行方案不动曝光（MJPEG + 摄像头自动策略 = 稳定 30fps），暗光下 fps 波动属正常。
- **compose `command` 必须单行**：YAML `>` 折叠标量对更深缩进的续行保留 `\n`，
  多行命令会导致 `config_path` 参数丢失、加载错误配置。
- **不要删容器内 /ws/build**：colcon `--symlink-install` 下 install 里部分文件是
  指向 build 的符号链接，删 build 会产生死链导致 setup.bash 失效。重建走 Dockerfile。
- **Docker 权限**：zhuge 已在 docker 组；早于加组启动的 shell（含旧 Claude 会话）
  需 `sg docker -c '<命令>'`，新登录终端直接 `docker`。
- **诊断工具**（容器内）：
  ```bash
  docker exec robot_cam ros2 run ros_camera_server v4l2_caps_investigator /dev/video0
  docker exec robot_cam v4l2-ctl -d /dev/video0 --list-formats-ext
  docker exec robot_cam ros2 run ros_camera_server enumerate_encoders
  ```

## 常见操作

```bash
# 看 CPU/内存占用
docker stats robot_cam --no-stream

# 重启（改配置后）
docker compose restart

# IP 变了：改 config/camera_server.yaml 的 address 后
docker compose restart

# 完全重建镜像（改 Dockerfile/补丁后）
docker compose build --no-cache && docker compose up -d
```

## 后续扩展

- **云端推流**：ros_camera_server 原生支持 SRT / RTP 输出，在
  `camera_server.yaml` 的 `outputs` 里追加目标（服务器地址+端口）即可，采集层不动。
- **上游 PR**：GstValueList 补丁可整理后提交至
  https://github.com/StefanFabian/ros_camera_server ，合入后可删 patches/ 环节。
