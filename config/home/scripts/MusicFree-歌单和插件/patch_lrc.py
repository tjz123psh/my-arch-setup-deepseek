#!/usr/bin/env python3
# MusicFree 0.0.8 外部歌词窗口 "Object has been destroyed" 修复补丁
# 给 createLyricWindow/showLyricWindow/closeLyricWindow 相关回调加 isDestroyed 保护
path = '/usr/lib/musicfree/resources/app/.webpack/main/index.js'
data = open(path, encoding='utf-8').read()

patches = [
    # 1. showLyricWindow：f.lrcWindow 可能是已销毁的旧引用 → 先复位
    ('showLyricWindow(){f.lrcWindow||this.createLyricWindow(),f.lrcWindow.show(),p.default.setConfig({"lyric.enableDesktopLyric":!0})}',
     'showLyricWindow(){f.lrcWindow&&f.lrcWindow.isDestroyed()&&(f.lrcWindow=null),f.lrcWindow||this.createLyricWindow(),f.lrcWindow.show(),p.default.setConfig({"lyric.enableDesktopLyric":!0})}'),
    # 2. closeLyricWindow：已销毁的窗口不 close
    ('closeLyricWindow(){f.lrcWindow?.close(),f.lrcWindow=null,p.default.setConfig({"lyric.enableDesktopLyric":!1})}',
     'closeLyricWindow(){f.lrcWindow&&!f.lrcWindow.isDestroyed()&&f.lrcWindow.close(),f.lrcWindow=null,p.default.setConfig({"lyric.enableDesktopLyric":!1})}'),
    # 3. resize 回调：窗口已销毁则跳过
    ('o.on("resize",(()=>{const[e,t]=o.getSize(),n=Math.max(Math.min(Math.floor((i-60)/2),80),16);p.default.setConfig({"lyric.fontSize":n,"private.lyricWindowSize":{width:r,height:i}}),r=e,i=t}))',
     'o.on("resize",(()=>{if(o.isDestroyed())return;const[e,t]=o.getSize(),n=Math.max(Math.min(Math.floor((i-60)/2),80),16);p.default.setConfig({"lyric.fontSize":n,"private.lyricWindowSize":{width:r,height:i}}),r=e,i=t}))'),
    # 4. 配置更新回调：setSize 前检查销毁
    ('const l=(e,t,n)=>{"renderer"===n&&e["lyric.fontSize"]&&(i=this.evaluateWindowHeight(),o.setSize(r,i))}',
     'const l=(e,t,n)=>{"renderer"===n&&e["lyric.fontSize"]&&!o.isDestroyed()&&(i=this.evaluateWindowHeight(),o.setSize(r,i))}'),
]

for i, (old, new) in enumerate(patches, 1):
    cnt = data.count(old)
    print(f'补丁{i}: 匹配 {cnt} 次 -> {old[:55]}...')
    if cnt != 1:
        raise SystemExit(f'  预期 1 次匹配，实际 {cnt} 次，中止（补丁{i}）')
    data = data.replace(old, new)

open(path, 'w', encoding='utf-8').write(data)
print('✅ 4 处补丁全部应用成功')
