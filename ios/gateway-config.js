// Installed only by the iOS host, after the unmodified embedded panel loads.
(() => {
  'use strict';
  const original = document.getElementById('cfgForm');
  if (!original) return;
  original.hidden = true;
  const box = document.createElement('div');
  box.className = 'box pad';
  const title = document.createElement('h3');
  title.textContent = '本机网关配置';
  const note = document.createElement('p');
  note.textContent = '只支持下列网关字段；监听地址、存储路径和任务不可修改。保存前请保留非空 API 密钥。';
  const editor = document.createElement('textarea');
  editor.setAttribute('aria-label', '网关 JSON 配置');
  editor.spellcheck = false;
  editor.style.cssText = 'width:100%;min-height:400px;font-family:monospace';
  const read = document.createElement('button');
  read.textContent = '读取配置';
  const save = document.createElement('button');
  save.textContent = '保存配置';
  const result = document.createElement('p');
  const call = async (method, body) => {
    const response = await fetch('/panel/api/config', {
      method, headers: {'Authorization': 'Bearer ' + localStorage.getItem('wb2api.key'), 'Content-Type': 'application/json'},
      ...(body ? {body:JSON.stringify(body)} : {})
    });
    const data = await response.json();
    if (!response.ok) throw Error(data.error || '配置请求失败');
    return data;
  };
  read.onclick = async () => {
    try { editor.value = JSON.stringify((await call('GET')).config, null, 2); result.textContent = '已读取'; }
    catch (error) { result.textContent = error.message; }
  };
  save.onclick = async () => {
    try {
      const config = JSON.parse(editor.value);
      if (typeof config.api_key !== 'string' || !config.api_key.trim()) throw Error('API 密钥不可为空');
      await call('POST', config);
      localStorage.setItem('wb2api.key', config.api_key);
      result.textContent = '已保存并立即生效；复制接入配置可获得当前密钥。';
    } catch (error) { result.textContent = error.message; }
  };
  box.append(title, note, editor, read, save, result);
  original.parentNode.append(box);
  read.click();
})();
