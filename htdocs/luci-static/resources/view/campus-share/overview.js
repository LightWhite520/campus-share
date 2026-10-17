'use strict';
'require view';
'require form';
'require uci';
'require fs';
'require ui';
'require poll';

function command(args) {
	return fs.exec('/usr/libexec/campus-share', args).then(function(result) {
		var data;
		try { data = JSON.parse(result.stdout || '{}'); }
		catch (e) { throw new Error('服务返回无效数据'); }
		if (!data.ok) throw new Error(data.error || '操作失败');
		return data;
	});
}
return view.extend({
	load: function() {
		return Promise.all([uci.load('campus_share'), uci.load('network'), uci.load('mwan3'),
			command(['status']).catch(function() { return { slots: [] }; })]);
	},
	render: function(data) {
		var self = this, initial = data[3], occupied = {};
		(initial.slots || []).forEach(function(s) {
			if (s.phase !== 'free' && s.phase !== 'unavailable') occupied[s.id] = s;
		});
		var rows = E('div', { 'class': 'cbi-section' });
		var invite = E('input', { 'readonly': true, 'style': 'width:100%', 'placeholder': '点击生成邀请链接' });
		var notice = E('p', {}, '生成邀请后，舍友领取空闲出口，在校园网原页面认证。密码不会经过本插件。');
		function notify(e) { ui.addNotification(null, E('p', {}, e.message), 'error'); }
		function refresh() {
			return command(['status']).then(function(status) {
				var table = E('table', { 'class': 'table' }, [
					E('tr', { 'class': 'tr table-titles' }, ['出口', '接口', '状态', '设备', '操作'].map(function(t) {
						return E('th', { 'class': 'th' }, t);
					}))
				]);
				var phases = { free: '空闲', unavailable: '不可分配 / 已有用途', pending: '等待认证或链路', active: '已加入共享' };
				(status.slots || []).forEach(function(s) {
					var release = E('button', { 'class': 'btn cbi-button cbi-button-negative',
						'disabled': s.phase === 'free' || s.phase === 'unavailable',
						'click': function() {
							ui.showModal('释放出口', [
								E('p', {}, '将停止该出口共享，并移除该设备的专用路由。校园网账号本身不会被自动注销。'),
								E('button', { 'class': 'btn', 'click': ui.hideModal }, '取消'),
								E('button', { 'class': 'btn cbi-button-negative', 'click': function() {
									command(['release', s.id]).then(function() { ui.hideModal(); refresh(); }).catch(notify);
								}}, '释放')
							]);
						}
					}, '释放');
					table.appendChild(E('tr', { 'class': 'tr' }, [
						E('td', { 'class': 'td' }, s.label || s.id),
						E('td', { 'class': 'td' }, s.interface),
						E('td', { 'class': 'td' }, phases[s.phase] || s.phase),
						E('td', { 'class': 'td' }, s.owner ? s.owner + (s.ip ? ' · ' + s.ip : '') : '—'),
						E('td', { 'class': 'td' }, release)
					]));
				});
				rows.replaceChildren(table);
			}).catch(notify);
		}
		var m = new form.Map('campus_share', '校园网共享',
			'接口来自当前网络配置。只有明确加入分配池、关闭自动启动且未被其他负载均衡成员引用的 DHCP 接口才会分配。');
		var s = m.section(form.NamedSection, 'main', 'settings', '共享设置'), o;
		o = s.option(form.ListValue, 'policy', '加入的负载均衡策略');
		o.value('', '请选择');
		uci.sections('mwan3', 'policy', function(p) { o.value(p['.name']); });
		o.validate = function(section, value) {
			if (Object.keys(occupied).length && value !== uci.get('campus_share', section, 'policy'))
				return '请先释放占用的出口，再更换策略';
			return value ? true : '请选择一个现有策略';
		};
		o = s.option(form.ListValue, 'lan_interface', '舍友所在内网');
		uci.sections('network', 'interface', function(n) {
			if (n.proto === 'static') o.value(n['.name']);
		});
		o = s.option(form.Value, 'portal_url', '校园网登录地址');
		o.validate = function(section, value) { return /^http:\/\/[^\s]+$/.test(value) ? true : '请填写 HTTP 登录地址'; };
		o = s.option(form.Value, 'pending_timeout', '待认证占用时间（秒）');
		o.datatype = 'range(120,3600)';
		o = s.option(form.Value, 'invite_timeout', '邀请有效时间（秒）');
		o.datatype = 'range(120,86400)';
		s = m.section(form.GridSection, 'slot', '可分配出口池');
		s.addremove = true; s.anonymous = false;
		s.sectiontitle = function(id) { return uci.get('campus_share', id, 'label') || id; };
		s.handleRemove = function(id, ev) {
			if (occupied[id]) { notify(new Error('请先释放这个出口')); return Promise.resolve(); }
			return form.GridSection.prototype.handleRemove.call(this, id, ev);
		};
		s.validateSectionAdd = function(value) {
			return /^[a-zA-Z0-9_]{1,12}$/.test(value) ? true : '名称限 1–12 位字母、数字、下划线';
		};
		o = s.option(form.Flag, 'enabled', '允许分配'); o.default = '1'; o.rmempty = false;
		o.validate = function(id, value) { return occupied[id] && value !== '1' ? '请先释放这个出口' : true; };
		o = s.option(form.Value, 'label', '显示名称');
		o = s.option(form.ListValue, 'interface', '网络接口'); o.rmempty = false;
		var choices = [];
		uci.sections('network', 'interface', function(n) {
			if (n.proto === 'dhcp' && n.device) {
				choices.push(n);
				o.value(n['.name'], n['.name'] + ' (' + n.device + ')');
			}
		});
		o.validate = function(id, value) {
			if (occupied[id] && occupied[id].interface !== value) return '请先释放这个出口';
			var chosen = choices.find(function(n) { return n['.name'] === value; });
			if (!chosen) return '请选择一个具有设备的 DHCP 接口';
			if (!occupied[id] && chosen.auto !== '0') return '接口正在使用，请先在网络设置中停用自动启动';
			var duplicate = uci.sections('campus_share', 'slot').some(function(n) {
				return n['.name'] !== id && n.interface === value;
			});
			return duplicate ? '同一个接口只能出现在分配池一次' : true;
		};
		o = s.option(form.Value, 'table', '专用路由表');
		o.datatype = 'range(200,239)'; o.rmempty = false;
		o.validate = function(id, value) {
			if (occupied[id] && value !== uci.get('campus_share', id, 'table')) return '请先释放这个出口';
			var duplicate = uci.sections('campus_share', 'slot').some(function(n) {
				return n['.name'] !== id && String(n.table) === String(value);
			});
			return duplicate ? '路由表编号不能重复' : true;
		};
		return m.render().then(function(config) {
			poll.add(refresh, 5); refresh();
			return E('div', {}, [
				E('h2', {}, '校园网共享'), notice,
				E('p', {}, '当前共享出口不会自动进入分配池。增加虚拟出口也不会突破物理端口的总带宽。'),
				rows,
				E('div', { 'class': 'cbi-section' }, [
					E('button', { 'class': 'btn', 'click': function() {
						command(['discover']).then(function(r) {
							ui.addNotification(null, E('p', {}, '已导入 ' + r.imported + ' 个空闲接口，正在刷新。'), 'info');
							window.location.reload();
						}).catch(notify);
					}}, '扫描并导入空闲接口'),
					E('button', { 'class': 'btn cbi-button-action', 'click': function() {
						command(['invite']).then(function(r) { invite.value = r.url; invite.focus(); invite.select(); }).catch(notify);
					}}, '生成邀请链接'), E('p', {}, invite)
				]), config
			]);
		});
	}
});
