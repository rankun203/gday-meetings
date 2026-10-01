'use strict';
const $ = id => document.getElementById(id);
const state = { samples: [], sample: null, data: null, clipId: null, selection: null, selected: null, history: [], generation: 0, saved: 0, saving: null, conflict: false, waveform: null, loadToken: 0, playbackEnd: null, navigating: false };
const copy = value => structuredClone(value);
const clip = () => state.data?.clips.find(item => item.id === state.clipId);
const duration = () => clip()?.durationSeconds || 1;
const time = value => `${Math.floor(value / 60)}:${(value % 60).toFixed(2).padStart(5, '0')}`;
const bound = value => Math.max(0, Math.min(duration(), value));
const speakerName = value => /^speaker-\d+$/.test(value) ? `Speaker ${Number(value.split('-')[1])}` : value;
let saveTimer;
function error(message) {
  $('error').replaceChildren(document.createTextNode(message));
  const close = document.createElement('button'); close.textContent = 'Dismiss'; close.onclick = () => { $('error').hidden = true; }; $('error').append(close); $('error').hidden = false;
}
async function request(path, options = {}) {
  const response = await fetch(path, { ...options, headers: { 'Content-Type': 'application/json', ...options.headers } });
  const body = await response.json();
  if (!response.ok) { const failure = new Error(body.error || `Request failed (${response.status}).`); failure.status = response.status; throw failure; }
  return body;
}
function mutate(action, invalidate = true) {
  if (!state.data || state.conflict) return;
  state.history.push(copy({ clips: state.data.clips, speakerReferences: state.data.speakerReferences || [] }));
  if (state.history.length > 100) state.history.shift();
  action();
  normalizeUncertainty();
  if (invalidate) { clip().status = 'unreviewed'; clip().reviewedRegions = []; }
  state.generation++; $('save-state').textContent = 'Unsaved Changes';
  clearTimeout(saveTimer); saveTimer = setTimeout(() => save().catch(() => {}), 450);
  render();
}
async function save() {
  clearTimeout(saveTimer);
  if (state.saving) return state.saving;
  if (state.conflict) throw new Error('Load the saved annotations before continuing.');
  state.saving = (async () => {
    while (state.saved < state.generation) {
      const generation = state.generation;
      $('save-state').textContent = 'Saving…';
      try {
        const result = await request(`/api/samples/${encodeURIComponent(state.sample)}`, { method: 'PUT', body: JSON.stringify({ revision: state.data.revision, clips: state.data.clips, speakerReferences: state.data.speakerReferences || [] }) });
        state.data.revision = result.revision; state.saved = generation; $('save-state').textContent = 'Saved';
      } catch (failure) {
        $('save-state').textContent = 'Changes Not Saved';
        if (failure.status === 409) { state.conflict = true; $('conflict').hidden = false; render(); }
        else error(`${failure.message} Your changes remain in this window. Edit again to retry saving.`);
        throw failure;
      }
    }
  })();
  try { await state.saving; } finally { state.saving = null; }
}
async function openClip(sample, id) {
  if (state.navigating) return;
  state.navigating = true; renderNavigation();
  try {
    await save();
    $('audio').pause(); if (referenceAudio) referenceAudio.pause(); state.playbackEnd = null;
    if (sample !== state.sample) {
      const data = await request(`/api/samples/${encodeURIComponent(sample)}`);
      state.data = data; state.sample = sample; state.generation = 0; state.saved = 0; state.history = [];
    }
    state.clipId = id; state.selection = null; state.selected = null; state.waveform = null;
    $('zoom').value = '1'; $('timeline').style.width = '100%'; $('timeline-scroll').scrollLeft = 0;
    $('audio').src = audioURL(sample, id); $('audio').playbackRate = Number($('speed').value);
    $('save-state').textContent = 'Saved'; $('export-result').hidden = true; render();
    loadWaveform(sample, id);
  } catch (failure) { error(failure.message); }
  finally { state.navigating = false; renderNavigation(); }
}
function audioURL(sample, id) { return `/api/audio/${encodeURIComponent(sample)}/${encodeURIComponent(id)}`; }
async function loadWaveform(sample, id) {
  const token = ++state.loadToken; $('audio-state').textContent = 'Loading Waveform…';
  let context;
  try {
    const response = await fetch(audioURL(sample, id));
    if (!response.ok) throw new Error('Audio could not be loaded.');
    context = new AudioContext(); const buffer = await context.decodeAudioData(await response.arrayBuffer());
    if (token !== state.loadToken) return;
    // Keep a compact peak envelope so long clips do not redraw their full PCM data.
    const bins = 12000, peaks = new Float32Array(bins), stride = Math.max(1, Math.ceil(buffer.length / bins));
    for (let channel = 0; channel < buffer.numberOfChannels; channel++) {
      const samples = buffer.getChannelData(channel);
      for (let bin = 0; bin < bins; bin++) { let peak = peaks[bin]; for (let n = bin * stride; n < Math.min(samples.length, (bin + 1) * stride); n++) peak = Math.max(peak, Math.abs(samples[n])); peaks[bin] = peak; }
    }
    state.waveform = peaks; drawWaveform(); $('audio-state').textContent = '';
  } catch (failure) { if (token === state.loadToken) $('audio-state').textContent = 'Waveform unavailable. Use the audio player and selection fields to review this clip.'; }
  finally { if (context) await context.close(); }
}
function drawWaveform() {
  const canvas = $('waveform'), width = Math.max(1, canvas.clientWidth), ratio = window.devicePixelRatio || 1;
  canvas.width = width * ratio; canvas.height = 150 * ratio;
  const ctx = canvas.getContext('2d'); ctx.scale(ratio, ratio); ctx.strokeStyle = '#547fad'; ctx.lineWidth = 1; ctx.beginPath();
  const peaks = state.waveform;
  for (let x = 0; x < width; x++) { const value = peaks ? peaks[Math.min(peaks.length - 1, Math.floor(x / width * peaks.length))] : 0; const height = Math.max(1, value * 66); ctx.moveTo(x, 75 - height); ctx.lineTo(x, 75 + height); } ctx.stroke();
  $('ruler').replaceChildren();
  const count = Math.max(2, Math.floor(width / 90));
  for (let n = 1; n < count; n++) { const mark = document.createElement('span'); mark.textContent = time(n / count * duration()); mark.style.left = `${n / count * 100}%`; $('ruler').append(mark); }
}
function renderNavigation() {
  const currentSample = state.samples.find(sample => sample.id === state.sample);
  if (currentSample && state.data) currentSample.clips = state.data.clips.map(({ id, durationSeconds, status }) => ({ id, durationSeconds, status }));
  $('navigation').replaceChildren();
  for (const sample of state.samples) {
    const title = document.createElement('h3'); title.textContent = sample.id; $('navigation').append(title);
    const clips = sample.id === state.sample ? state.data.clips : sample.clips;
    for (const row of clips) { const button = document.createElement('button'); button.textContent = `${row.status === 'reviewed' ? '✓ ' : ''}${row.id}`; button.setAttribute('aria-current', String(sample.id === state.sample && row.id === state.clipId)); button.disabled = state.conflict || state.navigating; button.onclick = () => openClip(sample.id, row.id); $('navigation').append(button); }
  }
}
function updateSelection() {
  const selection = state.selection;
  $('selection').hidden = !selection;
  if (selection) { $('selection').style.left = `${selection.start / duration() * 100}%`; $('selection').style.width = `${(selection.end - selection.start) / duration() * 100}%`; }
  $('start').value = selection ? selection.start.toFixed(2) : ''; $('end').value = selection ? selection.end.toFixed(2) : '';
  const blocked = !clip() || state.conflict;
  for (const id of ['assign', 'uncertain', 'replay', 'save-reference']) $(id).disabled = blocked || !selection || selection.end <= selection.start;
  $('remove').disabled = blocked || !state.selected;
  $('selection-help').textContent = selection ? `${time(selection.start)}–${time(selection.end)} · ${(selection.end - selection.start).toFixed(2)} seconds` : 'Select a range to label speech or mark uncertainty.';
}
const extraSpeakers = new Map();
function renderSpeakerOptions() {
  const selected = $('speaker').value;
  const labels = new Set(Array.from({ length: 20 }, (_, index) => `speaker-${index + 1}`));
  for (const row of state.data?.clips || []) for (const interval of row.intervals) labels.add(interval.speaker);
  for (const reference of state.data?.speakerReferences || []) labels.add(reference.speaker);
  for (const label of extraSpeakers.get(state.sample) || []) labels.add(label);
  const options = [...labels].sort((a, b) => a.localeCompare(b, undefined, { numeric: true }));
  $('speaker').replaceChildren(...options.map(label => new Option(speakerName(label), label)));
  $('speaker').value = labels.has(selected) ? selected : 'speaker-1';
}
function render() {
  renderNavigation();
  renderSpeakerOptions();
  const current = clip(), blocked = !current || state.conflict;
  for (const id of ['finish', 'select-all', 'clear-selection', 'start', 'end', 'speaker', 'add-speaker', 'zoom']) $(id).disabled = blocked;
  $('undo').disabled = blocked || !state.history.length;
  $('export').disabled = blocked || !state.data.clips.every(row => row.status === 'reviewed');
  updateSelection(); if (!current) return;
  $('clip-title').textContent = `${state.sample} · ${current.id}`;
  $('progress').textContent = `${state.data.clips.filter(row => row.status === 'reviewed').length} of ${state.data.clips.length} clips reviewed · ${time(current.durationSeconds)}${current.status === 'reviewed' ? ' · Reviewed' : ''}`;
  $('lanes').replaceChildren(); $('interval-list').replaceChildren();
  const speakers = [...new Set(current.intervals.map(row => row.speaker))].sort((a, b) => a.localeCompare(b, undefined, { numeric: true }));
  for (const key of [...speakers, 'uncertain']) {
    const kind = key === 'uncertain' ? 'uncertainRegions' : 'intervals';
    const rows = current[kind] || [];
    if (!rows.some(row => kind === 'uncertainRegions' || row.speaker === key)) continue;
    const lane = document.createElement('div'); lane.className = 'lane'; const label = document.createElement('span'); label.className = 'lane-name'; label.textContent = key === 'uncertain' ? 'Uncertain' : speakerName(key); lane.append(label);
    rows.forEach((row, index) => {
      if (kind === 'intervals' && row.speaker !== key) return;
      const text = `${key === 'uncertain' ? 'Uncertain' : speakerName(key)} · ${time(row.start)}–${time(row.end)}`;
      const button = document.createElement('button'); button.className = `interval ${key === 'uncertain' ? 'uncertain' : ''} ${state.selected?.kind === kind && state.selected.index === index ? 'selected' : ''}`; button.style.left = `${row.start / duration() * 100}%`; button.style.width = `${(row.end - row.start) / duration() * 100}%`; button.textContent = text; button.title = text; button.onclick = () => selectInterval(kind, index); lane.append(button);
      const listButton = document.createElement('button'); listButton.textContent = text; listButton.onclick = button.onclick; $('interval-list').append(listButton);
    }); $('lanes').append(lane);
  }
  if (!$('interval-list').children.length) $('interval-list').textContent = 'No speech or uncertain ranges marked.';
  $('references').replaceChildren();
  for (const reference of state.data.speakerReferences || []) { const button = document.createElement('button'); button.textContent = `Play ${speakerName(reference.speaker)} Reference`; button.onclick = () => playReference(reference); $('references').append(button); }
  drawWaveform();
}
function selectInterval(kind, index) {
  const row = clip()[kind][index]; state.selected = { kind, index }; state.selection = { start: row.start, end: row.end };
  if (row.speaker) { if (![...$('speaker').options].some(option => option.value === row.speaker)) $('speaker').add(new Option(speakerName(row.speaker), row.speaker)); $('speaker').value = row.speaker; }
  render();
}
function assign(speaker) {
  if (!state.selection || state.selection.end <= state.selection.start) return;
  const range = copy(state.selection);
  mutate(() => {
    if (state.selected?.kind === 'intervals') clip().intervals[state.selected.index] = { ...range, speaker };
    else { clip().intervals.push({ ...range, speaker }); state.selected = { kind: 'intervals', index: clip().intervals.length - 1 }; }
  });
}
function applySelection() {
  if (state.selected) { const { kind, index } = state.selected; const range = copy(state.selection); mutate(() => Object.assign(clip()[kind][index], range)); }
  else updateSelection();
}
function remove() { if (!state.selected) return; mutate(() => { clip()[state.selected.kind].splice(state.selected.index, 1); state.selected = null; }); }
function undo() {
  if (!state.history.length || state.conflict) return;
  Object.assign(state.data, state.history.pop()); state.selected = null; state.selection = null; state.generation++; render(); $('save-state').textContent = 'Unsaved Changes'; clearTimeout(saveTimer); saveTimer = setTimeout(() => save().catch(() => {}), 450);
}
function normalizeUncertainty() {
  const current = clip(); if (!current) return;
  const merged = [];
  for (const row of [...(current.uncertainRegions || [])].sort((a, b) => a.start - b.start)) {
    const previous = merged.at(-1);
    if (previous && row.start <= previous.end) previous.end = Math.max(previous.end, row.end);
    else merged.push({ start: row.start, end: row.end });
  }
  current.uncertainRegions = merged;
  if (state.selected?.kind === 'uncertainRegions' && state.selection) {
    const index = merged.findIndex(row => row.start <= state.selection.start && row.end >= state.selection.end);
    state.selected = index >= 0 ? { kind: 'uncertainRegions', index } : null;
    if (index >= 0) state.selection = copy(merged[index]);
  }
}
function coverage(durationSeconds, uncertain) {
  const regions = []; let cursor = 0;
  for (const row of [...uncertain].sort((a, b) => a.start - b.start)) { if (row.start > cursor) regions.push({ start: cursor, end: row.start }); cursor = Math.max(cursor, row.end); }
  if (cursor < durationSeconds) regions.push({ start: cursor, end: durationSeconds });
  return regions;
}
async function finish() {
  if (!clip() || state.conflict) return;
  if (!coverage(duration(), clip().uncertainRegions || []).length) { error('This entire clip is marked uncertain. Remove or shorten an uncertain range after listening before finishing the clip.'); return; }
  mutate(() => { clip().reviewedRegions = coverage(duration(), clip().uncertainRegions || []); clip().status = 'reviewed'; }, false);
  try { await save(); const index = state.data.clips.findIndex(row => row.id === state.clipId); const next = [...state.data.clips.slice(index + 1), ...state.data.clips.slice(0, index)].find(row => row.status !== 'reviewed'); if (next) await openClip(state.sample, next.id); else { $('save-state').textContent = 'Sample Reviewed'; render(); } } catch (_) { /* Keep the clip open when saving fails. */ }
}
function replay() { if (!state.selection) return; $('audio').currentTime = state.selection.start; state.playbackEnd = state.selection.end; $('audio').play().catch(failure => error(failure.message)); }
let referenceAudio;
function playReference(reference) {
  $('audio').pause(); if (referenceAudio) referenceAudio.pause();
  referenceAudio = new Audio(audioURL(state.sample, reference.clip));
  referenceAudio.onloadedmetadata = () => { referenceAudio.currentTime = reference.start; referenceAudio.play().catch(failure => error(failure.message)); };
  referenceAudio.ontimeupdate = () => { if (referenceAudio.currentTime >= reference.end) referenceAudio.pause(); };
}
function point(event) { const rect = $('waveform').getBoundingClientRect(); return bound((event.clientX - rect.left) / rect.width * duration()); }
let drag;
$('timeline').addEventListener('pointerdown', event => {
  if (!clip() || state.conflict || event.button !== 0) return;
  const edge = event.target.closest('.edge');
  if (!edge && event.target !== $('waveform')) return;
  event.preventDefault(); $('timeline').focus({ preventScroll: true });
  if (edge) drag = { mode: edge.classList.contains('start') ? 'start' : 'end' };
  else { state.selected = null; drag = { mode: 'new', anchor: point(event) }; state.selection = { start: drag.anchor, end: drag.anchor }; }
  $('timeline').setPointerCapture(event.pointerId); updateSelection();
});
$('timeline').addEventListener('pointermove', event => {
  if (!drag) return; const value = point(event);
  if (drag.mode === 'new') state.selection = { start: Math.min(drag.anchor, value), end: Math.max(drag.anchor, value) };
  else if (drag.mode === 'start') state.selection.start = Math.min(value, state.selection.end - 0.01);
  else state.selection.end = Math.max(value, state.selection.start + 0.01);
  updateSelection();
});
$('timeline').addEventListener('pointerup', event => { if (!drag) return; drag = null; $('timeline').releasePointerCapture(event.pointerId); if (state.selection.end - state.selection.start < 0.01) { $('audio').currentTime = state.selection.start; state.selection = null; } else applySelection(); updateSelection(); });
$('timeline').addEventListener('pointercancel', () => { drag = null; render(); });
for (const id of ['start', 'end']) $(id).addEventListener('change', () => {
  const start = Number($('start').value), end = Number($('end').value);
  if (!Number.isFinite(start) || !Number.isFinite(end) || start < 0 || end > duration() || end <= start) { error('Enter a start before the end, within the clip duration.'); return; }
  state.selection = { start, end }; applySelection(); updateSelection();
});
$('add-speaker').onclick = () => {
  if (!clip() || state.conflict) return;
  const numbers = [...$('speaker').options].map(option => /^speaker-(\d+)$/.exec(option.value)).filter(Boolean).map(match => Number(match[1]));
  const next = Math.max(20, ...numbers) + 1;
  if (!Number.isSafeInteger(next)) { error('Choose an existing speaker label.'); return; }
  const label = `speaker-${next}`;
  if (!extraSpeakers.has(state.sample)) extraSpeakers.set(state.sample, new Set());
  extraSpeakers.get(state.sample).add(label);
  renderSpeakerOptions(); $('speaker').value = label; $('speaker').focus();
};
$('assign').onclick = () => assign($('speaker').value);
$('uncertain').onclick = () => { if (!state.selection) return; const range = copy(state.selection); mutate(() => { clip().uncertainRegions ||= []; clip().uncertainRegions.push(range); state.selected = { kind: 'uncertainRegions', index: clip().uncertainRegions.length - 1 }; }); };
$('remove').onclick = remove; $('undo').onclick = undo; $('finish').onclick = finish; $('replay').onclick = replay;
$('select-all').onclick = () => { state.selected = null; state.selection = { start: 0, end: duration() }; render(); };
$('clear-selection').onclick = () => { state.selected = null; state.selection = null; state.playbackEnd = null; render(); };
$('zoom').oninput = () => { $('timeline').style.width = `${Number($('zoom').value) * 100}%`; drawWaveform(); };
$('speed').onchange = () => { $('audio').playbackRate = Number($('speed').value); };
$('audio').ontimeupdate = () => { $('playhead').style.left = `${$('audio').currentTime / duration() * 100}%`; if (state.playbackEnd !== null && $('audio').currentTime >= state.playbackEnd) { if ($('loop').checked && state.selection) $('audio').currentTime = state.selection.start; else { $('audio').pause(); if (referenceAudio) referenceAudio.pause(); state.playbackEnd = null; } } };
$('audio').onplay = () => { if (referenceAudio) referenceAudio.pause(); };
$('audio').onerror = () => { if (clip()) $('audio-state').textContent = 'Audio could not be loaded. Reload the page to try again.'; };
$('save-reference').onclick = () => { if (!state.selection) return; const reference = { speaker: $('speaker').value, clip: state.clipId, ...state.selection }; mutate(() => { state.data.speakerReferences = (state.data.speakerReferences || []).filter(row => row.speaker !== reference.speaker); state.data.speakerReferences.push(reference); }, false); };
function renderExport(result) {
  const container = $('export-result'); container.replaceChildren(); container.hidden = false;
  const heading = document.createElement('h3'); heading.textContent = 'Comparison With Reviewed Audio'; container.append(heading);
  const note = document.createElement('p'); note.textContent = 'Error measures missed speech, extra speech, and speaker confusion on independently selected clips. Lower is better for these reviewed ranges; this does not establish performance on other recordings.'; container.append(note);
  const table = document.createElement('table');
  const head = document.createElement('tr');
  for (const title of ['System', 'Boundary Exclusion', 'Overlap', 'Speaker Error']) { const cell = document.createElement('th'); cell.scope = 'col'; cell.textContent = title; head.append(cell); }
  table.append(head);
  for (const [system, variants] of Object.entries(result.results.systems || {})) {
    for (const variant of variants) {
      const row = document.createElement('tr');
      const values = [result.results.systemLabels?.[system] || system, variant.collar_half_width_seconds ? `±${variant.collar_half_width_seconds * 1000} ms` : 'None', variant.exclude_reference_overlap ? 'Excluded' : 'Included', variant.diarization_error_rate === null ? 'No reviewed speech' : `${(variant.diarization_error_rate * 100).toFixed(2)}%`];
      for (const value of values) { const cell = document.createElement('td'); cell.textContent = value; row.append(cell); } table.append(row);
    }
  }
  container.append(table); const output = document.createElement('p'); output.textContent = `Export saved to ${result.output}`; container.append(output);
}
$('export').onclick = async () => { try { await save(); const result = await request(`/api/export/${encodeURIComponent(state.sample)}`, { method: 'POST', body: '{}' }); renderExport(result); } catch (failure) { error(failure.message); } };
$('download-draft').onclick = async () => {
  try {
    const result = await request(`/api/drafts/${encodeURIComponent(state.sample)}`, { method: 'POST', body: JSON.stringify({ revision: state.data.revision, clips: state.data.clips, speakerReferences: state.data.speakerReferences || [] }) });
    $('draft-state').textContent = `Draft saved to ${result.output}`;
  } catch (failure) { error(failure.message); }
};
$('reload').onclick = async () => { try { state.data = await request(`/api/samples/${encodeURIComponent(state.sample)}`); state.conflict = false; state.saved = state.generation = 0; state.history = []; state.selected = null; state.selection = null; $('conflict').hidden = true; $('save-state').textContent = 'Saved'; render(); } catch (failure) { error(failure.message); } };
window.addEventListener('beforeunload', event => { if (state.saved < state.generation) { event.preventDefault(); event.returnValue = ''; } });
window.addEventListener('resize', drawWaveform);
document.addEventListener('keydown', event => {
  if (/INPUT|SELECT|TEXTAREA/.test(event.target.tagName) || event.target.closest('audio') || !clip() || state.conflict) return;
  if ((event.ctrlKey || event.metaKey) && event.key.toLowerCase() === 'z') { event.preventDefault(); undo(); }
  else if (event.key === ' ' && event.target.tagName !== 'BUTTON') { event.preventDefault(); if ($('audio').paused) { state.playbackEnd = null; $('audio').play().catch(failure => error(failure.message)); } else $('audio').pause(); }
  else if (/^[1-9]$/.test(event.key)) { event.preventDefault(); $('speaker').value = `speaker-${event.key}`; assign($('speaker').value); }
  else if (event.key.toLowerCase() === 'r') { event.preventDefault(); replay(); }
  else if (event.key === 'Delete' || event.key === 'Backspace') { event.preventDefault(); remove(); }
  else if ((event.key === 'ArrowLeft' || event.key === 'ArrowRight') && state.selection) { event.preventDefault(); const delta = event.key === 'ArrowLeft' ? -0.05 : 0.05; if (event.shiftKey) state.selection.end = Math.max(state.selection.start + 0.01, bound(state.selection.end + delta)); else { const shift = Math.max(-state.selection.start, Math.min(duration() - state.selection.end, delta)); state.selection.start += shift; state.selection.end += shift; } applySelection(); updateSelection(); }
});
(async () => { render(); try { const data = await request('/api/samples'); state.samples = data.samples; if (state.samples.length && state.samples[0].clips.length) await openClip(state.samples[0].id, state.samples[0].clips[0].id); else { $('save-state').textContent = 'No Clips Available'; $('audio-state').textContent = 'Prepare review clips, then reload this page.'; } } catch (failure) { $('save-state').textContent = 'Samples Unavailable'; error(failure.message); } })();
