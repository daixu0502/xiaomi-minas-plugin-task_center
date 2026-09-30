(function () {
  'use strict';
var document = window.XiaomiPluginClient.document;
  const $ = id => document.getElementById(id);
  const kinds = {reboot:'重启 NAS',docker_start:'启动容器',docker_stop:'停止容器',docker_restart:'重启容器',docker_image:'镜像容器',script:'用户脚本',cleanup:'安全清理'};
  const states = {running:'执行中',success:'成功',failed:'失败',timeout:'超时',skipped:'已跳过',interrupted:'已中断',requested:'已请求重启'};
  let data = {tasks:[],runs:[]}, templates = [], editing = null, loading = false, toastTimer, resolveConfirm, resolveCleanup, editSession=0, scrollY = 0, focusBefore = null, pickerSelect;
  const triggers = new Map();
  function node(tag, cls, text) { const e=document.createElement(tag); if(cls)e.className=cls; if(text!==undefined)e.textContent=text; return e; }
  async function request(action, body) {
    const r=await window.XiaomiPluginClient.request({plugin:'taskcenter',cgi:'taskcenter.cgi',action,options:{method:'POST',credentials:'same-origin',cache:'no-store',headers:{'Content-Type':'application/json'},body:JSON.stringify(body||{})}});
    let result; try { result=await r.json(); } catch (_) { throw Error('设备返回了无法解析的数据'); }
    if(!result.ok)throw Error(result.error||'操作失败'); return result;
  }
  function toast(text,error) { $('toast').textContent=text; $('toast').className='toast'+(error?' error':''); clearTimeout(toastTimer); toastTimer=setTimeout(()=>{$('toast').textContent='';},4500); }
  async function busy(button, fn) { if(button.disabled)return; button.disabled=true; button.setAttribute('aria-busy','true'); try { await fn(); } catch(e) { toast(e.message,true); } finally { button.disabled=false; button.removeAttribute('aria-busy'); } }
  function button(text, cls, fn, disabled) { const b=node('button',cls,text); b.type='button'; b.disabled=!!disabled; b.onclick=()=>busy(b,()=>fn(b)); return b; }
  function timestamp(value, timezone=data.timezone) {
    if(typeof value==='string')return value; if(!value)return '—';
    const zone=(timezone||'').match(/([+-])(\d{2})(\d{2})$/);
    if(!zone)return new Date(value*1000).toLocaleString();
    const offset=(Number(zone[2])*60+Number(zone[3]))*(zone[1]==='-'?-1:1);
    return new Date((value+offset*60)*1000).toISOString().slice(0,16).replace('T',' ');
  }
  function scheduleText(s) {
    if(s.type==='daily')return '每天 '+s.time;
    if(s.type==='weekly')return '每周 '+(s.days||[s.weekday]).map(d=>'一二三四五六日'[d]).join('、')+' '+s.time;
    if(s.type==='monthly')return '每月 '+s.day+' 日 '+s.time;
    if(s.type==='once')return '仅一次 '+s.at.replace('T',' ');
    if(s.type==='cron')return 'Cron '+s.expression;
    if(s.type==='after_task'){const p=data.tasks.find(t=>t.id===s.taskId);return '成功后联动：'+(p?p.name:'前置任务');}
    if(s.type==='boot')return '开机后 '+s.delay+' 秒';
    return '每隔 '+s.minutes+' 分钟'+(s.window?' · '+s.start+'–'+s.end:'');
  }
  function target(t) { const p=t.params||{}; return p.container||p.image||p.path||(t.kind==='reboot'?'整台 NAS':'尚未配置'); }
  function switchPage(name) {
    document.querySelectorAll('.page').forEach(p=>p.classList.toggle('active',p.id==='page-'+name));
    document.querySelectorAll('[data-page]').forEach(b=>{b.classList.toggle('active',b.dataset.page===name);b.setAttribute('aria-current',b.dataset.page===name?'page':'false');});
  }
  function dialogs() { return Array.from(document.querySelectorAll('.dialog')).filter(e=>!e.hidden); }
  function syncLock() {
    const opened=dialogs().length>0, root=document.documentElement, locked=root.classList.contains('dialog-scroll-locked');
    if(opened&&!locked) { scrollY=window.scrollY; focusBefore=document.activeElement; root.style.setProperty('--dialog-scroll-top',-scrollY+'px'); root.classList.add('dialog-scroll-locked'); }
    if(!opened&&locked) { root.classList.remove('dialog-scroll-locked'); root.style.removeProperty('--dialog-scroll-top'); if(!root.classList.contains('desktop-client'))window.scrollTo(0,scrollY); if(focusBefore&&focusBefore.isConnected)focusBefore.focus({preventScroll:true}); }
    $('backdrop').hidden=!dialogs().some(d=>d.id!=='picker'); $('pickerBackdrop').hidden=$('picker').hidden;
  }
  function show(id) { $(id).hidden=false; syncLock(); const b=$(id).querySelector('button:not(:disabled), input'); if(b)b.focus({preventScroll:true}); }
  function close(id) { $(id).hidden=true; syncLock(); if(id==='picker'&&pickerSelect)triggers.get(pickerSelect).focus({preventScroll:true}); if(id==='cleanupDialog'&&resolveCleanup){const resolve=resolveCleanup;resolveCleanup=null;resolve(false);} }
  function confirm(title,message,risky) {
    $('confirmTitle').textContent=title; $('confirmMessage').textContent=message; $('confirmDialog').classList.toggle('risky',!!risky); $('confirmAccept').className=risky?'danger':'secondary';
    show('confirmDialog'); $('confirmCancel').focus(); return new Promise(resolve=>{resolveConfirm=resolve;});
  }
  function answer(ok) { close('confirmDialog'); const resolve=resolveConfirm; resolveConfirm=null; if(resolve)resolve(ok); }
  $('confirmCancel').onclick=()=>answer(false); $('confirmAccept').onclick=()=>answer(true);
  document.querySelectorAll('[data-close]').forEach(b=>b.onclick=()=>close(b.dataset.close));
  $('pickerBackdrop').onclick=()=>close('picker');
  $('backdrop').onclick=()=>{ if(!$('confirmDialog').hidden)answer(false); else if(!$('logDialog').hidden)close('logDialog'); };
  document.addEventListener('keydown',e=>{
    const open=dialogs(); if(!open.length)return; const top=open.find(d=>d.id==='picker')||open.find(d=>d.id==='confirmDialog')||open[open.length-1];
    if(e.key==='Escape') { e.preventDefault(); if(top.id==='confirmDialog')answer(false); else close(top.id); }
    if(e.key==='Tab') { const items=Array.from(top.querySelectorAll('button:not(:disabled),input:not(:disabled),textarea:not(:disabled),[tabindex="0"]')).filter(n=>n.getClientRects().length); const first=items[0],last=items[items.length-1]; if(e.shiftKey&&document.activeElement===first){e.preventDefault();last.focus();}else if(!e.shiftKey&&document.activeElement===last){e.preventDefault();first.focus();} }
  });
  // Contain touch gestures even on older iOS WebViews without overscroll-behavior.
  let touchY=0;
  document.addEventListener('touchstart',e=>{if(e.touches.length===1)touchY=e.touches[0].clientY;},{passive:true});
  document.addEventListener('touchmove',e=>{
    if(!dialogs().length||e.touches.length!==1)return;
    const dy=e.touches[0].clientY-touchY; touchY=e.touches[0].clientY;
    let el=e.target; let canScroll=false;
    while(el&&el!==document.body) { if(el.scrollHeight>el.clientHeight+1&&/(auto|scroll)/.test(getComputedStyle(el).overflowY)&&((dy>0&&el.scrollTop>0)||(dy<0&&el.scrollTop+el.clientHeight<el.scrollHeight-1))){canScroll=true;break;} if(el.classList&&el.classList.contains('dialog'))break; el=el.parentElement; }
    if(!canScroll)e.preventDefault();
  },{passive:false});
  function syncSelect(select) { const b=triggers.get(select); if(b)b.textContent=select.selectedOptions[0]?select.selectedOptions[0].textContent:'请选择'; }
  document.querySelectorAll('select').forEach(select=>{
    const b=node('button','pick-trigger'); b.type='button'; b.setAttribute('aria-haspopup','dialog'); select.hidden=true; select.after(b); triggers.set(select,b); syncSelect(select);
    select.addEventListener('change',()=>syncSelect(select));
    b.onclick=()=>{pickerSelect=select; $('pickerTitle').textContent=select.parentElement.firstChild.textContent.trim()||'选择选项'; $('pickerOptions').replaceChildren(); Array.from(select.options).forEach(o=>{const opt=button(o.textContent,o.selected?'selected':'',()=>{select.value=o.value;select.dispatchEvent(new Event('change'));close('picker');},o.disabled);$('pickerOptions').append(opt);});show('picker');};
  });
  function setSelect(id,value) { $(id).value=String(value); syncSelect($(id)); }
  function updateFields() {
    const kind=$('taskKind').value, s=$('scheduleType').value;
    $('containerFields').hidden=!['docker_start','docker_stop','docker_restart'].includes(kind); $('imageFields').hidden=kind!=='docker_image'; $('scriptFields').hidden=kind!=='script'; $('rebootWarning').hidden=kind!=='reboot';
    $('cleanupFields').hidden=kind!=='cleanup';
    $('timeField').hidden=!['daily','weekly','workdays','weekends','monthly'].includes(s); $('weekdayField').hidden=s!=='weekly'; $('intervalField').hidden=s!=='interval'; $('delayField').hidden=s!=='boot';
    $('monthField').hidden=s!=='monthly';$('onceField').hidden=s!=='once';$('cronField').hidden=s!=='cron';$('dependencyField').hidden=s!=='after_task';$('windowFields').hidden=s!=='interval';$('windowTimes').hidden=!$('useWindow').checked;
    $('previewSchedule').hidden=['boot','after_task'].includes(s);$('schedulePreview').hidden=true;
    const retryAllowed=['docker_start','script'].includes(kind);$('retryEnabled').disabled=!retryAllowed;if(!retryAllowed)$('retryEnabled').checked=false;$('retryFields').hidden=!$('retryEnabled').checked;
    $('scheduleHelp').textContent=(s==='interval'?'按固定分钟边界执行，不是从启用时计时；窗口包含开始/结束分钟，不跨午夜。':s==='boot'?'只在启用后的下一次开机生效，最多等待前置条件 30 分钟。':s==='monthly'?'某月不存在所选日期时跳过该月。':s==='once'?'错过不补跑；触发一次后自动停用。':s==='after_task'?'联动按分钟检查，不要求父任务保持启用；父任务手动执行也可触发。':'每分钟检查一次。')+' 使用 NAS 时区：'+(data.timezone||'正在读取');
  }
  $('taskKind').onchange=updateFields; $('scheduleType').onchange=updateFields;
  $('useWindow').onchange=updateFields;$('retryEnabled').onchange=updateFields;
  function collectSchedule() {
    const typ=$('scheduleType').value,s={type:typ};
    if(['daily','weekly','workdays','weekends','monthly'].includes(typ))s.time=$('scheduleTime').value;
    if(typ==='weekly')s.days=Array.from(document.querySelectorAll('#weekdayField input:checked')).map(n=>Number(n.value));
    if(typ==='monthly')s.day=Number($('monthDay').value);if(typ==='once')s.at=$('onceAt').value;
    if(typ==='interval')Object.assign(s,{minutes:Number($('interval').value),window:$('useWindow').checked,start:$('windowStart').value,end:$('windowEnd').value});
    if(typ==='boot')s.delay=Number($('delay').value);if(typ==='cron')s.expression=$('cronExpression').value;if(typ==='after_task')s.taskId=$('parentTask').value;
    return s;
  }
  $('previewSchedule').onclick=()=>busy($('previewSchedule'),async()=>{const r=await request('schedule_preview',{schedule:collectSchedule()});$('schedulePreview').replaceChildren(node('strong','','未来执行时间（'+r.timezone+'）'),...r.times.map(t=>node('div','',timestamp(t))));if(!r.times.length)$('schedulePreview').append(node('p','','未来 8 年未找到执行时间，或一次性时间已过去。'));$('schedulePreview').hidden=false;});
  function fillOptions(id,values,current) { const s=$(id); s.replaceChildren(new Option(id==='container'?'请选择容器':'请选择镜像','')); [...new Set(values.concat(current?[current]:[]))].forEach(v=>s.add(new Option(v,v))); setSelect(id,current||''); }
  async function edit(task,isTemplate) {
    const session=++editSession;
    editing=task&&!isTemplate?task.id:null; const t=task||{name:'',kind:'docker_start',params:{},schedule:{type:'daily',time:'02:00'},timeout:300,waitPool:true}; const p=t.params||{}, s=t.schedule;
    $('editorTitle').textContent=editing?'编辑任务':'新建任务'; $('taskName').value=t.name; setSelect('taskKind',t.kind); setSelect('scheduleType',s.type); $('scheduleTime').value=s.time||'02:00'; $('interval').value=s.minutes||60; $('delay').value=s.delay||120; $('timeout').value=t.timeout||300; $('waitPool').checked=t.waitPool!==false; $('containerName').value=p.name||''; $('scriptPath').value=p.path||'';
    document.querySelectorAll('#weekdayField input').forEach(n=>n.checked=(s.days||[s.weekday===undefined?0:s.weekday]).includes(Number(n.value)));
    $('monthDay').value=s.day||1;$('onceAt').value=s.at||'';$('cronExpression').value=s.expression||'0 3 * * 1-5';$('useWindow').checked=!!s.window;$('windowStart').value=s.start||'08:00';$('windowEnd').value=s.end||'22:00';
    $('parentTask').replaceChildren(new Option('请选择前置任务',''));data.tasks.filter(j=>j.id!==editing).forEach(j=>$('parentTask').add(new Option(j.name,j.id)));setSelect('parentTask',s.taskId||'');
    const conditions=t.conditions||{};$('dockerReady').checked=conditions.dockerReady===true;$('conditionPaths').value=(conditions.paths||[]).join('\n');
    const retry=t.retry||{};$('retryEnabled').checked=!!retry.enabled;$('retryMinutes').value=retry.minutes||5;$('retryMax').value=retry.max||3;
    setSelect('cleanupMode',p.mode||'logs');$('cleanupPath').value=p.path||'';$('cleanupDays').value=p.days||30;$('cleanupMaxFiles').value=p.maxFiles||1000;$('cleanupMaxMiB').value=p.maxMiB||1024;$('cleanupRecursive').checked=p.recursive!==false;
    fillOptions('container',[],p.container); fillOptions('image',[],p.image); $('resourceError').textContent='正在读取 Docker 容器与镜像…'; updateFields(); show('editor');
    try { const r=await request('resources'); if($('editor').hidden||session!==editSession)return; fillOptions('container',r.containers.map(c=>c.Names),p.container); fillOptions('image',r.images.map(i=>i.Repository==='<none>'||i.Tag==='<none>'?i.ID:i.Repository+':'+i.Tag),p.image); $('resourceError').textContent='Docker 操作会影响整台 NAS 上的容器，请确认目标。'; }
    catch(e) { if(session===editSession)$('resourceError').textContent=e.message+'；仍可配置脚本、重启和清理任务。'; }
  }
  $('taskForm').onsubmit=e=>{e.preventDefault();busy($('saveTask'),async()=>{
    const kind=$('taskKind').value, schedule=collectSchedule();
    const params=kind==='cleanup'?{mode:$('cleanupMode').value,path:$('cleanupPath').value,days:Number($('cleanupDays').value),recursive:$('cleanupRecursive').checked,maxFiles:Number($('cleanupMaxFiles').value),maxMiB:Number($('cleanupMaxMiB').value)}:kind==='script'?{path:$('scriptPath').value}:kind==='docker_image'?{image:$('image').value,name:$('containerName').value}:{container:$('container').value};
    const result=await request('save',{task:{id:editing,name:$('taskName').value,kind,params,schedule,timeout:Number($('timeout').value),waitPool:$('waitPool').checked,conditions:{dockerReady:$('dockerReady').checked,paths:$('conditionPaths').value.split('\n').map(p=>p.trim()).filter(Boolean)},retry:{enabled:$('retryEnabled').checked,minutes:Number($('retryMinutes').value),max:Number($('retryMax').value)}}});
    close('editor');switchPage('tasks');toast(result.message);await refresh();
  });};
  function warning(t) { const base=t.kind==='cleanup'?'将永久删除指定范围内符合规则的文件，不能撤销。':t.kind==='reboot'?'到执行时将请求 1 分钟后重启整台 NAS，中断全部用户和服务。':t.kind==='script'?'将以当前 NAS 用户权限执行脚本，请确认脚本内容可信。':'将操作 NAS 上的 Docker 容器，可能影响正在运行的服务。';return base+(t.retry&&t.retry.enabled?'\n失败/超时后每隔 '+t.retry.minutes+' 分钟重试，最多 '+t.retry.max+' 次，不含首次。脚本需能安全重复执行。':''); }
  function reviewCleanup(r,task,proceed) {
    const size=r.bytes<1024?r.bytes+' 字节':r.bytes<1048576?(r.bytes/1024).toFixed(2)+' KiB':(r.bytes/1048576).toFixed(2)+' MiB';
    $('cleanupSummary').textContent='目录：'+r.path+'\n规则：'+r.patterns.join('、')+'；修改时间超过 '+task.params.days+' 天\n预计 '+r.count+' 个文件，共 '+size+'\n单次上限：'+task.params.maxFiles+' 个 / '+task.params.maxMiB+' MiB';
    $('cleanupSamples').textContent=r.samples.length?'匹配文件示例（最多 40 个）：\n'+r.samples.join('\n'):'当前没有匹配的旧文件。';$('cleanupContinue').hidden=!proceed;$('cleanupCancel').textContent=proceed?'取消':'关闭';show('cleanupDialog');return new Promise(resolve=>{resolveCleanup=resolve;});
  }
  $('cleanupCancel').onclick=()=>close('cleanupDialog');$('cleanupContinue').onclick=()=>{const resolve=resolveCleanup;resolveCleanup=null;close('cleanupDialog');if(resolve)resolve(true);};
  async function previewCleanup(task) { const r=await request('cleanup_preview',{id:task.id});await reviewCleanup(r,task,false); }
  async function operate(t,action) {
    let body={id:t.id,confirmed:true}, title, message;
    if(t.kind==='cleanup'&&(action==='run'||(action==='toggle'&&!t.enabled))) { const r=await request('cleanup_preview',{id:t.id});if(!await reviewCleanup(r,t,true))return;body.previewToken=r.previewToken; }
    if(action==='toggle') { body.enabled=!t.enabled; title=t.enabled?'停用任务？':'启用任务？'; message=t.enabled?'停止后续自动调度，不会中断已开始的执行。':t.name+'\n'+scheduleText(t.schedule)+'\n'+warning(t)+(t.schedule.type==='boot'?'\n仅下一次开机生效。':''); }
    if(action==='run') { title='立即执行此任务？'; message=t.name+'\n'+warning(t)+'\n这次执行不会自动启用定时计划。'; }
    if(action==='delete') { title='删除任务？'; message='删除“'+t.name+'”的计划，保留历史记录；不会删除脚本、容器或用户文件。'; }
    if(action==='cancel_retry') { title='取消自动重试？';message='取消等待中的重试，不终止当前执行，也不关闭后续正常计划。'; }
    if(!await confirm(title,message,action==='delete'||t.kind==='reboot'||t.kind==='cleanup'||action==='run'))return;
    const r=await request(action,body);toast(r.message);await refresh();
  }
  function taskCard(t,isTemplate) {
    const card=node('article','task-card'), head=node('div','task-head'), left=node('div'); left.append(node('h3','',t.name)); head.append(left,node('span','badge'+(t.enabled?' enabled':''),isTemplate?'模板':t.running?'执行中':t.enabled?'已启用':'已停用')); card.append(head);
    const meta=node('div','task-meta'); [kinds[t.kind],scheduleText(t.schedule),isTemplate?'默认停用':target(t)].forEach(v=>meta.append(node('span','chip',v)));card.append(meta);
    if(t.description)card.append(node('p','',t.description));
    if(!isTemplate&&t.enabled)card.append(node('p','','下次：'+timestamp(t.nextRun)));
    if(t.retryAt)card.append(node('p','','等待重试：'+timestamp(t.retryAt)));
    if(t.waitingReason)card.append(node('p','','等待前置条件：'+t.waitingReason));
    if(t.kind==='cleanup'&&!isTemplate)card.append(node('p','',t.cleanupApproved?'已确认清理规则；修改保存后需重新预览。':'启用/立即执行之前会先显示清理预览。'));
    const actions=node('div','actions');
    if(isTemplate)actions.append(button('使用模板','secondary',()=>edit(t,true)));
    else { actions.append(button('编辑','secondary',()=>edit(t,false),t.running),button(t.enabled?'停用':'启用','secondary',()=>operate(t,'toggle')),button('立即执行','secondary',()=>operate(t,'run'),t.running||!!t.retryAt||!data.scheduler));if(t.kind==='cleanup')actions.append(button('预览清理','secondary',()=>previewCleanup(t),t.running));if(t.retryAt)actions.append(button('取消重试','secondary',()=>operate(t,'cancel_retry')));actions.append(button('删除','danger',()=>operate(t,'delete'),t.running)); }
    card.append(actions);return card;
  }
  function runCard(r) {
    const card=node('article','task-card'), head=node('div','task-head');head.append(node('h3','',r.name),node('span','badge'+(['failed','timeout','interrupted'].includes(r.state)?' failed':r.state==='success'?' enabled':''),states[r.state]||r.state));card.append(head,node('p','',timestamp(r.started)+' · '+({manual:'手动执行',retry:'自动重试 #'+r.attempt,dependency:'成功后联动',schedule:'计划执行'}[r.source]||r.source)),node('p','',r.message));
    const a=node('div','actions');a.append(button('查看输出','secondary',async()=>{const d=await request('log',{id:r.id});$('logTitle').textContent=r.name;$('logText').textContent=d.text;show('logDialog');}));card.append(a);return card;
  }
  function list(id,items,renderer,empty) { $(id).replaceChildren(...(items.length?items.map(renderer):[node('div','empty',empty)])); }
  function render() {
    const heartbeat=data.lastTick&&data.serverTime-data.lastTick<180;
    $('health').textContent=!data.scheduler?'调度已停用':heartbeat?'调度正常':'等待调度心跳'; $('health').className='badge'+(data.scheduler&&heartbeat?' enabled':'');
    $('clock').textContent='NAS 时间 '+timestamp(data.serverTime)+' · '+(data.timezone||''); $('poolInfo').textContent=data.poolReady?'存储池已挂载，可执行要求存储池就绪的任务。':'存储池尚未挂载：依赖存储池的任务不会执行。';
    $('countTotal').textContent=data.tasks.length;$('countEnabled').textContent=data.tasks.filter(t=>t.enabled).length;$('countRunning').textContent=data.runs.filter(r=>r.state==='running').length;$('countFailed').textContent=data.runs.filter(r=>['failed','timeout','interrupted'].includes(r.state)).length;
    $('taskSummary').textContent=data.tasks.length+' 个任务 · '+data.tasks.filter(t=>t.enabled).length+' 个已启用';
    list('taskList',data.tasks,t=>taskCard(t,false),'暂无任务，可从模板创建。');list('templateList',templates,t=>taskCard(t,true),'正在读取模板…');list('historyList',data.runs,runCard,'还没有执行记录。安装后所有预置任务保持停用。');list('recent',data.runs.slice(0,3),runCard,'尚未执行任务，先配置并手动启用一个模板吧。');
    $('version').textContent='插件版本 '+(data.pluginVersion||'1.0.0')+(data.helperVersion?' · 公共权限组件 '+data.helperVersion:'');
  }
  async function refresh() { if(loading)return; loading=true;try{data=await request('list');if(!templates.length)templates=(await request('templates')).templates;render();}finally{loading=false;} }
  document.querySelectorAll('[data-page]').forEach(b=>b.onclick=()=>switchPage(b.dataset.page));document.querySelectorAll('[data-go]').forEach(b=>b.onclick=()=>switchPage(b.dataset.go));
  $('newTask').onclick=()=>busy($('newTask'),()=>edit());$('refresh').onclick=()=>busy($('refresh'),refresh);$('refreshHistory').onclick=()=>busy($('refreshHistory'),refresh);
  refresh().catch(e=>{ $('health').textContent='连接失败';toast(e.message,true); });
  setInterval(()=>{if(!document.hidden&&!dialogs().length)refresh().catch(()=>{});},15000);
})();
