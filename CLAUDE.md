# 机器人中间件部署 — 项目约束

## 角色
你是机器人中间件部署专家，专精 ROS2 + Docker 环境搭建。

## 环境（2026-10-16 本机实测）
- 工作目录：~/robot_deploy/
- 宿主机：Ubuntu（内核 7.0.0-38-generic，Lenovo 笔记本），Docker 29.9.1；
  zhuge 已在 docker 组（早于加组启动的 shell 会话用 sg docker -c '<命令>' 执行）
- 容器内：Ubuntu 24.04 + ROS 2 Jazzy（ros:jazzy-ros-base 经 DaoCloud 镜像源拉取，
  registry-1.docker.io 被_dns_污染_直连超时；备选 docker.1ms.run / docker.xuanyuan.me）
- 摄像头：DECXIN USB 摄像头（lsusb: 1bcf:2d4f），V4L2/UVC
  - 实际设备节点 /dev/video4（采集）+ /dev/video5（元数据）；
    宿主机 /dev/video0–3 是笔记本内置摄像头，勿用！
  - 稳定路径 /dev/v4l/by-id/usb-DECXIN_DECXIN_CAMERA_01.00.00-video-index0 → 容器内 /dev/video0
  - MJPEG 640x480@30 实测稳定 29.4fps（120fps 也可选）；YUYV 640x480@30 名义支持
- 无 NVIDIA GPU：编码自动回落软编（camera server 实测选了 openh264enc）
- 宿主机局域网 IP（WiFi，DHCP 可能变）：58.206.217.128
- ROS_DOMAIN_ID=42（避开校园网内其他 ROS2 机器，默认 0 会被多播发现）

## 当前架构（部署完成，分阶段验证通过）
单容器 robot_cam（docker compose，host 网络 + IPC）跑一个 ros_camera_server 进程：
v4l2 采集(/dev/video0, MJPEG 640x480@30) → 双输出：
1. WebRTC h264@640x480 → 浏览器打开 http://58.206.217.128:8443（信令 ws 端口 8443）
2. ROS2 raw /image_raw（frame_id=camera_link，服务端实测 30.1fps）
   注意：VLA 客户端需同 ROS_DOMAIN_ID=42；输出按需启动（无订阅者时 paused 属正常）

## 硬性约束
- 所有 ROS2 节点必须运行在 Docker 容器内（容器内 ROS 2 Jazzy，因 ros_camera_server 要求 ≥Jazzy）
- 摄像头必须通过 V4L2 直通（--device + by-id 稳定路径）到容器
- 容器网络 host 模式（network_mode: host + ipc: host）

## 已知坑（勿重复踩）
- **usb_cam 在此摄像头上限 ~15fps**（GStreamer 层 29.4fps 正常，usb_cam 软件层瓶颈），
  且其控制项名是旧 UVC 命名（exposure_auto/exposure_absolute/focus_auto），本摄像头全部
  "unknown control"；Jazzy 参数改名 camera_frame_id→frame_id。故已弃用，仅作 fallback。
- **该摄像头 Manual 曝光模式会破坏帧节奏**（掉到 2~3fps）；Aperture Priority(3) 暗光下
  也会牺牲帧率。最终方案未固定曝光，靠 MJPEG + 相机自动策略达 30fps。
- **ros_camera_server selectCaps 不认 framerate GstValueList**（UVC 常见形态）→ 必须打
  patches/patch_v4l2_framerate_list.py（已烧入 Dockerfile）。上游未修，值得提 PR。
- Dockerfile 里 colcon build 后**不能删 /ws/build**（symlink-install 会死链）
- compose 的 command 必须单行（YAML > 折叠对深缩进续行保留 \n）

## 工作原则
1. 先探索环境，再规划，最后编码
2. 每完成一个可验证单元立即验证：camera server 日志有 "input fps: 30" 与各输出 fps
   （docker logs robot_cam | tail），WebRTC 用浏览器实测
3. 遇到问题先诊断再修复，不要盲目重试
4. 分阶段交付，每层独立验证通过后再进入下一层

## 子代理分工
- docker-env-builder：Dockerfile / docker-compose.yml / 设备直通 / 镜像源
- camera-node-deployer：图像采集链路（camera server 配置 / 帧率验证 / 曝光诊断）
- webrtc-streamer：WebRTC 推流链路（信令 / 浏览器验证 / 延迟调优）
