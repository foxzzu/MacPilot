# MacPilot 宣传动画视频

52 秒品牌宣传动画，1920×1080 @ 30fps，H.264。全部画面由代码生成（无拍摄素材、无二维码、无水印侵权风险）。18 个功能模块全部覆盖：6 个主打功能为动态小剧场，其余 12 个以卡片墙逐个介绍。

## 成品

- `MacPilot-promo-1080p.mp4` — 含配乐成片（发布用）
- `MacPilot-promo-1080p-silent.mp4` — 无音轨版本（平台配乐二创用）
- `poster.jpg` — 海报帧（取自片尾）

## 分镜（51.6s）

| 时间 | 内容 |
|---|---|
| 0.0–4.6 | 开场标语「少一点操作。多一点自动。」 |
| 4.4–10.0 | 菜单栏场景：点击图标展开 18 个模块面板 |
| 9.8–13.6 | 01 BLE 解锁（靠近解锁 / 离开锁定） |
| 13.4–17.2 | 02 剪贴板历史（⌘⇧V 取历史粘贴） |
| 17.0–20.8 | 03 窗口切换（⌥Tab 滑行切换） |
| 20.6–24.4 | 04 截图与标注（框选→闪光→缩略图→标注） |
| 24.2–28.0 | 05 保持唤醒（开关 + 咖啡倒计时环） |
| 27.8–31.6 | 06 闲置自动退出（倒计时环逐个回收 + 释放内存计数） |
| 31.3–36.3 | 卡片墙一：画中画 · 平滑滚动 · 访达右键菜单 · Dock 分组 · 存储压缩 · 屏幕录制 |
| 36.1–41.1 | 卡片墙二：远程控制 · 输入法 · 定时启动 · 内存监控 · CPU 监控 · 本地端口 |
| 40.9–43.2 | 品牌跑马灯 AUTOMATE THE REPEATS ✳ MADE FOR MAC |
| 43.0–46.2 | 四大原则：原生 / 轻量 / 本机 / 按需开启 |
| 46.0–51.6 | 片尾：图标 + 官网 + 下载信息（无二维码） |

六个主打小剧场覆盖「BLE 解锁 / 剪切板 / 窗口切换 / 截屏与贴图 / 保持唤醒 / 退出」，卡片墙覆盖其余 12 个模块，与菜单栏面板里的 18 项一一对应。品牌色 `#c8fa75` / `#111310` 与网站一致。

## 重新渲染

依赖：Node 22+、Google Chrome、ffmpeg、Python 3 + numpy（仅配乐）。

```bash
# 1. 逐帧渲染（2x 超采样，输出 frames/*.png，约 15 分钟）
cd render && node render.js full

# 2. 合成视频（1080p，向下采样）
ffmpeg -y -framerate 30 -i frames/f%05d.png \
  -vf "scale=1920:1080:flags=lanczos,format=yuv420p" \
  -c:v libx264 -preset slow -crf 17 -movflags +faststart \
  -x264-params aq-mode=3:aq-strength=1.1 \
  MacPilot-promo-1080p-silent.mp4

# 3. 配乐（可选）
python3 render/music.py   # 输出 /tmp/macpilot-promo-music.wav
ffmpeg -y -i MacPilot-promo-1080p-silent.mp4 -i /tmp/macpilot-promo-music.wav \
  -c:v copy -c:a aac -b:a 192k -shortest MacPilot-promo-1080p.mp4
```

调试单帧：`cd render && node render.js sample 7.0,16.2`（输出 `/tmp/sample-*.png`）。

## 实现说明

- `index.html` 是**确定性时间线**：整支视频是 `renderFrame(t)` 的纯函数，无真实时钟、无随机数（噪声均带种子），同一 t 永远渲染出同一帧，可断点续渲、可精修。
- `render/render.js` 用 playwright-core 驱动本机 Chrome 截帧；`DSF=2` 超采样后由 ffmpeg lanczos 降采样，保证细线与文字边缘干净。
- App 图标来自 `Resources/AppIcon.icns`（拷贝为 `assets/icon.png`）。
- 注意：不要在画面里添加二维码（平台会限流），下载指引统一用文字域名。
