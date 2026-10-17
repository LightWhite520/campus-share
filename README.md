# Campus Share

OpenWrt / LuCI 校园网共享出口管理插件。管理员动态选择空闲 DHCP 接口，舍友通过邀请链接领取出口，在校园网原页面认证。仅在 HTTP 联网检测成功后，出口才加入选定的 mwan3 策略。

**不内置当前路由器的出口名称、MAC、账号或密码。** 接口池、内网接口、mwan3 策略及认证入口均通过配置读取。

## 接入流程

1. 在 OpenWrt 创建 DHCP 出口（物理口、VLAN 或 macvlan 均可），设置独立 MAC / DHCP client ID，加入具有 IPv4 NAT 的出口防火墙区域。
2. 出口保持停用自动启动，且未被现有 mwan3 成员引用。
3. 在“网络 → 校园网共享”选择已有 mwan3 策略，点击“扫描并导入空闲接口”或手动添加出口池；每个槽位使用唯一的 200–239 路由表编号。
4. 保存应用后，管理员生成邀请链接，发给一位舍友。
5. 舍友连接本地 Wi-Fi、关闭移动数据和代理，打开邀请链接并领取出口。
6. 插件将领取设备的 IPv4 流量固定到该出口；获取地址后显示校园网认证按钮。
7. 舍友在校园网原页面填写自己的账号密码。插件检查到指定出口返回预期联网检测正文后，将它作为等权成员加入选定策略。
8. 管理员可释放出口。未完成认证的占用默认十分钟自动释放。

同一设备只能领取一个出口。邀请只能由领取它的设备继续使用。随机 MAC 变化时应释放旧出口重新领取。当前版本面向可信宿舍局域网；MAC 绑定不等同于强身份认证。

## 实现边界

- 不采集校园密码，不自动替用户登录。
- 每次领取生成新的本地 MAC 和 DHCP client ID；释放时恢复原接口设置，防止下一位成员复用上一位的认证。
- 已领取设备固定使用自己的出口；其他设备由 mwan3 分流。
- 使用 HTTP 正文验证，不把“能 ping”当作认证成功。
- 认证失效连续三次后移出共享策略，进入重新认证状态。
- 专用路由表包含不可达默认路由，未认证/断链时不会静默借用其他出口。
- 接入设备的 IPv6 转发被阻止，避免绕过 IPv4 出口分配；不管理 IPv6 校园认证。
- 邀请链接含敏感令牌，只在本地分享；网页不加载外部资源。
- flock 序列化领取；不覆盖已启动接口、其他 mwan3 成员或同设备上的现有逻辑接口。
- 逻辑出口数量不等于独立带宽；macvlan 仍共享父物理口和 AP 上联。
- 不保证系统自动弹窗。通过邀请链接接入，路由器已联网时系统通常不会自动弹认证页。
- 私有状态保存在路由器 /etc/campus-share，禁止进入 Git；失败计数存放 /var/run。

## 安装与卸载

依赖：OpenWrt firewall4、mwan3、LuCI、curl、jsonfilter、flock、conntrack；macvlan 另需 kmod。

将项目复制到路由器，执行：

```sh
sh scripts/install.sh
```

安装器备份配置，建立单独的内网 HTTP 接入服务和防火墙例外，不启用任何出口。默认端口 8088，在 /etc/config/campus_share 配置。更改绑定内网/端口后重新运行 /usr/libexec/campus-share-setup。

```sh
sh scripts/uninstall.sh
```

卸载先释放本插件的出口，保留私有状态供检查。Makefile 提供 OpenWrt feeds 构建入口；源码安装是直接验证路径，没有预编译 apk。

## 检查

开发机：

```sh
node tests/frontend-check.mjs
```

OpenWrt：

```sh
sh tests/router-tests.sh
```

路由器测试使用独立 UCI、状态目录和模拟网络命令，覆盖并发领取、占用保护、令牌校验、健康检查、超时释放和跨站拒绝，不启用实际测试出口。真实舍友账号接入仍需实际设备验证。

## 文件

- root/usr/libexec/campus-share：分配、认证检测、路由、mwan3。
- root/www-campus-share：自助接入页面及 API。
- htdocs/luci-static/resources/view/campus-share/overview.js：LuCI 管理页。
- root/etc/config/campus_share：通用配置。
- scripts：安装与卸载；tests：隔离测试。
