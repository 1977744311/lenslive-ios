# 本地 RTMP 联调

无真机/不开真实直播间时，用本地 RTMP 服务器验证「Mock 相机帧 → HaishinKit → RTMP」整条推流链路。

## 方式一：SRS（推荐，带播放页）

```bash
docker run --rm -it -p 1935:1935 -p 8080:8080 ossrs/srs:6
```

- App 内推流目标选「自定义 RTMP」：服务器 `rtmp://<Mac 局域网 IP>:1935/live`，串流密钥任意（如 `test`）。
- 播放验证：浏览器开 `http://<Mac IP>:8080/players/srs_player.html`，流地址 `rtmp://.../live/test`；或 `ffplay rtmp://localhost:1935/live/test`。

## 方式二：ffplay 直听（最简）

```bash
ffplay -listen 1 -f flv rtmp://0.0.0.0:1935/live/test
```

先启 ffplay 再开推流（listen 模式单连接）。

## 注意

- 模拟器推 `rtmp://127.0.0.1` 即可；真机推 Mac 局域网 IP，需同一 WiFi。
- B 站直播姬中转模式的本地行为与 SRS 等价：直播姬开「第三方推流」后按其给出的局域网地址填目标。
