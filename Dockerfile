# ROS 2 Jazzy + usb_cam + ros_camera_server
# 注：ros_camera_server 官方要求 ROS 2 >= Jazzy（不支持 Humble），故容器用 Jazzy；
#     宿主机无 ROS，容器内版本选择不影响宿主机。
#     ros-base 已够用（容器内无 GUI 需求，比 desktop 小 2GB+，WebRTC 解码在浏览器端完成）。
# registry-1.docker.io 直连超时（DNS 污染），经 DaoCloud 镜像源拉取官方 ros 镜像
FROM docker.1ms.run/library/ros:jazzy-ros-base

ARG DEBIAN_FRONTEND=noninteractive

# usb_cam（官方 jazzy 二进制包）+ 设备诊断 + GStreamer 运行时 + 编译工具链
RUN apt-get update && apt-get install -y --no-install-recommends \
    ros-jazzy-usb-cam \
    v4l-utils \
    gstreamer1.0-tools \
    gstreamer1.0-plugins-base \
    gstreamer1.0-plugins-good \
    gstreamer1.0-plugins-bad \
    gstreamer1.0-plugins-ugly \
    gstreamer1.0-libav \
    build-essential \
    git \
    python3-colcon-common-extensions \
    python3-rosdep \
  && rm -rf /var/lib/apt/lists/*

# 源码编译 ros_camera_server（无二进制包；依赖同作者的 gstreamer_ros_babel_fish）
RUN mkdir -p /ws/src \
  && cd /ws/src \
  && git clone --depth 1 https://github.com/StefanFabian/ros_camera_server.git \
  && git clone --depth 1 https://github.com/StefanFabian/gstreamer_ros_babel_fish.git

# 上游补丁：selectCaps 不认 UVC 摄像头常见的 framerate GstValueList（离散帧率列表），
# 导致 v4l2 输入构建管线必失败（"No caps matching WxH @ N/1"）。详见 patches/ 目录。
COPY patches/ /tmp/patches/
RUN python3 /tmp/patches/patch_v4l2_framerate_list.py && rm -rf /tmp/patches
RUN rosdep init || true && rosdep update \
  && apt-get update \
  && cd /ws && rosdep install --from-paths src --ignore-src -r -y \
  && rm -rf /var/lib/apt/lists/*
RUN bash -c "source /opt/ros/jazzy/setup.bash \
  && cd /ws && colcon build --symlink-install --packages-up-to ros_camera_server"
# 注意：不能删 /ws/build —— symlink-install 下 install 内部分文件是指向 build 的符号链接，删了会死链

# 常驻容器；各节点由 docker exec 分阶段启动，便于逐层验证
CMD ["bash", "-c", "source /ws/install/setup.bash && sleep infinity"]
