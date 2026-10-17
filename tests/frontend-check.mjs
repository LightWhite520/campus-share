import fs from 'node:fs';
import path from 'node:path';
const root = path.resolve(import.meta.dirname, '..');
const view = fs.readFileSync(path.join(root, 'htdocs/luci-static/resources/view/campus-share/overview.js'), 'utf8');
new Function(view);
const page = fs.readFileSync(path.join(root, 'root/www-campus-share/index.html'), 'utf8');
for (const match of page.matchAll(/<script>([\s\S]*?)<\/script>/g)) new Function(match[1]);
for (const name of ['root/usr/share/luci/menu.d/luci-app-campus-share.json','root/usr/share/rpcd/acl.d/luci-app-campus-share.json'])
 JSON.parse(fs.readFileSync(path.join(root,name),'utf8'));
console.log('Frontend syntax and LuCI metadata passed');
