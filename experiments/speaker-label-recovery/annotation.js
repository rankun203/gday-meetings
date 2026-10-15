const AnnotationContract = {
  validate(data, payload, strict = true) {
    if (payload.version !== 1 || payload.reviewId !== data.reviewId || payload.inputHash !== data.inputHash || !Array.isArray(payload.labels)) throw new Error('These labels belong to a different batch.');
    if (strict && payload.kind !== 'speaker_target_annotations') throw new Error('Choose an exported speaker annotation file.');
    const targets = new Map(data.items.flatMap(item => item.targets.map(target => [target.id, {item,target}]))), seen = new Set();
    const decisions = new Set(['reference','custom_reference','other','no_speech','overlap','unsure','speech_present',null]);
    return payload.labels.map(label => {
      const match = targets.get(label.targetId);
      if (!match || seen.has(label.targetId) || !decisions.has(label.decision)) throw new Error('The file contains an invalid target or decision.');
      seen.add(label.targetId);
      const presence = match.target.type === 'clipSpeechPresence';
      if ((presence && !['speech_present','no_speech','overlap','unsure',null].includes(label.decision)) || (!presence && label.decision === 'speech_present')) throw new Error('Choose a result appropriate to this target.');
      if (strict && (label.itemId !== match.item.id || label.track !== match.item.track || label.audioHash !== data.tracks[match.item.track].sha256)) throw new Error('A label does not match its original audio or clip.');
      if (!label.flags || typeof label.flags !== 'object' || Array.isArray(label.flags) || Object.values(label.flags).some(x => typeof x !== 'boolean')) throw new Error('Label flags must be true or false.');
      if (label.decision === 'reference' && !match.item.references.some(r => r.id === label.referenceId)) throw new Error('A reference does not belong to this clip.');
      if (label.decision === 'custom_reference' && !(Number.isFinite(label.referenceStart) && Number.isFinite(label.referenceEnd) && label.referenceStart >= 0 && label.referenceStart < label.referenceEnd && label.referenceEnd <= data.tracks[match.item.track].duration && label.referenceEnd - label.referenceStart <= 30)) throw new Error('Custom references must be within the track and no longer than 30 seconds.');
      if (label.decision === 'custom_reference' && label.referenceStart < match.target.end && label.referenceEnd > match.target.start) throw new Error('Choose a separate reference that does not overlap this target.');
      return {targetId:label.targetId,itemId:match.item.id,track:match.item.track,audioHash:data.tracks[match.item.track].sha256,decision:label.decision,
        referenceId:label.decision === 'reference' ? label.referenceId : null,
        referenceStart:label.decision === 'custom_reference' ? label.referenceStart : null,
        referenceEnd:label.decision === 'custom_reference' ? label.referenceEnd : null,
        otherSpeaker:typeof label.otherSpeaker === 'string' ? label.otherSpeaker.slice(0,200) : '',
        flags:{timingWrong:!!label.flags?.timingWrong,missingWord:!!label.flags?.missingWord,referenceUnusable:!!label.flags?.referenceUnusable},
        notes:typeof label.notes === 'string' ? label.notes.slice(0,10000) : '',updatedAt:label.updatedAt || null};
    });
  },
  export(data, labels) { return {version:1,kind:'speaker_target_annotations',reviewId:data.reviewId,inputHash:data.inputHash,exportedAt:new Date().toISOString(),labels:this.validate(data,{version:1,reviewId:data.reviewId,inputHash:data.inputHash,labels:Object.values(labels)},false)}; }
};
if (typeof module !== 'undefined') module.exports = AnnotationContract;
if (typeof document !== 'undefined') {
const data = JSON.parse(document.getElementById('data').textContent), $ = id => document.getElementById(id);
const storageKey = 'speaker-annotation-v1-' + data.reviewId;
let labels = {}, index = 0, playEnd = null;
const time = seconds => { const s = Math.floor(seconds);return `${Math.floor(s/60)}:${String(s%60).padStart(2,'0')}`; };
const preciseTime = seconds => { const centiseconds = Math.round(seconds * 100); return `${Math.floor(centiseconds / 6000)}:${String(Math.floor(centiseconds / 100) % 60).padStart(2,'0')}.${String(centiseconds % 100).padStart(2,'0')}`; };
const current = () => data.items[index];
const status = (message,error=false) => { $('saved').textContent=message; $('saved').className=error?'small error':'small'; };
function persist() { try {localStorage.setItem(storageKey,JSON.stringify(AnnotationContract.export(data,labels)));status('Saved in this browser. Export a copy when finished.');}catch(e){status('Could not save in this browser. Export labels before closing this page.',true);} count(); }
try { const saved=localStorage.getItem(storageKey);if(saved)labels=Object.fromEntries(AnnotationContract.validate(data,JSON.parse(saved)).map(x=>[x.targetId,x])); } catch(e){status('Saved labels could not be loaded. You can import an exported copy.',true);}
function count(){const all=data.items.flatMap(i=>i.targets);$('progress').textContent=`${all.filter(t=>labels[t.id]?.decision).length} of ${all.length} targets labeled · Clip ${index+1} of ${data.items.length}`;}
function play(start,end){const audio=$('audio'),duration=data.tracks[current().track].duration;start=Math.max(0,start);end=Math.min(duration,end);if(!(start<end))return;playEnd=end;audio.currentTime=start;audio.play().catch(()=>status('Playback could not start. Use the audio controls to try again.',true));}
function element(tag,text,className){const e=document.createElement(tag);if(text!==undefined)e.textContent=text;if(className)e.className=className;return e;}
function button(text,action){const b=element('button',text);b.type='button';b.onclick=action;return b;}
function show(){const item=current();$('audio').pause();playEnd=null;$('clip').value=String(index);const src=data.tracks[item.track].audio;if($('audio').getAttribute('src')!==src)$('audio').src=src;$('position').textContent=`${data.tracks[item.track].source} · ${time(item.start)}–${time(item.end)}`;
$('previous').disabled=index===0;$('next').disabled=index===data.items.length-1;
const context=$('context');context.replaceChildren();let cursor=0;const ranges=item.targets.filter(t=>t.contextRange).sort((a,b)=>a.contextRange.location-b.contextRange.location);
for(const t of ranges){const r=t.contextRange;if(r.location<cursor||r.location+r.length>item.contextText.length)continue;context.append(document.createTextNode(item.contextText.slice(cursor,r.location)));const b=button(item.contextText.slice(r.location,r.location+r.length),()=>{play(t.start-.35,t.end+.35);document.getElementById('target-'+t.id)?.scrollIntoView({block:'nearest'});});b.className='targetlink';const number=item.targets.findIndex(target=>target.id===t.id)+1;const badge=element('span',String(number),'targetnumber');badge.setAttribute('aria-hidden','true');b.prepend(badge);b.setAttribute('aria-label',`Play Target ${number}: ${t.text}`);b.title=`Replay Target ${number}`;context.append(b);cursor=r.location+r.length;}
context.append(document.createTextNode(item.contextText.slice(cursor)||(!item.contextText?'No transcript text is available. Listen for speech in this clip.':'')));
$('references').replaceChildren();for(const r of item.references){$('references').append(button(`Play ${r.label} · ${r.relation==='previous'?'Before':'After'} · ${time(r.start)}`,()=>play(r.start,r.end)));}
$('targets').replaceChildren();item.targets.forEach((target,number)=>renderTarget(item,target,number));count();}
function renderTarget(item,target,number){const old=labels[target.id]||{},section=element('div',undefined,'target');section.id='target-'+target.id;const head=element('div',undefined,'targethead');head.append(button(`Play Target ${number+1}`,()=>play(target.start-.35,target.end+.35)));const title=element('div');title.append(element('p',target.text || 'Listen for speech', 'targettext'),element('span',`${preciseTime(target.start)}–${preciseTime(target.end)}${target.granularity && target.granularity !== 'word' ? ' · Coarse timing: judge the highlighted text as a whole' : ''}`,'small'));head.append(title);section.append(head);
const fields=element('div',undefined,'fields'),decisionLabel=element('label',target.type==='clipSpeechPresence'?'Is speech audible?':'Who is speaking?'),select=element('select');select.setAttribute('aria-label',`Judgment for target ${number+1}`);select.append(new Option('Choose a Result',''));
if(target.type!=='clipSpeechPresence')for(const r of item.references)select.append(new Option(`Same Voice as ${r.label} (${r.relation==='previous'?'Before':'After'})`,'ref:'+r.id));
const choices=target.type==='clipSpeechPresence'?[['speech_present','Speech Present'],['no_speech','No Speech (Silence or Noise)'],['overlap','Overlapping Voices'],['unsure','Unsure']]:[['custom_reference','Same Voice as Another Audio Reference'],['other','Other Speaker'],['no_speech','No Speech (Silence or Noise)'],['overlap','Overlapping Voices'],['unsure','Unsure']];for(const [v,t] of choices)select.append(new Option(t,v));
select.value=old.decision==='reference'?'ref:'+old.referenceId:old.decision||'';decisionLabel.append(select);fields.append(decisionLabel);
const otherLabel=element('label','Other speaker identifier · optional'),other=element('input');other.type='text';other.maxLength=200;other.placeholder='For example, Voice C';other.value=old.otherSpeaker||'';otherLabel.append(other);fields.append(otherLabel);section.append(fields);
const custom=element('div',undefined,'custom'),start=element('input'),end=element('input');for(const e of [start,end]){e.type='number';e.min='0';e.step='.1';}start.value=old.referenceStart??'';end.value=old.referenceEnd??'';start.placeholder='Start · sec';end.placeholder='End · sec';start.setAttribute('aria-label','Custom reference start in seconds');end.setAttribute('aria-label','Custom reference end in seconds');custom.append(start,end,button('Play Reference',()=>{if(Number(end.value)-Number(start.value)>30){status('Choose a reference no longer than 30 seconds.',true);return;}play(Number(start.value),Number(end.value));}));section.append(custom);
const flags=element('div',undefined,'flags'),checks={};for(const [key,text] of [['timingWrong','Timing Is Wrong'],['missingWord','A Word Is Missing'],['referenceUnusable','Reference Is Unclear or Has Multiple Voices']]){const label=element('label'),check=element('input');check.type='checkbox';check.checked=!!old.flags?.[key];checks[key]=check;label.append(check,document.createTextNode(text));flags.append(label);}section.append(flags);
const noteLabel=element('label','Notes · optional'),notes=element('textarea');notes.maxLength=10000;notes.value=old.notes||'';notes.setAttribute('aria-label',`Notes for target ${number+1}`);noteLabel.append(notes);section.append(noteLabel);
function visibility(){custom.hidden=select.value!=='custom_reference';otherLabel.hidden=select.value!=='other';}
function save(){visibility();const choice=select.value;const label={targetId:target.id,decision:choice.startsWith('ref:')?'reference':choice||null,referenceId:choice.startsWith('ref:')?choice.slice(4):null,referenceStart:Number(start.value),referenceEnd:Number(end.value),otherSpeaker:other.value,flags:{timingWrong:checks.timingWrong.checked,missingWord:checks.missingWord.checked,referenceUnusable:checks.referenceUnusable.checked},notes:notes.value,updatedAt:new Date().toISOString()};try{const normalized=AnnotationContract.validate(data,{version:1,reviewId:data.reviewId,inputHash:data.inputHash,labels:[label]},false)[0];labels[target.id]=normalized;persist();}catch(e){delete labels[target.id];persist();status(e.message + ' This target is not yet saved.',true);}}
select.onchange=save;other.oninput=save;notes.oninput=save;start.oninput=save;end.oninput=save;for(const c of Object.values(checks))c.onchange=save;visibility();$('targets').append(section);}
for(let i=0;i<data.items.length;i++)$('clip').append(new Option(`Clip ${i+1} · ${data.tracks[data.items[i].track].source} · ${time(data.items[i].start)}`,String(i)));
$('clip').onchange=()=>{index=Number($('clip').value);show();};$('previous').onclick=()=>{if(index>0){index--;show();}};$('next').onclick=()=>{if(index<data.items.length-1){index++;show();}};
$('unreviewed').onclick=()=>{for(let step=1;step<=data.items.length;step++){const n=(index+step)%data.items.length;if(data.items[n].targets.some(t=>!labels[t.id]?.decision)){index=n;show();return;}}status('Every target has a judgment. Export labels when finished.');};$('play').onclick=()=>play(current().start,current().end);
$('audio').addEventListener('timeupdate',()=>{if(playEnd!==null&&$('audio').currentTime>=playEnd){$('audio').pause();playEnd=null;}});
$('export').onclick=()=>{const blob=new Blob([JSON.stringify(AnnotationContract.export(data,labels),null,2)],{type:'application/json'}),url=URL.createObjectURL(blob),a=element('a');a.href=url;a.download='speaker-annotations-'+data.reviewId.slice(0,12)+'.json';a.click();setTimeout(()=>URL.revokeObjectURL(url),1000);};
$('import').onclick=()=>$('file').click();$('file').onchange=async()=>{const file=$('file').files[0];if(!file)return;try{if(file.size>5000000)throw new Error('Choose a label file smaller than 5 MB.');const imported=AnnotationContract.validate(data,JSON.parse(await file.text()));for(const label of imported)labels[label.targetId]=label;persist();show();status(`Imported ${imported.length} target labels.`);}catch(e){status(e.message,true);}finally{$('file').value='';}};
if(data.items.length)show();else status('This batch has no clips.',true);
}
